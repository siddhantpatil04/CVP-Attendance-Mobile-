-- =====================================================================
-- EMPLOYEE REGISTRATION AND LOGIN APPROVAL WORKFLOW   (run this ONE file; safe to run again)
--
--   1. "New employee? Register": the employee types the Full Name and ONE contact - the e-mail ID or the mobile number -
--      that HR / Admin saved in the employee record. The details are matched with that record.
--   2. A code is sent to that e-mail / mobile number (Supabase Auth). The employee types it.
--   3. The verified request goes to "Pending Login Approvals" (HR and Admin): Approve or Reject.
--   4. Only after approval the employee opens "Check status / Create login", gets a code again and creates the
--      Username, Password and Confirm Password. The password is saved by Supabase Auth only; nobody can see it.
--   5. HR / Admin see username, account status, verification, approval and login status - never the password.
--   6. Login works only after approval AND account creation.
--
--   Employee sees:  Pending Verification -> Pending Approval -> Approved - Create Login -> Active   (or Rejected)
--
--   Needs in Supabase Dashboard -> Authentication:
--     * Providers -> Email: enabled; the "Confirm signup" and "Magic Link" templates must contain {{ .Token }} (the code)
--     * Providers -> Phone: enabled with an SMS provider, only if employees verify with a mobile number
--     * "Allow new users to sign up" ON (a person who verifies a code gets an inactive helper account that is deleted
--       when the login is created)
-- =====================================================================
alter table public.profiles add column if not exists login_claimed boolean not null default true;
alter table public.profiles add column if not exists email text;

create or replace function public._phone_key(p text) returns text
language sql immutable as $$
  select right(regexp_replace(coalesce(p, ''), '\D', '', 'g'), 10)
$$;
revoke execute on function public._phone_key(text) from public, anon, authenticated;

create or replace function public._norm(p text) returns text
language sql immutable as $$
  select lower(regexp_replace(trim(coalesce(p, '')), '\s+', ' ', 'g'))
$$;

-- ---------------------------------------------------------------------
-- 1. Registration requests
-- ---------------------------------------------------------------------
create table if not exists public.employee_registrations (
  id                bigint generated always as identity primary key,
  employee_id       uuid not null references public.profiles(id) on delete cascade,   -- the record made by Admin / HR
  verifier_id       uuid,                                                              -- the Auth user that verified the code
  channel           text,
  full_name         text not null,
  mobile            text,
  email             text,
  department        text,
  designation       text,
  email_verified_at timestamptz,
  phone_verified_at timestamptz,
  status            text not null default 'Pending Verification'
                      check (status in ('Pending Verification', 'Pending Approval', 'Approved', 'Active', 'Rejected')),
  created_at        timestamptz not null default now(),
  submitted_at      timestamptz,
  reviewed_by       uuid references public.profiles(id),
  reviewed_at       timestamptz,
  review_note       text,
  login_created_at  timestamptz
);
alter table public.employee_registrations add column if not exists channel text;
alter table public.employee_registrations alter column mobile drop not null;
alter table public.employee_registrations alter column email drop not null;
create unique index if not exists employee_registrations_open_idx on public.employee_registrations (employee_id)
  where status in ('Pending Verification', 'Pending Approval', 'Approved');
create index if not exists employee_registrations_status_idx on public.employee_registrations (status, id desc);
create index if not exists employee_registrations_verifier_idx on public.employee_registrations (verifier_id);

alter table public.employee_registrations enable row level security;
drop policy if exists employee_registrations_read on public.employee_registrations;
create policy employee_registrations_read on public.employee_registrations for select to authenticated
  using (private.is_staff_admin());
-- nobody writes to the table directly: only the functions below
revoke all on public.employee_registrations from anon, authenticated;
grant select on public.employee_registrations to authenticated;

do $$
begin
  if not exists (select 1 from pg_publication_tables
                  where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'employee_registrations') then
    alter publication supabase_realtime add table public.employee_registrations;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 2. Matching with the employee record made by Admin / HR
