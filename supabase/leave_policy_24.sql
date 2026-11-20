-- =====================================================================
-- LEAVE POLICY: 24 PAID LEAVES A YEAR AFTER 6 MONTHS  (Earned 12 + Casual 6 + Sick 6), HALF DAYS, ADMIN / HR APPROVAL
--
-- Run AFTER: cvp_attendance_schema.sql, holiday_setup.sql, leave_eligibility.sql, monthly_leave_no_carry.sql, leave_rules_update.sql
--            (and checkin_places_500m.sql if you use the Working Hours rules - the 4h half-day rule is read from it).
-- THIS FILE REPLACES the "1 paid leave a month, nothing carried forward" rule (monthly_leave_no_carry.sql) for NEW leave requests.
--
-- WHAT IT DOES
--  1. Leave types: Earned Leave (EL, 12 a year, saved up to 30), Casual Leave (CL, 6), Sick Leave (SL, 6), Unpaid (Loss of Pay),
--     and the quick "Half Day - Personal work".  Annual Leave, Compensatory Off and Monthly Paid Leave are switched OFF for new
--     requests (active = false).  NOTHING is deleted: every old leave request stays, and OLD requests are still counted and paid
--     exactly as before (they keep the old rule; the new rule applies only to requests made with this file: leaves.policy_v2 = true).
--  2. Balances are a LEDGER (leave_ledger): +credit every month (EL +1, CL +0.5, SL +0.5) once the employee is eligible
--     (joining date + 6 months, or "Start paid leaves now"), -used when a request is APPROVED, -lapsed on the year-end date for CL / SL,
--     -encashed, +/- adjusted by Admin.  EL is capped (default 30): at the cap no more EL is added until some is used.
--  3. Monthly credit + year-end lapse are one daily job: run_leave_jobs()  (pg_cron schedules it if pg_cron is installed;
--     otherwise Admin can call it from the Leave policy screen).  A month is never credited twice.
--     NO back-credit: the job credits only the CURRENT month.  Opening balances are set by you after the preview
--     (see leave_policy_preview.sql) with admin_adjust_leave_balance().
--  4. Applying (apply_leave): EL needs notice days (default 7), CL max 3 days a request and any day, SL needs a medical certificate
--     above 2 days and can be applied up to 3 days after, half day for every type, "Half Day - Personal work" picks CL, then EL,
--     then Unpaid automatically.  Days above the balance become Unpaid (LOP).  Everything goes to Admin / HR for approval.
--  5. Approval (review_leave): the balance is deducted only when APPROVED (rows written to leave_day_alloc + leave_ledger).
--  6. Salary: the same per-day formula; approved LOP units are deducted (a half day = 0.5).  admin_payroll is replaced by a version
--     that gives the SAME numbers for old leave and adds the new leave; unpaid days / payable days can now show .5.
--  7. Attendance: on a half-day leave date the required working hours are half (see _required_minutes_on in checkin_places_500m.sql).
--
-- ONE additive file.  Safe to run again.  No safety lock.  No table is dropped and no data is deleted.
-- BACK UP THE DATABASE FIRST.  Do NOT edit or run cvp_attendance_schema.sql for this.
-- Supabase -> SQL Editor -> paste the WHOLE file -> Run.
-- =====================================================================

-- 1. Policy settings (extra columns on the existing payroll_settings row) -----------------------------------------
alter table public.payroll_settings add column if not exists leave_el_notice_days    integer not null default 7  check (leave_el_notice_days between 7 and 15);
alter table public.payroll_settings add column if not exists leave_el_cap            numeric not null default 30 check (leave_el_cap between 12 and 120);
alter table public.payroll_settings add column if not exists leave_el_keep_min       numeric not null default 12 check (leave_el_keep_min between 0 and 120);   -- EL above this can be encashed
alter table public.payroll_settings add column if not exists leave_cl_max_request    numeric not null default 3  check (leave_cl_max_request between 2 and 3);
alter table public.payroll_settings add column if not exists leave_sl_cert_after     numeric not null default 2  check (leave_sl_cert_after between 0 and 30);
alter table public.payroll_settings add column if not exists leave_sl_apply_within   integer not null default 3  check (leave_sl_apply_within between 0 and 30);
alter table public.payroll_settings add column if not exists leave_lapse_month       integer not null default 12 check (leave_lapse_month between 1 and 12);
alter table public.payroll_settings add column if not exists leave_lapse_day         integer not null default 31 check (leave_lapse_day between 1 and 31);
alter table public.payroll_settings add column if not exists leave_personal_order    text    not null default 'CL,EL' check (leave_personal_order in ('CL,EL', 'EL,CL'));
alter table public.payroll_settings add column if not exists leave_personal_max_month integer check (leave_personal_max_month is null or leave_personal_max_month between 0 and 31);

-- Leave types: new ones added, old demo ones switched off (never deleted) ----------------------------------------------
insert into public.leave_types (name, annual_quota, counts_balance, sort_order, active) values
  ('Earned Leave', 12, true, 1, true),
  ('Half Day - Personal work', 0, false, 4, true)
on conflict (name) do update set active = true;
update public.leave_types set annual_quota = 6, sort_order = 2, active = true where name = 'Casual Leave';
update public.leave_types set annual_quota = 6, sort_order = 3, active = true where name = 'Sick Leave';
update public.leave_types set sort_order = 5, active = true where name = 'Loss of Pay';
update public.leave_types set active = false where name in ('Annual Leave', 'Compensatory Off', 'Monthly Paid Leave');

-- Leave requests: new columns (old rows keep policy_v2 = false and are counted by the old rule) --------------------------
alter table public.leaves add column if not exists policy_v2        boolean not null default false;
alter table public.leaves add column if not exists units            numeric(4,1);                         -- 0.5 for a half day
alter table public.leaves add column if not exists half_part        text check (half_part is null or half_part in ('first', 'second'));
alter table public.leaves add column if not exists personal_work    text;
alter table public.leaves add column if not exists certificate_path text;

-- Early start of paid leaves for an employee under 6 months (Admin switch) ------------------------------------------------
alter table public.profiles add column if not exists paid_leave_early_from   date;
alter table public.profiles add column if not exists paid_leave_early_reason text;

