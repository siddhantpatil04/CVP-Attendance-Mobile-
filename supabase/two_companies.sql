-- =====================================================================
-- TWO COMPANIES:  CVPA = "C.V. Patil & Associates"   CVPCE = "C.V. Patil Consultancy Engineers Pvt. Ltd."
--
-- Employees live in public.profiles in this app, so "employees.company_id" = profiles.company_id.
-- The company only decides WHICH employees appear in a report and WHICH name / address is printed on it.
-- It does NOT touch check_in / check_out, attendance, leave, working hours or salary calculations.
--
-- This file:
--   1. creates   companies                  (CVPA + CVPCE; CVPCE address / CIN left empty -> Settings > Companies)
--   2. adds      profiles.company_id        (FK; every existing employee -> CVPA)
--   3. creates   employee_company_history   (one starting row per employee: CVPA from the joining date)
--   4. RLS       everybody signed in reads companies; employees read only their own history, HR / Admin read all;
--                nobody writes directly - only the functions below (HR / Admin; company details Admin only)
--   5. functions get_employee_company(employee, date)      -> company id valid on that date
--                admin_create_company(legal_name, address, pan_or_cin)  (Admin only, Audit Trail: adds a new company)
--                admin_set_employee_company(user, company, from_date)  (HR / Admin, Audit Trail)
--                admin_update_company(company, legal_name, address, pan_or_cin)  (Admin only, Audit Trail)
--   6. triggers  new employee -> CVPA + starting history row;  company_id can only be changed through the function
--
-- No existing row is deleted or edited except the NEW column profiles.company_id being filled with CVPA.
-- BACK UP FIRST.   Supabase -> SQL Editor -> paste the WHOLE file -> Run.   Safe to run again.   Undo: two_companies_ROLLBACK.sql
-- =====================================================================

-- 1. companies ---------------------------------------------------------
create table if not exists public.companies (
  id          bigint generated always as identity primary key,
  short_code  text not null unique,
  legal_name  text not null,
  address     text,
  pan_or_cin  text,
  is_active   boolean not null default true
);

-- (older version of this file limited short_code to CVPA / CVPCE: remove that limit so more companies can be added)
alter table public.companies drop constraint if exists companies_short_code_check;

insert into public.companies (short_code, legal_name, address, pan_or_cin) values
  ('CVPA',  'C.V. Patil & Associates',
   '1002, Trident Business Centre, Oppo. Audi Showroom, Mumbai-Pune Highway, Baner, Pune-411045', 'AKDPP4541Q'),
  ('CVPCE', 'C.V. Patil Consultancy Engineers Pvt. Ltd.', null, null)
on conflict (short_code) do nothing;

-- 2. profiles.company_id -----------------------------------------------
alter table public.profiles add column if not exists company_id bigint references public.companies(id);

update public.profiles
   set company_id = (select id from public.companies where short_code = 'CVPA')
 where company_id is null;

alter table public.profiles alter column company_id set not null;
create index if not exists profiles_company_idx on public.profiles (company_id);

-- 3. employee_company_history -----------------------------------------
create table if not exists public.employee_company_history (
  id          bigint generated always as identity primary key,
  employee_id uuid   not null references public.profiles(id) on delete cascade,
  company_id  bigint not null references public.companies(id),
  from_date   date   not null,
  changed_by  uuid references public.profiles(id) on delete set null,
  changed_at  timestamptz not null default now(),
  unique (employee_id, from_date)
);
create index if not exists ech_emp_idx on public.employee_company_history (employee_id, from_date desc);

-- one starting row per employee: CVPA from the joining date (falls back to the account creation date)
insert into public.employee_company_history (employee_id, company_id, from_date)
select p.id, p.company_id, coalesce(p.joining_date, (p.created_at at time zone 'Asia/Kolkata')::date)
  from public.profiles p
 where not exists (select 1 from public.employee_company_history h where h.employee_id = p.id);

-- 4. Row level security -------------------------------------------------
alter table public.companies                enable row level security;
alter table public.employee_company_history enable row level security;

drop policy if exists companies_read on public.companies;
create policy companies_read on public.companies for select to authenticated using (true);

drop policy if exists ech_read on public.employee_company_history;
create policy ech_read on public.employee_company_history for select to authenticated
  using (employee_id = auth.uid()
         or exists (select 1 from public.profiles me where me.id = auth.uid() and me.active and me.role in ('HR', 'Admin')));
-- (no insert / update / delete policy: writes only through the SECURITY DEFINER functions below)

-- 5a. Which company is an employee in on a given date ------------------
--     = the history row with the latest from_date <= date; before the first row the first company is used.
create or replace function public.get_employee_company(p_employee uuid, p_date date)
returns bigint
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select h.company_id from public.employee_company_history h
      where h.employee_id = p_employee and h.from_date <= p_date
      order by h.from_date desc limit 1),
    (select h.company_id from public.employee_company_history h
      where h.employee_id = p_employee order by h.from_date asc limit 1),
    (select p.company_id from public.profiles p where p.id = p_employee))
$$;
revoke all on function public.get_employee_company(uuid, date) from public, anon;
grant execute on function public.get_employee_company(uuid, date) to authenticated;

-- 5b. Move an employee to a company from a date (HR / Admin) -----------
create or replace function public.admin_set_employee_company(p_user uuid, p_company bigint, p_from date)
returns public.profiles
language plpgsql security definer set search_path = public as $$
declare
  me      public.profiles := public._require_admin();
  target  public.profiles;
  comp    public.companies;