-- ---------------------------------------------------------------------
-- the one active employee record with this e-mail / mobile number (read from what Admin / HR saved in the app)
create or replace function public._registration_match2(p_channel text, p_contact text, p_name text) returns uuid
language plpgsql stable security definer set search_path = public as $$
declare ids uuid[]; k text; v text;
begin
  if p_channel = 'mobile' then
    k := right(regexp_replace(coalesce(p_contact, ''), '\D', '', 'g'), 10);
    if length(k) < 10 then return null; end if;
    select array_agg(distinct p.id) into ids
      from public.profiles p left join public.employee_details d on d.user_id = p.id
     where p.role = 'Employee' and p.active
       and (right(regexp_replace(coalesce(p.phone, ''), '\D', '', 'g'), 10) = k
         or right(regexp_replace(coalesce(d.cell_no, ''), '\D', '', 'g'), 10) = k);
  elsif p_channel = 'email' then
    v := lower(trim(coalesce(p_contact, '')));
    if v !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then return null; end if;
    select array_agg(distinct p.id) into ids
      from public.profiles p left join public.employee_details d on d.user_id = p.id
     where p.role = 'Employee' and p.active
       and (lower(coalesce(d.email, '')) = v or lower(coalesce(p.email, '')) = v);
  else
    return null;
  end if;
  if coalesce(array_length(ids, 1), 0) <> 1 then return null; end if;
  return ids[1];
end $$;
revoke execute on function public._registration_match2(text, text, text) from public, anon, authenticated;