-- 2. Ledger and per-day allocation ---------------------------------------------------------------------------------------
create table if not exists public.leave_ledger (
  id            bigint generated always as identity primary key,
  employee_id   uuid not null references public.profiles(id) on delete cascade,
  leave_type    text not null check (leave_type in ('Earned Leave', 'Casual Leave', 'Sick Leave')),
  month         date not null,                                   -- first day of the month the row belongs to
  kind          text not null check (kind in ('credit', 'used', 'lapse', 'encash', 'adjust', 'opening')),
  credited      numeric(6,2) not null default 0,
  used          numeric(6,2) not null default 0,
  lapsed        numeric(6,2) not null default 0,
  encashed      numeric(6,2) not null default 0,
  adjusted      numeric(6,2) not null default 0,                 -- may be negative
  amount        numeric(12,2),                                   -- rupees, for an encashment
  leave_id      bigint references public.leaves(id) on delete set null,
  reason        text,
  balance_after numeric(6,2) not null default 0,
  created_by    uuid references public.profiles(id) on delete set null,
  created_at    timestamptz not null default now()
);
create index if not exists leave_ledger_emp_idx on public.leave_ledger (employee_id, leave_type, month);
create unique index if not exists leave_ledger_credit_once on public.leave_ledger (employee_id, leave_type, month) where kind = 'credit';
create unique index if not exists leave_ledger_lapse_once  on public.leave_ledger (employee_id, leave_type, month) where kind = 'lapse';
alter table public.leave_ledger enable row level security;
drop policy if exists leave_ledger_read on public.leave_ledger;
create policy leave_ledger_read on public.leave_ledger for select to authenticated using (employee_id = auth.uid() or public.is_staff_admin());
revoke all on public.leave_ledger from anon;
revoke insert, update, delete on public.leave_ledger from authenticated;
grant select on public.leave_ledger to authenticated;

create table if not exists public.leave_day_alloc (
  leave_id  bigint not null references public.leaves(id) on delete cascade,
  user_id   uuid   not null references public.profiles(id) on delete cascade,
  day       date   not null,
  bucket    text   not null check (bucket in ('EL', 'CL', 'SL', 'LOP')),
  units     numeric(3,1) not null check (units > 0),
  half_part text,
  primary key (leave_id, day, bucket)
);
create index if not exists leave_day_alloc_user_idx on public.leave_day_alloc (user_id, day);
alter table public.leave_day_alloc enable row level security;
drop policy if exists leave_day_alloc_read on public.leave_day_alloc;
create policy leave_day_alloc_read on public.leave_day_alloc for select to authenticated using (user_id = auth.uid() or public.is_staff_admin());
revoke all on public.leave_day_alloc from anon;
revoke insert, update, delete on public.leave_day_alloc from authenticated;
grant select on public.leave_day_alloc to authenticated;

-- Medical certificates: private bucket, an employee uploads into his own folder, Admin / HR can read ----------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('leave_certs', 'leave_certs', false, 10485760, array['application/pdf', 'image/jpeg', 'image/png'])
on conflict (id) do update set public = false;
drop policy if exists leave_certs_upload on storage.objects;
create policy leave_certs_upload on storage.objects for insert to authenticated
  with check (bucket_id = 'leave_certs' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists leave_certs_read on storage.objects;
create policy leave_certs_read on storage.objects for select to authenticated
  using (bucket_id = 'leave_certs' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_staff_admin()));

-- 3. Eligibility: joining date + N months, or the early-start date -------------------------------------------------------
create or replace function public._leave_eligible_from(p_user uuid) returns date
language sql stable security definer set search_path = public as $$
  select case when p.joining_date is null then p.paid_leave_early_from
              else least((p.joining_date + make_interval(months => s.leave_eligibility_months))::date,
                         coalesce(p.paid_leave_early_from, date '9999-12-31')) end
    from public.profiles p cross join public.payroll_settings s
   where p.id = p_user and s.id = 1
$$;
revoke execute on function public._leave_eligible_from(uuid) from public, anon, authenticated;

-- 4. Ledger helpers -------------------------------------------------------------------------------------------------------
create or replace function public._lv_bal(p_user uuid, p_type text) returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce(sum(credited + adjusted - used - lapsed - encashed), 0)
    from public.leave_ledger where employee_id = p_user and leave_type = p_type
$$;
revoke execute on function public._lv_bal(uuid, text) from public, anon, authenticated;

-- one ledger row; amount > 0 for credit / opening / adjust(+), the row decides the column from p_kind (adjust may be negative)
create or replace function public._lv_add(p_user uuid, p_type text, p_month date, p_kind text, p_amt numeric,
                                          p_reason text default null, p_leave bigint default null, p_by uuid default null, p_money numeric default null)
returns void
language plpgsql security definer set search_path = public as $$
declare v_bal numeric;
begin
  v_bal := public._lv_bal(p_user, p_type);
  insert into public.leave_ledger (employee_id, leave_type, month, kind, credited, used, lapsed, encashed, adjusted, amount, leave_id, reason, balance_after, created_by)
  values (p_user, p_type, date_trunc('month', p_month::timestamp)::date, p_kind,
          case when p_kind in ('credit', 'opening') then p_amt else 0 end,
          case when p_kind = 'used' then p_amt else 0 end,
          case when p_kind = 'lapse' then p_amt else 0 end,
          case when p_kind = 'encash' then p_amt else 0 end,
          case when p_kind = 'adjust' then p_amt else 0 end,
          p_money, p_leave, nullif(trim(coalesce(p_reason, '')), ''),
          v_bal + case when p_kind in ('credit', 'opening', 'adjust') then p_amt else -p_amt end,
          p_by);
end $$;
revoke execute on function public._lv_add(uuid, text, date, text, numeric, text, bigint, uuid, numeric) from public, anon, authenticated;

-- 5. Working days of a leave request: a leave day is a working day that is not a holiday ---------------------------------
--    Allocation plan of a request: for each date the bucket (EL / CL / SL / LOP) and the units, using the CURRENT balances.
--    Used by the preview (employee and approver) and by the approval itself.
create or replace function public._lv_plan(p_user uuid, p_type text, p_from date, p_to date, p_half text default null)
returns table (day date, status text, bucket text, units numeric)
language plpgsql stable security definer set search_path = public as $$
declare
  st     public.payroll_settings;
  v_elig date := public._leave_eligible_from(p_user);
  v_el   numeric := public._lv_bal(p_user, 'Earned Leave');
  v_cl   numeric := public._lv_bal(p_user, 'Casual Leave');
  v_sl   numeric := public._lv_bal(p_user, 'Sick Leave');
  d      date;
  u      numeric; rest numeric; take numeric; b text; order_ text[];