begin
  if p_from is null then raise exception 'Enter the company from date'; end if;
  select * into comp from public.companies where id = p_company and is_active;
  if comp.id is null then raise exception 'Company not found'; end if;
  select * into target from public.profiles where id = p_user for update;
  if target.id is null then raise exception 'User not found'; end if;
  -- same rule as admin_update_profile: only an Admin touches HR / Admin accounts
  if me.role <> 'Admin' and target.id <> me.id and target.role <> 'Employee' then
    raise exception 'Only an Admin can change HR / Admin accounts';
  end if;

  insert into public.employee_company_history (employee_id, company_id, from_date, changed_by)
  values (p_user, p_company, p_from, me.id)
  on conflict (employee_id, from_date)
  do update set company_id = excluded.company_id, changed_by = excluded.changed_by, changed_at = now();

  -- profiles.company_id = the company valid today (the guard trigger allows it because of this flag)
  perform set_config('cvp.company_change', 'on', true);
  update public.profiles
     set company_id = public.get_employee_company(p_user, public.ist_today())
   where id = p_user returning * into target;

  perform public._audit('EMPLOYEE_COMPANY',
    target.username || ' -> ' || comp.legal_name || ' from ' || p_from::text);
  return target;
end $$;
revoke all on function public.admin_set_employee_company(uuid, bigint, date) from public, anon;
grant execute on function public.admin_set_employee_company(uuid, bigint, date) to authenticated;

-- 5c. Company details (Admin only) -------------------------------------
create or replace function public.admin_update_company(p_company bigint, p_legal_name text, p_address text, p_pan_or_cin text)
returns public.companies
language plpgsql security definer set search_path = public as $$
declare
  me  public.profiles := public._require_active();
  c   public.companies;
begin
  if me.role <> 'Admin' then raise exception 'Only an Admin can edit company details' using errcode = '42501'; end if;
  if p_legal_name is null or length(trim(p_legal_name)) = 0 then raise exception 'Enter the company name'; end if;
  update public.companies
     set legal_name = trim(p_legal_name),
         address    = nullif(trim(coalesce(p_address, '')), ''),
         pan_or_cin = nullif(trim(coalesce(p_pan_or_cin, '')), '')
   where id = p_company returning * into c;
  if c.id is null then raise exception 'Company not found'; end if;
  perform public._audit('UPDATE_COMPANY', c.short_code || ' ' || c.legal_name);
  return c;
end $$;
revoke all on function public.admin_update_company(bigint, text, text, text) from public, anon;
grant execute on function public.admin_update_company(bigint, text, text, text) to authenticated;

-- 5d. Add a new company (Admin only): Settings > Companies > "+ New company"
--     the short code is made from the initials of the name and made unique with a number when needed
create or replace function public.admin_create_company(p_legal_name text, p_address text, p_pan_or_cin text)
returns public.companies
language plpgsql security definer set search_path = public as $$
declare
  me     public.profiles := public._require_active();
  c      public.companies;
  base   text;
  code   text;
  n      int := 1;
begin
  if me.role <> 'Admin' then raise exception 'Only an Admin can add a company' using errcode = '42501'; end if;
  if p_legal_name is null or length(trim(p_legal_name)) = 0 then raise exception 'Enter the company name'; end if;
  if exists (select 1 from public.companies where lower(legal_name) = lower(trim(p_legal_name))) then
    raise exception 'A company with this name already exists';
  end if;
  -- initials of the words (letters / digits only), at most 6 characters
  select coalesce(nullif(left(string_agg(upper(left(w, 1)), ''), 6), ''), 'CO') into base
    from regexp_split_to_table(regexp_replace(trim(p_legal_name), '[^A-Za-z0-9 ]', ' ', 'g'), '\s+') as w
   where w <> '';
  code := base;
  while exists (select 1 from public.companies where short_code = code) loop
    n := n + 1; code := base || n::text;
  end loop;
  insert into public.companies (short_code, legal_name, address, pan_or_cin)
  values (code, trim(p_legal_name), nullif(trim(coalesce(p_address, '')), ''), nullif(trim(coalesce(p_pan_or_cin, '')), ''))
  returning * into c;
  perform public._audit('CREATE_COMPANY', c.short_code || ' ' || c.legal_name);
  return c;
end $$;
revoke all on function public.admin_create_company(text, text, text) from public, anon;
grant execute on function public.admin_create_company(text, text, text) to authenticated;

-- 6a. New employee: CVPA unless set + starting history row -------------
create or replace function public._profiles_company_default() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.company_id is null then
    select id into new.company_id from public.companies where short_code = 'CVPA';
  end if;
  return new;
end $$;
drop trigger if exists profiles_company_default on public.profiles;
create trigger profiles_company_default before insert on public.profiles
  for each row execute function public._profiles_company_default();

create or replace function public._profiles_company_history_start() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.employee_company_history (employee_id, company_id, from_date)
  values (new.id, new.company_id, coalesce(new.joining_date, (now() at time zone 'Asia/Kolkata')::date))
  on conflict (employee_id, from_date) do nothing;
  return new;
end $$;
drop trigger if exists profiles_company_history_start on public.profiles;
create trigger profiles_company_history_start after insert on public.profiles
  for each row execute function public._profiles_company_history_start();

-- 6b. company_id can only be changed through admin_set_employee_company ----
create or replace function public._profiles_company_guard() returns trigger
language plpgsql as $$
begin
  if new.company_id is distinct from old.company_id
     and coalesce(current_setting('cvp.company_change', true), '') <> 'on' then
    raise exception 'The company can only be changed by HR / Admin in Employees > Joining' using errcode = '42501';
  end if;
  return new;
end $$;
drop trigger if exists profiles_company_guard on public.profiles;
create trigger profiles_company_guard before update of company_id on public.profiles
  for each row execute function public._profiles_company_guard();

notify pgrst, 'reload schema';

-- CHECK after running (all should show CVPA):
--   select c.short_code, count(*) from public.profiles p join public.companies c on c.id = p.company_id group by 1;