-- Before sign-in: do the details match? (true / false only: nothing about the record is revealed)
drop function if exists public.check_registration_details(text, text);
create or replace function public.check_registration_details(p_channel text, p_contact text, p_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select public._registration_match2(lower(trim(coalesce(p_channel, ''))), p_contact, p_name) is not null
$$;
revoke execute on function public.check_registration_details(text, text, text) from public;
grant  execute on function public.check_registration_details(text, text, text) to anon, authenticated;

-- ---------------------------------------------------------------------
-- 3. The employee: code verified -> the request goes to HR / Admin
-- ---------------------------------------------------------------------
create or replace function public.start_registration(p_channel text, p_contact text, p_name text) returns text
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  au auth.users;
  e uuid;
  emp public.profiles;
  ch text := lower(trim(coalesce(p_channel, '')));
  v_email text := null;
  v_mobile text := null;
  r public.employee_registrations;
begin
  if uid is null then raise exception 'Verify the code first' using errcode = '28000'; end if;
  if ch not in ('email', 'mobile') then raise exception 'Choose e-mail or mobile number'; end if;
  select * into au from auth.users where id = uid;
  if ch = 'email' then
    v_email := lower(trim(coalesce(p_contact, '')));
    if au.email_confirmed_at is null or lower(coalesce(au.email, '')) <> v_email then
      raise exception 'Verify your e-mail with the code first';
    end if;
  else
    v_mobile := public._phone_key(p_contact);
    if au.phone_confirmed_at is null or public._phone_key(au.phone) <> v_mobile then
      raise exception 'Verify your mobile number with the code first';
    end if;
  end if;

  e := public._registration_match2(ch, p_contact, p_name);
  if e is null then
    raise exception 'These details do not match an employee record that is waiting for a login. Check them, or ask HR / Admin';
  end if;
  if e = uid then raise exception 'Not allowed'; end if;
  select * into emp from public.profiles where id = e;

  -- the same e-mail address cannot belong to two employees
  if v_email is not null and (
       exists (select 1 from public.employee_registrations x
                where lower(coalesce(x.email, '')) = v_email and x.employee_id <> e and x.status in ('Pending Approval', 'Approved', 'Active'))
    ) then
    raise exception 'This e-mail address is already used by another employee';
  end if;

  select * into r from public.employee_registrations
   where employee_id = e and status in ('Pending Verification', 'Pending Approval', 'Approved') for update;
  if r.id is not null and r.status = 'Pending Approval' then
    raise exception 'Your registration is already waiting for HR / Admin approval';
  elsif r.id is not null and r.status = 'Approved' then
    raise exception 'Your registration is already approved. Use "Check status / Create login"';
  elsif r.id is not null then
    update public.employee_registrations
       set verifier_id = uid, channel = ch, status = 'Pending Approval', submitted_at = now(),
           email = v_email, mobile = coalesce(v_mobile, public._phone_key(emp.phone)),
           email_verified_at = case when ch = 'email' then au.email_confirmed_at end,
           phone_verified_at = case when ch = 'mobile' then au.phone_confirmed_at end
     where id = r.id;
  else
    insert into public.employee_registrations
      (employee_id, verifier_id, channel, full_name, mobile, email, department, designation, email_verified_at, phone_verified_at, status, submitted_at)
    values (e, uid, ch, emp.full_name, coalesce(v_mobile, public._phone_key(emp.phone)), v_email, emp.department, emp.designation,
            case when ch = 'email' then au.email_confirmed_at end, case when ch = 'mobile' then au.phone_confirmed_at end,
            'Pending Approval', now());
  end if;
  insert into public.audit_log (actor_id, action, detail) values (e, 'REGISTRATION_REQUEST', emp.full_name || ' (' || ch || ')');
  return 'Pending Approval';
end $$;

-- The employee (signed in with the code): where is my request?
drop function if exists public.my_registration();
create or replace function public.my_registration()
returns table (id bigint, status text, full_name text, email text, mobile text, review_note text,
               submitted_at timestamptz, reviewed_at timestamptz, message text)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  if auth.uid() is null then raise exception 'Verify the code first' using errcode = '28000'; end if;
  return query
  select r.id, r.status, r.full_name, r.email, r.mobile, r.review_note, r.submitted_at, r.reviewed_at,
         case r.status
           when 'Pending Verification' then 'Register again to send your request to HR / Admin.'
           when 'Pending Approval'     then 'Your request is waiting for HR / Admin approval.'
           when 'Approved'             then 'Approved. Create your username and password now.'
           when 'Active'               then 'Your login is active. Sign in with your username and password.'
           when 'Rejected'             then 'Your request was rejected.' || coalesce(' Reason: ' || nullif(r.review_note, ''), '') || ' Contact HR / Admin.'
         end
    from public.employee_registrations r
   where r.verifier_id = auth.uid()
   order by r.id desc limit 1;
end $$;

-- A code verified for "Check status": link the helper account to the request that has this e-mail / mobile number
create or replace function public.claim_registration_status(p_channel text, p_contact text) returns text
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid(); au auth.users; r public.employee_registrations;
  ch text := lower(trim(coalesce(p_channel, '')));
begin
  if uid is null then raise exception 'Verify the code first' using errcode = '28000'; end if;
  select * into au from auth.users where id = uid;
  if ch = 'email' then
    if au.email_confirmed_at is null or lower(coalesce(au.email, '')) <> lower(trim(coalesce(p_contact, ''))) then
      raise exception 'Verify your e-mail with the code first';
    end if;
    select * into r from public.employee_registrations
     where lower(coalesce(email, '')) = lower(trim(p_contact)) order by id desc limit 1 for update;
  elsif ch = 'mobile' then
    if au.phone_confirmed_at is null or public._phone_key(au.phone) <> public._phone_key(p_contact) then
      raise exception 'Verify your mobile number with the code first';
    end if;
    select * into r from public.employee_registrations
     where mobile = public._phone_key(p_contact) order by id desc limit 1 for update;
  else
    raise exception 'Choose e-mail or mobile number';
  end if;
  if r.id is null then raise exception 'No registration was found for this contact. Register first'; end if;
  -- the request must have been verified with the same kind of contact
  if r.channel is distinct from ch then raise exception 'Use the same e-mail / mobile number you registered with'; end if;
  update public.employee_registrations set verifier_id = uid where id = r.id;
  return r.status;
end $$;

-- ---------------------------------------------------------------------
-- 4. HR / Admin: approve or reject
-- ---------------------------------------------------------------------
create or replace function public.review_registration_request(p_id bigint, p_approve boolean, p_note text default null) returns text
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._require_admin(); r public.employee_registrations;
begin
  select * into r from public.employee_registrations where id = p_id for update;
  if r.id is null then raise exception 'Request not found'; end if;
  if r.status <> 'Pending Approval' then raise exception 'This request is already %', lower(r.status); end if;
  if r.employee_id = me.id then raise exception 'You cannot review your own request'; end if;
  update public.employee_registrations
     set status = case when p_approve then 'Approved' else 'Rejected' end,
         reviewed_by = me.id, reviewed_at = now(), review_note = nullif(trim(coalesce(p_note, '')), '')
   where id = p_id;
  perform public._audit(case when p_approve then 'APPROVE_REGISTRATION_REQUEST' else 'REJECT_REGISTRATION_REQUEST' end, r.full_name);
  return case when p_approve then 'Approved' else 'Rejected' end;
end $$;

-- ---------------------------------------------------------------------
-- 5. The employee, after approval: create the username and password
-- ---------------------------------------------------------------------
create or replace function public.complete_registration_login(p_username text, p_password text, p_confirm text) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare
  uid uuid := auth.uid();
  r public.employee_registrations;
  v_u text := lower(trim(coalesce(p_username, '')));
begin
  if uid is null then raise exception 'Verify the code first' using errcode = '28000'; end if;
  select * into r from public.employee_registrations
   where verifier_id = uid and status = 'Approved' order by id desc limit 1 for update;
  if r.id is null then raise exception 'Your registration is not approved yet'; end if;

  if v_u !~ '^[a-z0-9._-]{2,40}$' then
    raise exception 'Username may contain letters, numbers, dot, dash and underscore (2-40 characters)';
  end if;
  if v_u like 'pending-%' then raise exception 'Choose another username'; end if;
  if p_password is distinct from p_confirm then raise exception 'The two passwords are not the same'; end if;
  if length(coalesce(p_password, '')) < 12 then raise exception 'The password must be at least 12 characters'; end if;
  if p_password !~ '[A-Z]' or p_password !~ '[a-z]' or p_password !~ '[0-9]' or p_password !~ '[^A-Za-z0-9]' then
    raise exception 'The password needs an upper-case letter, a lower-case letter, a number and a special character';
  end if;
  if length(v_u) >= 3 and position(v_u in lower(p_password)) > 0 then raise exception 'The password must not contain the username'; end if;
  if exists (select 1 from public.profiles where lower(username) = v_u and id <> r.employee_id) then
    raise exception 'This username is already taken. Choose another one';
  end if;
  if not exists (select 1 from public.profiles where id = r.employee_id and role = 'Employee' and active) then
    raise exception 'This employee record is no longer active';
  end if;

  begin
    update public.profiles set username = v_u, login_claimed = true, email = coalesce(r.email, email) where id = r.employee_id;
  exception when unique_violation then
    raise exception 'This username is already taken. Choose another one';
  end;
  -- the password is saved by Supabase Auth only (bcrypt hash); it is never stored anywhere else
  update auth.users set encrypted_password = crypt(p_password, gen_salt('bf')), updated_at = now() where id = r.employee_id;
  update public.employee_registrations set status = 'Active', login_created_at = now() where id = r.id;
  insert into public.audit_log (actor_id, action, detail) values (r.employee_id, 'LOGIN_CREATED', v_u);

  -- the helper account that proved the e-mail / mobile number is no longer needed
  begin
    delete from auth.users where id = uid;
  exception when others then
    update public.profiles set active = false where id = uid;
  end;
  return v_u;
end $$;

-- ---------------------------------------------------------------------
-- 6. HR / Admin: registration and login status of every employee (never the password)
-- ---------------------------------------------------------------------
drop function if exists public.admin_login_overview();
create or replace function public.admin_login_overview()
returns table (
  user_id uuid, username text, role text, active boolean, login_claimed boolean, reg_id bigint, reg_status text, email text,
  email_verified boolean, phone_verified boolean, approval text, reviewed_at timestamptz, account_created_at timestamptz
)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  perform public._require_admin();
  return query
  select p.id,
         case when p.login_claimed then p.username else null end,
         p.role, p.active, p.login_claimed, r.id, r.status,
         coalesce(r.email, p.email),
         (r.email_verified_at is not null),
         (r.phone_verified_at is not null),
         case when r.status in ('Pending Approval') then 'Pending'
              when r.status in ('Approved', 'Active') then 'Approved'
              when r.status = 'Rejected' then 'Rejected' end,
         r.reviewed_at,
         coalesce(r.login_created_at, case when p.login_claimed then p.created_at end)
    from public.profiles p
    left join lateral (select x.* from public.employee_registrations x where x.employee_id = p.id order by x.id desc limit 1) r on true
   where p.approval_status = 'Approved' and p.reg_submitted
   order by p.full_name;
end $$;

-- ---------------------------------------------------------------------
-- 7. Grants; the older routes that skip the approval are switched off
-- ---------------------------------------------------------------------
revoke execute on function public.start_registration(text, text, text) from public, anon;
revoke execute on function public.my_registration() from public, anon;
revoke execute on function public.claim_registration_status(text, text) from public, anon;
revoke execute on function public.review_registration_request(bigint, boolean, text) from public, anon;
revoke execute on function public.complete_registration_login(text, text, text) from public, anon;
revoke execute on function public.admin_login_overview() from public, anon;
grant  execute on function public.start_registration(text, text, text) to authenticated;
grant  execute on function public.my_registration() to authenticated;
grant  execute on function public.claim_registration_status(text, text) to authenticated;
grant  execute on function public.review_registration_request(bigint, boolean, text) to authenticated;
grant  execute on function public.complete_registration_login(text, text, text) to authenticated;
grant  execute on function public.admin_login_overview() to authenticated;

do $$
declare f text;
begin
  foreach f in array array[
    'public.request_login(text)',
    'public.register_with_mobile(text, text, text)',
    'public.register_with_mobile(text, text, text, text)',
    'public.submit_registration(text, text, text, text, text, text)',
    'public.complete_self_registration(text, text, text, text, text)'
  ] loop
    if to_regprocedure(f) is not null then
      execute format('revoke execute on function %s from public, anon, authenticated', f);
    end if;
  end loop;
end $$;

notify pgrst, 'reload schema';