begin
  select * into st from public.payroll_settings where id = 1;
  for d in select g::date from generate_series(p_from::timestamp, p_to::timestamp, interval '1 day') g loop
    if exists (select 1 from public._holiday_info(p_user, d)) then
      day := d; status := 'Holiday'; bucket := null; units := 0; return next; continue;
    elsif not public._is_workday(p_user, d) then
      day := d; status := 'Weekly off'; bucket := null; units := 0; return next; continue;
    end if;
    u := case when p_half is not null then 0.5 else 1 end;
    rest := u;
    order_ := case p_type
                when 'Earned Leave' then array['EL']
                when 'Casual Leave' then array['CL']
                when 'Sick Leave'   then array['SL']
                when 'Half Day - Personal work' then case st.leave_personal_order when 'EL,CL' then array['EL', 'CL'] else array['CL', 'EL'] end
                else array[]::text[] end;
    if v_elig is not null and d >= v_elig then
      foreach b in array order_ loop
        exit when rest <= 0;
        take := least(rest, case b when 'EL' then v_el when 'CL' then v_cl else v_sl end);
        if take > 0 then
          if b = 'EL' then v_el := v_el - take; elsif b = 'CL' then v_cl := v_cl - take; else v_sl := v_sl - take; end if;
          rest := rest - take;
          day := d; status := 'Paid'; bucket := b; units := take; return next;
        end if;
      end loop;
    end if;
    if rest > 0 then day := d; status := 'Unpaid'; bucket := 'LOP'; units := rest; return next; end if;
  end loop;
end $$;
revoke execute on function public._lv_plan(uuid, text, date, date, text) from public, anon, authenticated;

-- 6. Preview for the Apply screen / approval: one row per date --------------------------------------------------------------
create or replace function public.leave_preview_v2(p_type text, p_from date, p_to date, p_half text default null, p_user uuid default null)
returns table (day date, status text, bucket text, units numeric, per_day numeric)
language plpgsql stable security definer set search_path = public as $$
declare me public.profiles := public._require_active(); v_user uuid := coalesce(p_user, me.id);
begin
  if p_user is not null and p_user <> me.id and me.role not in ('HR', 'Admin') then
    raise exception 'You can only preview your own leave' using errcode = '42501';
  end if;
  if p_to < p_from or p_to - p_from > 370 then return; end if;
  return query
  select p.day, p.status, p.bucket, p.units,
         round(coalesce(public._salary_on(v_user, p.day), 0) /
               extract(day from (date_trunc('month', p.day::timestamp) + interval '1 month - 1 day'))::numeric, 2)
    from public._lv_plan(v_user, p_type, p_from, p_to, p_half) p
   order by p.day, p.bucket;
end $$;

-- 7. Apply for leave -----------------------------------------------------------------------------------------------------------
-- (the old 4-argument version is replaced: calls with 4 arguments still work, the new arguments have defaults)
drop function if exists public.apply_leave(text, date, date, text);
create or replace function public.apply_leave(p_leave_type text, p_from date, p_to date, p_reason text,
                                              p_half text default null, p_personal text default null, p_certificate text default null)
returns public.leaves
language plpgsql security definer set search_path = public as $$
declare
  me     public.profiles := public._require_active();
  st     public.payroll_settings;
  t      public.leave_types;
  v_today date := public.ist_today();
  v_units numeric := 0;
  v_half  boolean := p_half is not null;
  v_pm    numeric;
  r      public.leaves;
begin
  select * into st from public.payroll_settings where id = 1;
  select * into t from public.leave_types
   where name = p_leave_type and active and name in ('Earned Leave', 'Casual Leave', 'Sick Leave', 'Loss of Pay', 'Half Day - Personal work');
  if t.name is null then raise exception 'Choose Earned, Casual, Sick, Unpaid or Half Day - Personal work'; end if;
  if p_to < p_from then raise exception 'End date cannot be before start date'; end if;
  if nullif(trim(p_reason), '') is null then raise exception 'Enter a reason'; end if;
  if extract(year from p_from) <> extract(year from p_to) then raise exception 'The dates are in two calendar years. Apply as two requests'; end if;

  if t.name = 'Half Day - Personal work' and not v_half then raise exception 'Choose which half: morning or afternoon'; end if;
  if v_half and p_half not in ('first', 'second') then raise exception 'Choose which half: morning or afternoon'; end if;
  if v_half and p_from <> p_to then raise exception 'A half day is for one date'; end if;
  if t.name = 'Half Day - Personal work' and coalesce(p_personal, '') not in ('Bank / office', 'Family', 'Doctor', 'Other') then
    raise exception 'Choose the personal work: Bank / office, Family, Doctor or Other';
  end if;

  -- notice rules
  if t.name = 'Earned Leave' and p_from < v_today + st.leave_el_notice_days then
    raise exception 'Earned Leave needs % days notice. Choose later dates, or use Casual Leave.', st.leave_el_notice_days;
  elsif t.name = 'Sick Leave' and p_from < v_today - st.leave_sl_apply_within then
    raise exception 'Sick Leave can be applied up to % days after the leave', st.leave_sl_apply_within;
  elsif t.name not in ('Earned Leave', 'Sick Leave') and p_from < v_today then
    raise exception 'Choose today or a later date';
  end if;

  -- units = working days (a weekly off / holiday is not leave); a half day = 0.5
  select coalesce(sum(x.units), 0) into v_units
    from public._lv_plan(me.id, t.name, p_from, p_to, p_half) x where x.bucket is not null;
  if v_units = 0 then raise exception 'No working days in the selected period (weekly off / holiday only)'; end if;

  if t.name = 'Casual Leave' and v_units > st.leave_cl_max_request then
    raise exception 'Casual Leave: maximum % days at a time.', st.leave_cl_max_request;
  end if;
  if t.name = 'Sick Leave' and v_units > st.leave_sl_cert_after
     and (p_certificate is null or split_part(p_certificate, '/', 1) <> me.id::text) then
    raise exception 'Upload the medical certificate (Sick Leave of more than % days).', st.leave_sl_cert_after;
  end if;
  if t.name = 'Half Day - Personal work' and st.leave_personal_max_month is not null then
    select coalesce(sum(l.units), 0) into v_pm from public.leaves l
     where l.user_id = me.id and l.leave_type = 'Half Day - Personal work' and l.status in ('Pending', 'Approved')
       and date_trunc('month', l.from_day::timestamp) = date_trunc('month', p_from::timestamp);
    if (v_pm + 0.5) > st.leave_personal_max_month * 0.5 then
      raise exception 'Only % personal half day(s) a month', st.leave_personal_max_month;
    end if;
  end if;

  -- overlap: two different halves of the same date are allowed; anything else on the same dates is not
  if exists (select 1 from public.leaves l
              where l.user_id = me.id and l.status in ('Pending', 'Approved') and l.from_day <= p_to and l.to_day >= p_from
                and not (v_half and l.half_part is not null and l.half_part <> p_half)) then
    raise exception 'These dates overlap with another leave request';
  end if;

  insert into public.leaves (user_id, leave_type, from_day, to_day, days, reason, policy_v2, units, half_part, personal_work, certificate_path)
  values (me.id, t.name, p_from, p_to, greatest(1, ceil(v_units))::int, trim(p_reason), true, v_units,
          p_half, case when t.name = 'Half Day - Personal work' then p_personal end, nullif(trim(coalesce(p_certificate, '')), ''))
  returning * into r;
  perform public._audit('LEAVE_REQUEST', t.name || ' ' || p_from || ' to ' || p_to || case when v_half then ' (' || p_half || ' half)' else '' end);
  return r;
end $$;

-- 8. Approve / reject: the balance is deducted only when approved ----------------------------------------------------------------
create or replace function public.review_leave(p_id bigint, p_approve boolean, p_note text default null)
returns public.leaves
language plpgsql security definer set search_path = public as $$
declare
  me    public.profiles := public._require_admin();
  r     public.leaves;
  t     public.leave_types;
  v_bal int;
  v_elig date;
  v_units numeric;
  x     record;
begin
  select * into r from public.leaves where id = p_id for update;
  if r.id is null then raise exception 'Leave request not found'; end if;
  if r.status <> 'Pending' then raise exception 'This request is already %', lower(r.status); end if;

  if p_approve and r.policy_v2 then
    -- NEW policy: allocate every day to EL / CL / SL / Unpaid against the balances of today, then deduct
    select coalesce(sum(pl.units), 0) into v_units from public._lv_plan(r.user_id, r.leave_type, r.from_day, r.to_day, r.half_part) pl where pl.bucket is not null;
    if v_units = 0 then raise exception 'This request has no working days (weekly off / holiday only)'; end if;
    for x in select pl.day, pl.bucket, pl.units from public._lv_plan(r.user_id, r.leave_type, r.from_day, r.to_day, r.half_part) pl where pl.bucket is not null loop
      insert into public.leave_day_alloc (leave_id, user_id, day, bucket, units, half_part)
      values (r.id, r.user_id, x.day, x.bucket, x.units, r.half_part)
      on conflict (leave_id, day, bucket) do nothing;
    end loop;
    for x in select a.bucket, sum(a.units) as u from public.leave_day_alloc a where a.leave_id = r.id and a.bucket <> 'LOP' group by a.bucket loop
      perform public._lv_add(r.user_id, case x.bucket when 'EL' then 'Earned Leave' when 'CL' then 'Casual Leave' else 'Sick Leave' end,
                             r.from_day, 'used', x.u, r.leave_type, r.id, me.id);
    end loop;
    update public.leaves set units = v_units, days = greatest(1, ceil(v_units))::int where id = r.id;
  elsif p_approve then
    -- OLD requests (before this policy): exactly the previous rule
    v_elig := public._leave_eligible_from(r.user_id);
    select coalesce(sum(u.days), 0)::int into r.days
      from public._leave_usage(r.user_id, r.from_day - 10, r.to_day + 10, array['Approved'], r.from_day, r.to_day, r.id) u
     where u.leave_type = 'NEW';
    if r.days = 0 then raise exception 'This request has no working days (weekly off / holiday only)'; end if;
    update public.leaves set days = r.days where id = r.id;
    select * into t from public.leave_types where name = r.leave_type;
    if t.counts_balance and (v_elig is null or r.from_day >= v_elig) then
      select b.balance into v_bal from public._leave_balance(r.user_id, extract(year from r.from_day)::int) b where b.leave_type = r.leave_type;
      if r.days > coalesce(v_bal, 0) then
        raise exception 'Insufficient balance: cannot approve (% day(s) available)', coalesce(v_bal, 0);
      end if;
    end if;
  end if;

  update public.leaves
     set status = case when p_approve then 'Approved' else 'Rejected' end,
         reviewed_by = me.id, reviewed_at = now(), review_note = nullif(trim(p_note), '')
   where id = p_id
  returning * into r;
  perform public._audit(case when p_approve then 'APPROVE_LEAVE' else 'REJECT_LEAVE' end, p_id::text);
  return r;
end $$;

-- Old rule only for OLD requests: new requests are never counted by the old monthly-allowance logic --------------------------------
create or replace function public._leave_usage(
  p_user uuid, p_from date, p_to date,
  p_statuses text[] default array['Approved'],
  p_new_from date default null, p_new_to date default null, p_exclude bigint default null
) returns table (leave_type text, days integer)
language sql stable security definer set search_path = public as $$
  with d as (
    select g::date as day from generate_series(p_from::timestamp, p_to::timestamp, interval '1 day') g
  ),
  info as (
    select d.day,
           public._is_workday(p_user, d.day) as work,
           exists (select 1 from public._holiday_info(p_user, d.day)) as hol,
           case when p_new_from is not null and d.day between p_new_from and p_new_to then 'NEW'
                else (select l.leave_type from public.leaves l
                       where l.user_id = p_user and l.status = any(p_statuses)
                         and not coalesce(l.policy_v2, false)
                         and (p_exclude is null or l.id <> p_exclude)
                         and d.day between l.from_day and l.to_day
                       order by l.id desc limit 1) end as lt
    from d
  ),
  lw as (select day, lt from info where work and lt is not null),
  nw as (select day, hol, day - (row_number() over (order by day))::int as grp from info where not work),
  blocks as (select min(day) as s, max(day) as e, bool_or(hol) as has_hol, count(*) as n from nw group by grp),
  sand as (
    select b.n,
           coalesce(case when nx.lt = 'NEW' then 'NEW' end, case when pv.lt = 'NEW' then 'NEW' end, pv.lt) as lt
    from blocks b
    join lw pv on pv.day = b.s - 1
    join lw nx on nx.day = b.e + 1
    where not b.has_hol
      and coalesce((select s.count_weekly_off_between_leave from public.payroll_settings s where s.id = 1), false)
  )
  select x.lt, sum(x.c)::integer
  from (select lt, count(*) as c from lw group by lt
        union all
        select lt, sum(n) from sand group by lt) x
  group by x.lt
$$;
revoke execute on function public._leave_usage(uuid, date, date, text[], date, date, bigint) from public, anon, authenticated;

-- 9. Monthly credit + year-end lapse (one daily job) -----------------------------------------------------------------------------
create or replace function public._lv_credit_user(p_user uuid, p_asof date) returns void
language plpgsql security definer set search_path = public as $$
declare
  st public.payroll_settings; v_elig date := public._leave_eligible_from(p_user);
  v_month date := date_trunc('month', p_asof::timestamp)::date; v_bal numeric; v_amt numeric; k text; amt numeric;
begin
  select * into st from public.payroll_settings where id = 1;
  if v_elig is null or v_elig > p_asof then return; end if;
  foreach k in array array['Earned Leave', 'Casual Leave', 'Sick Leave'] loop
    if exists (select 1 from public.leave_ledger where employee_id = p_user and leave_type = k and month = v_month and kind = 'credit') then continue; end if;
    amt := case k when 'Earned Leave' then 1 else 0.5 end;
    v_bal := public._lv_bal(p_user, k);
    -- EL is saved up to the cap; at the cap nothing is added until some is used
    v_amt := case when k = 'Earned Leave' then least(amt, greatest(0, st.leave_el_cap - v_bal)) else amt end;
    perform public._lv_add(p_user, k, v_month, 'credit', v_amt, case when v_amt < amt then 'EL balance is at the maximum' else 'Monthly credit' end);
  end loop;
end $$;
revoke execute on function public._lv_credit_user(uuid, date) from public, anon, authenticated;

create or replace function public.run_leave_jobs(p_asof date default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  st public.payroll_settings; v_day date := coalesce(p_asof, public.ist_today()); v_prev date := coalesce(p_asof, public.ist_today()) - 1;
  p record; k text; v_bal numeric; n_cred int := 0; n_lapse int := 0;
begin
  if auth.uid() is not null then perform public._require_full_admin(); end if;      -- cron has no signed-in user
  perform pg_advisory_xact_lock(hashtext('leave_jobs'));
  select * into st from public.payroll_settings where id = 1;

  -- year-end: the morning after the lapse date, unused CL / SL lapse (EL is carried, never lapsed)
  if v_prev = make_date(extract(year from v_prev)::int, st.leave_lapse_month, least(st.leave_lapse_day, 28)) + (st.leave_lapse_day - least(st.leave_lapse_day, 28)) then
    for p in select id from public.profiles loop
      foreach k in array array['Casual Leave', 'Sick Leave'] loop
        v_bal := public._lv_bal(p.id, k);
        if v_bal > 0 and not exists (select 1 from public.leave_ledger where employee_id = p.id and leave_type = k and kind = 'lapse'
                                       and month = date_trunc('month', v_prev::timestamp)::date) then
          perform public._lv_add(p.id, k, v_prev, 'lapse', v_bal, 'Lapsed at year end');
          n_lapse := n_lapse + 1;
        end if;
      end loop;
    end loop;
  end if;

  -- monthly credit for everybody who is eligible (the current month only; never twice; the eligibility day mid-month is covered)
  for p in select id from public.profiles where active loop
    perform public._lv_credit_user(p.id, v_day);
  end loop;
  select count(*) into n_cred from public.leave_ledger where kind = 'credit' and month = date_trunc('month', v_day::timestamp)::date;
  return jsonb_build_object('credited_rows_this_month', n_cred, 'lapsed_now', n_lapse, 'as_of', v_day);
end $$;

-- schedule it daily at 00:05 IST (18:35 UTC) when pg_cron is available; otherwise Admin runs run_leave_jobs() from the Leave policy screen
do $$
begin
  if to_regnamespace('cron') is not null then
    begin
      perform cron.unschedule('leave-jobs');
    exception when others then null;
    end;
    perform cron.schedule('leave-jobs', '35 18 * * *', 'select public.run_leave_jobs()');
  end if;
exception when others then
  raise notice 'pg_cron could not be scheduled (%). Run select public.run_leave_jobs(); every day, or use the button on the Leave policy screen.', sqlerrm;
end $$;

-- 10. Admin: early start, adjust balance, encash EL, policy ------------------------------------------------------------------------
create or replace function public.admin_set_paid_leave_early_start(p_user uuid, p_on boolean, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._require_admin(); emp public.profiles;
begin
  select * into emp from public.profiles where id = p_user;
  if emp.id is null then raise exception 'Employee not found'; end if;
  if p_on then
    if nullif(trim(coalesce(p_reason, '')), '') is null then raise exception 'Enter the reason'; end if;
    update public.profiles set paid_leave_early_from = date_trunc('month', public.ist_today()::timestamp)::date, paid_leave_early_reason = trim(p_reason) where id = p_user;
    perform public._lv_credit_user(p_user, public.ist_today());
  else
    update public.profiles set paid_leave_early_from = null, paid_leave_early_reason = null where id = p_user;
  end if;
  perform public._audit('PAID_LEAVE_EARLY_START', emp.username || ': ' || case when p_on then 'ON - ' || trim(p_reason) else 'OFF' end);
  return public.leave_summary(p_user);
end $$;

create or replace function public.admin_adjust_leave_balance(p_user uuid, p_type text, p_days numeric, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._require_admin();
begin
  if p_type not in ('Earned Leave', 'Casual Leave', 'Sick Leave') then raise exception 'Choose Earned, Casual or Sick leave'; end if;
  if p_days is null or p_days = 0 or abs(p_days) > 60 then raise exception 'Enter the days to add (+) or remove (-)'; end if;
  if nullif(trim(coalesce(p_reason, '')), '') is null then raise exception 'Enter the reason'; end if;
  if public._lv_bal(p_user, p_type) + p_days < 0 then raise exception 'The balance cannot go below 0'; end if;
  perform public._lv_add(p_user, p_type, public.ist_today(), 'adjust', p_days, p_reason, null, me.id);
  perform public._audit('LEAVE_ADJUST', p_type || ' ' || p_days || ': ' || trim(p_reason));
  return public.leave_summary(p_user);
end $$;

create or replace function public.admin_encash_leave(p_user uuid, p_days numeric, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me public.profiles := public._require_admin(); st public.payroll_settings; v_bal numeric; v_amt numeric; v_dim numeric;
begin
  select * into st from public.payroll_settings where id = 1;
  v_bal := public._lv_bal(p_user, 'Earned Leave');
  if p_days is null or p_days <= 0 then raise exception 'Enter the EL days to encash'; end if;
  if p_days > v_bal - st.leave_el_keep_min then
    raise exception 'Only EL above % day(s) can be encashed. Balance % - available to encash %', st.leave_el_keep_min, v_bal, greatest(v_bal - st.leave_el_keep_min, 0);
  end if;
  v_dim := extract(day from (date_trunc('month', public.ist_today()::timestamp) + interval '1 month - 1 day'));
  v_amt := round(coalesce(public._salary_on(p_user, public.ist_today()), 0) / v_dim * p_days, 0);   -- the existing per-day salary value
  perform public._lv_add(p_user, 'Earned Leave', public.ist_today(), 'encash', p_days, p_reason, null, me.id, v_amt);
  perform public._audit('LEAVE_ENCASH', p_days || ' EL day(s), Rs ' || v_amt);
  return public.leave_summary(p_user);
end $$;

create or replace function public.get_leave_policy2() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me public.profiles := public._require_active(); s public.payroll_settings;
begin
  select * into s from public.payroll_settings where id = 1;
  return jsonb_build_object(
    'eligibility_months', s.leave_eligibility_months, 'el_notice_days', s.leave_el_notice_days, 'el_cap', s.leave_el_cap,
    'el_keep_min', s.leave_el_keep_min, 'cl_max_request', s.leave_cl_max_request, 'sl_cert_after', s.leave_sl_cert_after,
    'sl_apply_within', s.leave_sl_apply_within, 'lapse_month', s.leave_lapse_month, 'lapse_day', s.leave_lapse_day,
    'personal_order', s.leave_personal_order, 'personal_max_month', s.leave_personal_max_month);
end $$;

create or replace function public.admin_set_leave_policy2(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._require_full_admin();
begin
  update public.payroll_settings set
    leave_el_notice_days  = coalesce((p->>'el_notice_days')::int, leave_el_notice_days),
    leave_el_cap          = coalesce((p->>'el_cap')::numeric, leave_el_cap),
    leave_el_keep_min     = coalesce((p->>'el_keep_min')::numeric, leave_el_keep_min),
    leave_cl_max_request  = coalesce((p->>'cl_max_request')::numeric, leave_cl_max_request),
    leave_sl_cert_after   = coalesce((p->>'sl_cert_after')::numeric, leave_sl_cert_after),
    leave_sl_apply_within = coalesce((p->>'sl_apply_within')::int, leave_sl_apply_within),
    leave_lapse_month     = coalesce((p->>'lapse_month')::int, leave_lapse_month),
    leave_lapse_day       = coalesce((p->>'lapse_day')::int, leave_lapse_day),
    leave_personal_order  = coalesce(p->>'personal_order', leave_personal_order),
    leave_personal_max_month = case when p ? 'personal_max_month' then nullif(p->>'personal_max_month', '')::int else leave_personal_max_month end,
    leave_eligibility_months = coalesce((p->>'eligibility_months')::int, leave_eligibility_months)
  where id = 1;
  perform public._audit('LEAVE_POLICY2', p::text);
  return public.get_leave_policy2();
end $$;

-- 11. What the screens read ---------------------------------------------------------------------------------------------------------
create or replace function public.leave_summary(p_user uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  me public.profiles := public._require_active(); v_user uuid := coalesce(p_user, me.id);
  st public.payroll_settings; emp public.profiles; v_today date := public.ist_today();
  v_elig date; v_m date := date_trunc('month', public.ist_today()::timestamp)::date; v_y int := extract(year from public.ist_today())::int;
  v_el numeric; v_cl numeric; v_sl numeric; c_el numeric; c_cl numeric; c_sl numeric; v_done int;
begin
  if v_user <> me.id and me.role not in ('HR', 'Admin') then raise exception 'You can only view your own leave' using errcode = '42501'; end if;
  select * into st from public.payroll_settings where id = 1;
  select * into emp from public.profiles where id = v_user;
  v_elig := public._leave_eligible_from(v_user);
  v_el := public._lv_bal(v_user, 'Earned Leave'); v_cl := public._lv_bal(v_user, 'Casual Leave'); v_sl := public._lv_bal(v_user, 'Sick Leave');
  select coalesce(sum(credited), 0) into c_el from public.leave_ledger where employee_id = v_user and leave_type = 'Earned Leave' and month = v_m and kind = 'credit';
  select coalesce(sum(credited), 0) into c_cl from public.leave_ledger where employee_id = v_user and leave_type = 'Casual Leave' and month = v_m and kind = 'credit';
  select coalesce(sum(credited), 0) into c_sl from public.leave_ledger where employee_id = v_user and leave_type = 'Sick Leave' and month = v_m and kind = 'credit';
  v_done := case when emp.joining_date is null then null
                 else greatest(0, (extract(year from age(v_today, emp.joining_date)) * 12 + extract(month from age(v_today, emp.joining_date)))::int) end;
  return jsonb_build_object(
    'joining_date', emp.joining_date, 'eligible_from', v_elig, 'eligible', (v_elig is not null and v_elig <= v_today),
    'months_done', v_done, 'months_total', st.leave_eligibility_months, 'days_left', case when v_elig is null then null else greatest(0, v_elig - v_today) end,
    'early_start', emp.paid_leave_early_from is not null, 'early_reason', emp.paid_leave_early_reason,
    'el', jsonb_build_object('balance', v_el, 'cap', st.leave_el_cap, 'yearly', 12, 'added_this_month', c_el, 'saved_before', greatest(v_el - c_el, 0)),
    'cl', jsonb_build_object('balance', v_cl, 'yearly', 6, 'added_this_month', c_cl,
            'used_year', (select coalesce(sum(used), 0) from public.leave_ledger where employee_id = v_user and leave_type = 'Casual Leave' and extract(year from month) = v_y)),
    'sl', jsonb_build_object('balance', v_sl, 'yearly', 6, 'added_this_month', c_sl,
            'used_year', (select coalesce(sum(used), 0) from public.leave_ledger where employee_id = v_user and leave_type = 'Sick Leave' and extract(year from month) = v_y)),
    'lop_year', (select coalesce(sum(a.units), 0) from public.leave_day_alloc a where a.user_id = v_user and a.bucket = 'LOP' and extract(year from a.day) = v_y),
    'paid_available', v_el + v_cl + v_sl,
    'policy', public.get_leave_policy2());
end $$;

create or replace function public.leave_ledger_rows(p_user uuid default null, p_year int default null)
returns table (month date, leave_type text, kind text, credited numeric, used numeric, lapsed numeric, encashed numeric, adjusted numeric,
               amount numeric, reason text, balance_after numeric, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
declare me public.profiles := public._require_active(); v_user uuid := coalesce(p_user, me.id);
begin
  if v_user <> me.id and me.role not in ('HR', 'Admin') then raise exception 'You can only view your own leave' using errcode = '42501'; end if;
  return query
  select l.month, l.leave_type, l.kind, l.credited, l.used, l.lapsed, l.encashed, l.adjusted, l.amount, l.reason, l.balance_after, l.created_at
    from public.leave_ledger l
   where l.employee_id = v_user and (p_year is null or extract(year from l.month) = p_year)
   order by l.month desc, l.id desc;
end $$;

-- for the approval screen: days ahead, certificate, under 6 months, balance now -> after
create or replace function public.leave_review_info(p_leave bigint) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  me public.profiles := public._require_admin(); r public.leaves; v_elig date;
  b_el numeric; b_cl numeric; b_sl numeric; u_el numeric; u_cl numeric; u_sl numeric; u_lop numeric;
begin
  select * into r from public.leaves where id = p_leave;
  if r.id is null then raise exception 'Leave request not found'; end if;
  v_elig := public._leave_eligible_from(r.user_id);
  b_el := public._lv_bal(r.user_id, 'Earned Leave'); b_cl := public._lv_bal(r.user_id, 'Casual Leave'); b_sl := public._lv_bal(r.user_id, 'Sick Leave');
  select coalesce(sum(units) filter (where bucket = 'EL'), 0), coalesce(sum(units) filter (where bucket = 'CL'), 0),
         coalesce(sum(units) filter (where bucket = 'SL'), 0), coalesce(sum(units) filter (where bucket = 'LOP'), 0)
    into u_el, u_cl, u_sl, u_lop
    from public._lv_plan(r.user_id, r.leave_type, r.from_day, r.to_day, r.half_part) where bucket is not null;
  return jsonb_build_object(
    'policy_v2', r.policy_v2, 'half_part', r.half_part, 'personal_work', r.personal_work, 'units', coalesce(r.units, r.days),
    'days_ahead', (r.from_day - (r.created_at at time zone 'Asia/Kolkata')::date),
    'certificate_path', r.certificate_path, 'under_eligibility', (v_elig is null or r.from_day < v_elig),
    'before', jsonb_build_object('EL', b_el, 'CL', b_cl, 'SL', b_sl),
    'uses', jsonb_build_object('EL', u_el, 'CL', u_cl, 'SL', u_sl, 'LOP', u_lop),
    'after', jsonb_build_object('EL', b_el - u_el, 'CL', b_cl - u_cl, 'SL', b_sl - u_sl));
end $$;

-- how many hours are required today (the app shows "Half Day (morning off), required today 4h")
create or replace function public.my_required_today() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me public.profiles := public._require_active(); v_req int; v_half text; v_type text;
begin
  v_req := (select r.required_minutes from public._rule_for(me.id) r);
  select a.half_part, l.leave_type into v_half, v_type
    from public.leave_day_alloc a join public.leaves l on l.id = a.leave_id
   where a.user_id = me.id and a.day = public.ist_today() and a.half_part is not null
   group by a.half_part, l.leave_type having sum(a.units) = 0.5 limit 1;
  return jsonb_build_object('required_minutes', coalesce(v_req, 480) / case when v_half is not null then 2 else 1 end,
                            'half_part', v_half, 'leave_type', v_type);
exception when undefined_function or undefined_table then
  return jsonb_build_object('required_minutes', 480, 'half_part', null, 'leave_type', null);
end $$;

-- 12. Salary: SAME numbers for old leave, plus the new leave (a half day = 0.5; unpaid half = 0.5 of one day's salary) ---------------------
drop function if exists public.admin_payroll(int, int);
create or replace function public.admin_payroll(p_year int, p_month int)
returns table (
  user_id uuid, username text, full_name text, department text,
  monthly_salary numeric, days_in_month int, present int, absent int,
  leave_days numeric, paid_leave numeric, unpaid_leave numeric, not_joined int, unpaid_days numeric, payable_days numeric,
  overtime_hours numeric, overtime_pay numeric, deduction numeric, net_salary numeric, left_on date,
  unpaid_holiday int
)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare
  st      public.payroll_settings;
  m0      date := make_date(p_year, p_month, 1);
  m1      date := (make_date(p_year, p_month, 1) + interval '1 month - 1 day')::date;
  v_dim   int  := extract(day from (make_date(p_year, p_month, 1) + interval '1 month - 1 day'))::int;
  rec     record;
  v_left  date;
  v_elig  date; v_pre_end date; v_pre int; v_pre_l int; v_pre_lop int;
  v_sal   numeric; v_pres int; v_abs int; v_l int; v_lop int; v_paid numeric; v_unpaid numeric; v_nj int; v_after int;
  v_unpd  numeric; v_work int; v_ot int; v_hr numeric; v_otpay numeric; v_ded numeric; v_shift_h numeric; v_uh int;
  v2_paid numeric; v2_lop numeric; v2_half numeric;
begin
  perform public._require_full_admin();
  select * into st from public.payroll_settings where id = 1;
  for rec in
    select p.*, coalesce(d.resign_date, p.left_on) as left_d
      from public.profiles p left join public.employee_details d on d.user_id = p.id
     where p.active or coalesce(d.resign_date, p.left_on) is not null
     order by p.full_name
  loop
    v_left := rec.left_d;

    if v_left is not null and date_trunc('month', v_left::timestamp) < date_trunc('month', m0::timestamp) then
      return query select rec.id, rec.username, rec.full_name, rec.department, 0::numeric, v_dim, 0, 0,
                          0::numeric, 0::numeric, 0::numeric, 0, v_dim::numeric, 0::numeric, 0::numeric, 0::numeric, 0::numeric, 0::numeric, v_left, 0;
      continue;
    end if;

    select coalesce(avg(public._salary_on(rec.id, g::date)), 0) into v_sal
      from generate_series(m0::timestamp, m1::timestamp, interval '1 day') g;
    v_sal := round(v_sal, 2);

    select count(*) filter (where m.status in ('Present','Checked In')),
           count(*) filter (where m.status = 'Absent' and m.day < public.ist_today()
                                      and m.day >= coalesce(rec.joining_date, date '1900-01-01')
                                      and (v_left is null or m.day <= v_left))
      into v_pres, v_abs
      from public._month_attendance(rec.id, p_year, p_month) m;

    -- OLD leave (requests made before this policy): exactly the previous rule
    v_elig := public._leave_eligible_from(rec.id);
    v_pre_end := case when v_elig is null or v_elig <= m0 then m0 - 1
                      when v_elig > m1 then m1
                      else v_elig - 1 end;
    select s.counted, s.lop into v_pre_l, v_pre_lop from public._leave_days_split(rec.id, m0, v_pre_end) s;
    v_pre := v_pre_l + v_pre_lop;
    select s.counted, s.lop into v_l, v_lop from public._leave_days_split(rec.id, v_pre_end + 1, m1) s;
    v_paid   := least(v_l, st.paid_leaves_per_month);
    v_unpaid := v_pre + (v_l - v_paid) + v_lop;

    -- NEW leave: the days approved under the 24-day policy (paid from EL / CL / SL, or Unpaid) - a half day counts 0.5
    select coalesce(sum(a.units) filter (where a.bucket <> 'LOP'), 0), coalesce(sum(a.units) filter (where a.bucket = 'LOP'), 0)
      into v2_paid, v2_lop
      from public.leave_day_alloc a where a.user_id = rec.id and a.day between m0 and m1;
    -- a half-day leave date on which he did not work at all: the other half is unpaid
    select coalesce(sum(0.5), 0) into v2_half
      from (select a.day from public.leave_day_alloc a
             where a.user_id = rec.id and a.day between m0 and m1 and a.day < public.ist_today() and a.half_part is not null
             group by a.day having sum(a.units) = 0.5
                and not exists (select 1 from public.attendance t where t.user_id = rec.id and t.work_date = a.day and t.check_in_at is not null)) h;
    v_paid   := v_paid + v2_paid;
    v_unpaid := v_unpaid + v2_lop + v2_half;

    v_nj     := case when rec.joining_date is null or rec.joining_date <= m0 then 0
                     else (least(rec.joining_date, m1 + 1) - m0) end;
    v_after  := case when v_left is not null and v_left < m1 then (m1 - v_left) else 0 end;
    v_uh     := public._unpaid_holiday_days(rec.id, greatest(m0, coalesce(rec.joining_date, m0)), least(m1, coalesce(v_left, m1)));
    v_unpd   := least(v_dim, v_abs + v_unpaid + v_nj + v_after + v_uh);

    select count(*) into v_work
      from generate_series(m0::timestamp, m1::timestamp, interval '1 day') g
     where public._is_workday(rec.id, g::date);
    v_shift_h := extract(epoch from (rec.shift_end - rec.shift_start)) / 3600;
    select coalesce(sum(o.ot_minutes), 0) into v_ot from public._month_overtime(rec.id, p_year, p_month) o;

    v_hr    := case when v_work > 0 and v_shift_h > 0 then v_sal / (v_work * v_shift_h) else 0 end;
    v_otpay := round(v_ot / 60.0 * v_hr * st.overtime_multiplier, 2);
    v_ded   := round(v_sal / v_dim * v_unpd, 0);          -- nearest rupee

    return query select rec.id, rec.username, rec.full_name, rec.department, v_sal, v_dim, v_pres, v_abs,
                        (v_pre + v_l + v_lop)::numeric + v2_paid + v2_lop, v_paid, v_unpaid, v_nj, v_unpd, v_dim - v_unpd,
                        round(v_ot / 60.0, 2), v_otpay, v_ded, round(v_sal - v_ded + v_otpay, 2), v_left, v_uh;
  end loop;
end $$;

-- 13. Permissions ----------------------------------------------------------------------------------------------------------------------
revoke all on function public.leave_preview_v2(text, date, date, text, uuid)                        from public, anon;
revoke all on function public.apply_leave(text, date, date, text, text, text, text)                 from public, anon;
revoke all on function public.review_leave(bigint, boolean, text)                                   from public, anon;
revoke all on function public.run_leave_jobs(date)                                                  from public, anon;
revoke all on function public.admin_set_paid_leave_early_start(uuid, boolean, text)                 from public, anon;
revoke all on function public.admin_adjust_leave_balance(uuid, text, numeric, text)                 from public, anon;
revoke all on function public.admin_encash_leave(uuid, numeric, text)                               from public, anon;
revoke all on function public.get_leave_policy2()                                                   from public, anon;
revoke all on function public.admin_set_leave_policy2(jsonb)                                        from public, anon;
revoke all on function public.leave_summary(uuid)                                                   from public, anon;
revoke all on function public.leave_ledger_rows(uuid, int)                                          from public, anon;
revoke all on function public.leave_review_info(bigint)                                             from public, anon;
revoke all on function public.my_required_today()                                                   from public, anon;
revoke all on function public.admin_payroll(int, int)                                               from public, anon;
grant execute on function public.leave_preview_v2(text, date, date, text, uuid)                     to authenticated;
grant execute on function public.apply_leave(text, date, date, text, text, text, text)              to authenticated;
grant execute on function public.review_leave(bigint, boolean, text)                                to authenticated;
grant execute on function public.run_leave_jobs(date)                                               to authenticated;
grant execute on function public.admin_set_paid_leave_early_start(uuid, boolean, text)              to authenticated;
grant execute on function public.admin_adjust_leave_balance(uuid, text, numeric, text)              to authenticated;
grant execute on function public.admin_encash_leave(uuid, numeric, text)                            to authenticated;
grant execute on function public.get_leave_policy2()                                                to authenticated;
grant execute on function public.admin_set_leave_policy2(jsonb)                                     to authenticated;
grant execute on function public.leave_summary(uuid)                                                to authenticated;
grant execute on function public.leave_ledger_rows(uuid, int)                                       to authenticated;
grant execute on function public.leave_review_info(bigint)                                          to authenticated;
grant execute on function public.my_required_today()                                                to authenticated;
grant execute on function public.admin_payroll(int, int)                                            to authenticated;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------
-- AFTER YOU HAVE SEEN leave_policy_preview.sql AND APPROVED THE OPENING BALANCES (nothing below runs by itself):
--   select public.run_leave_jobs();                         -- credits THIS month for every eligible employee (never twice)
--   -- opening balances, one employee / one type at a time (Admin screen "Adjust balance" does the same):
--   -- select public.admin_adjust_leave_balance('<employee uuid>', 'Earned Leave', 4, 'Opening balance from old Annual Leave');
-- UNDO (nothing is deleted; new requests go back to the old types): update public.leave_types set active = true where name in ('Annual Leave', 'Compensatory Off', 'Monthly Paid Leave');
-- ---------------------------------------------------------------------
