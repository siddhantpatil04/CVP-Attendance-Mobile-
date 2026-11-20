-- =====================================================================
-- RUN THIS ONE FILE for the Holiday Setup update (database already set up). No safety lock, safe to run again.
-- It contains, in order: 1) holiday_setup.sql   2) leave_eligibility.sql (payroll that counts unpaid holidays).
-- Supabase -> SQL Editor -> "+" New query (empty box) -> paste this whole file -> Run.
-- Do NOT use cvp_attendance_schema.sql for this: that file is only for a new, empty database.
-- =====================================================================
-- ########## PART 1: HOLIDAY SETUP ##########
-- =====================================================================
-- HOLIDAY SETUP: holidays for Site employees / Office employees, for everyone in a category or for selected employees,
--                PAID or UNPAID.
--   * The old company-wide holidays (table "holidays") are NOT changed: they still apply to everybody and are always paid.
--   * New holidays are saved in "employee_holidays" (+ "employee_holiday_users" for a list of selected employees).
--       Category : Site (site / selfie employees)  or  Office (office employees)
--       Selection: all employees of that category, or only the selected employees
--       Type     : Paid  = a normal holiday: not Absent, no salary deduction, work on it is overtime
--                  Unpaid = a holiday without pay: not Absent, but the day's salary IS deducted in payroll
--   * The attendance calendar, the live board, the leave rules (a holiday is not a leave day) and the payroll use these holidays
--     by themselves, only for the employees they apply to.
--   * Only Admin / HR add, edit and delete. An employee sees only the holidays that apply to him.
-- Run in Supabase Dashboard -> SQL Editor -> New query -> Run.  Safe to run again.
-- Then run leave_eligibility.sql AGAIN: its payroll function counts the unpaid holiday days.
-- Needs cvp_attendance_schema.sql (with its security clean-up, section 44) to be run before.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------
create table if not exists public.employee_holidays (
  id             bigint generated always as identity primary key,
  day            date not null,
  name           text not null check (length(trim(name)) > 0),
  category       text not null check (category in ('Site', 'Office')),
  holiday_type   text not null default 'Paid' check (holiday_type in ('Paid', 'Unpaid')),
  all_employees  boolean not null default true,      -- true = every employee of the category, false = only the selected ones
  created_by     uuid references public.profiles(id) on delete set null,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create index if not exists employee_holidays_day_idx on public.employee_holidays (day);

create table if not exists public.employee_holiday_users (
  holiday_id  bigint not null references public.employee_holidays(id) on delete cascade,
  user_id     uuid   not null references public.profiles(id) on delete cascade,
  primary key (holiday_id, user_id)
);
create index if not exists employee_holiday_users_user_idx on public.employee_holiday_users (user_id);

alter table public.employee_holidays      enable row level security;
alter table public.employee_holiday_users enable row level security;

-- Admin / HR see everything; an employee sees only the holidays that apply to him
drop policy if exists employee_holidays_read on public.employee_holidays;
create policy employee_holidays_read on public.employee_holidays for select to authenticated
  using (
    private.is_staff_admin()
    or exists (select 1 from public.employee_holiday_users u where u.holiday_id = employee_holidays.id and u.user_id = auth.uid())
    or (all_employees and category = (select case when p.site_employee then 'Site' else 'Office' end
                                        from public.profiles p where p.id = auth.uid()))
  );
drop policy if exists employee_holiday_users_read on public.employee_holiday_users;
create policy employee_holiday_users_read on public.employee_holiday_users for select to authenticated
  using (private.is_staff_admin() or user_id = auth.uid());

-- nobody writes directly: only admin_save_holiday() / admin_delete_holiday() below
revoke all on public.employee_holidays, public.employee_holiday_users from anon, authenticated;
grant select on public.employee_holidays, public.employee_holiday_users to authenticated;

do $$
declare t text;
begin
  foreach t in array array['employee_holidays', 'employee_holiday_users'] loop
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- 2. The holiday of one person on one day (null row = no holiday). A holiday made for him (selected, or his category) comes first,
--    then the company-wide holidays. If two apply, the Paid one wins.
-- ---------------------------------------------------------------------
create or replace function public._holiday_info(p_user uuid, p_day date)
returns table (name text, htype text)
language sql stable security definer set search_path = public as $$
  select x.name, x.htype
    from (
      select eh.name, eh.holiday_type as htype, 0 as pri
        from public.employee_holidays eh
       where eh.day = p_day
         and (exists (select 1 from public.employee_holiday_users u where u.holiday_id = eh.id and u.user_id = p_user)
              or (eh.all_employees and eh.category = (select case when p.site_employee then 'Site' else 'Office' end
                                                         from public.profiles p where p.id = p_user)))
      union all
      select h.name, 'Paid', 1 from public.holidays h where h.day = p_day
    ) x
   order by x.pri, (x.htype = 'Unpaid')
   limit 1
$$;
revoke execute on function public._holiday_info(uuid, date) from public, anon, authenticated;

-- Unpaid holiday days of one person between two dates (weekly offs are not counted twice). Safe before this file was run.
create or replace function public._unpaid_holiday_days(p_user uuid, p_from date, p_to date) returns int
language plpgsql stable security definer set search_path = public as $$
begin
  if to_regclass('public.employee_holidays') is null or p_to < p_from then return 0; end if;
  return (select count(*)::int
            from generate_series(p_from::timestamp, p_to::timestamp, interval '1 day') g
           where not public._is_weekly_off(p_user, g::date)
             and exists (select 1 from public._holiday_info(p_user, g::date) i where i.htype = 'Unpaid'));
end $$;
revoke execute on function public._unpaid_holiday_days(uuid, date, date) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 3. Admin / HR: add, edit, delete
-- ---------------------------------------------------------------------
create or replace function public.admin_save_holiday(
  p_id bigint, p_day date, p_name text, p_category text, p_type text, p_all boolean, p_users uuid[] default '{}'
) returns public.employee_holidays
language plpgsql security definer set search_path = public as $$
declare
  me public.profiles := public._require_admin();
  r  public.employee_holidays;
  v_users uuid[];
  v_bad int;
begin
  if p_day is null then raise exception 'Choose the holiday date'; end if;
  if nullif(trim(p_name), '') is null then raise exception 'Enter the holiday name'; end if;
  if p_category not in ('Site', 'Office') then raise exception 'Choose Site Employees or Office Employees'; end if;
  if p_type not in ('Paid', 'Unpaid') then raise exception 'Choose Paid or Unpaid'; end if;

  select coalesce(array_agg(distinct x), '{}') into v_users from unnest(coalesce(p_users, '{}')) x;
  if not coalesce(p_all, true) then
    if coalesce(array_length(v_users, 1), 0) = 0 then raise exception 'Select at least one employee'; end if;
    select count(*) into v_bad from unnest(v_users) x
     where not exists (select 1 from public.profiles p
                        where p.id = x and p.active and (case when p.site_employee then 'Site' else 'Office' end) = p_category);
    if v_bad > 0 then raise exception 'Some selected employees do not belong to the % category', lower(p_category); end if;
  end if;

  if p_id is null then
    insert into public.employee_holidays (day, name, category, holiday_type, all_employees, created_by)
    values (p_day, trim(p_name), p_category, p_type, coalesce(p_all, true), me.id) returning * into r;
  else
    update public.employee_holidays
       set day = p_day, name = trim(p_name), category = p_category, holiday_type = p_type,
           all_employees = coalesce(p_all, true), updated_at = now()
     where id = p_id returning * into r;
    if r.id is null then raise exception 'Holiday not found'; end if;
  end if;

  delete from public.employee_holiday_users where holiday_id = r.id;
  if not r.all_employees then
    insert into public.employee_holiday_users (holiday_id, user_id) select r.id, x from unnest(v_users) x;
  end if;
  perform public._audit(case when p_id is null then 'CREATE_EMPLOYEE_HOLIDAY' else 'UPDATE_EMPLOYEE_HOLIDAY' end,
    r.day::text || ' ' || r.name || ' (' || r.category || ', ' || r.holiday_type || ', '
    || case when r.all_employees then 'all' else coalesce(array_length(v_users, 1), 0)::text || ' selected' end || ')');
  return r;
end $$;

create or replace function public.admin_delete_holiday(p_id bigint) returns text
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._require_admin(); r public.employee_holidays;
begin
  delete from public.employee_holidays where id = p_id returning * into r;
  if r.id is null then raise exception 'Holiday not found'; end if;
  perform public._audit('DELETE_EMPLOYEE_HOLIDAY', r.day::text || ' ' || r.name);
  return r.name;
end $$;

revoke execute on function public.admin_save_holiday(bigint, date, text, text, text, boolean, uuid[]) from public, anon;
revoke execute on function public.admin_delete_holiday(bigint) from public, anon;
grant  execute on function public.admin_save_holiday(bigint, date, text, text, text, boolean, uuid[]) to authenticated;
grant  execute on function public.admin_delete_holiday(bigint) to authenticated;

-- ---------------------------------------------------------------------
-- 4. A working day: not a weekly off and not a holiday that applies to this person
-- ---------------------------------------------------------------------
create or replace function public._is_workday(p_user uuid, p_day date) returns boolean
language sql stable security definer set search_path = public as $$
  select not public._is_weekly_off(p_user, p_day)
     and not exists (select 1 from public._holiday_info(p_user, p_day))
$$;

-- Leave days: a holiday that applies to the person is not a leave day (and it cancels a sandwich), as before
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
  )
  select x.lt, sum(x.c)::integer
  from (select lt, count(*) as c from lw group by lt
        union all
        select lt, sum(n) from sand group by lt) x
  group by x.lt
$$;

-- ---------------------------------------------------------------------
-- 5. Attendance calendar of a month ("Holiday" status; an unpaid holiday says so in the note)
-- ---------------------------------------------------------------------
create or replace function public._month_attendance(p_user uuid, p_year int, p_month int)
returns table (
  day date, dow text, status text, in_time text, out_time text,
  hours numeric, is_late boolean, notes text, source text, site_name text
)
language sql stable security definer set search_path = public as $$
  with d as (
    select g::date as day
    from generate_series(make_date(p_year, p_month, 1)::timestamp,
                         (make_date(p_year, p_month, 1) + interval '1 month - 1 day'),
                         interval '1 day') g
  )
  select d.day,
         to_char(d.day, 'Dy'),
         case when d.day > public.ist_today()       then 'Upcoming'
              when h.name is not null               then 'Holiday'
              when lv.leave_type is not null        then 'Leave'
              when a.check_out_at is not null       then 'Present'
              when a.check_in_at  is not null       then 'Checked In'
              when tr.city is not null and public._is_workday(p_user, d.day) then 'Present'
              when public._is_weekly_off(p_user, d.day) then 'Rest Day'
              else 'Absent' end,
         to_char(a.check_in_at  at time zone 'Asia/Kolkata', 'HH24:MI'),
         to_char(a.check_out_at at time zone 'Asia/Kolkata', 'HH24:MI'),
         round(a.work_minutes / 60.0, 2),
         coalesce(a.is_late, false),
         coalesce(case when h.htype = 'Unpaid' then 'Unpaid holiday - ' || h.name else h.name end,
                  lv.leave_type, 'Tour - ' || tr.city, ''),
         a.source,
         a.site_name
  from d
  left join public.attendance a on a.user_id = p_user and a.work_date = d.day
  left join lateral (select i.name, i.htype from public._holiday_info(p_user, d.day) i limit 1) h on true
  left join lateral (
    select l.leave_type from public.leaves l
     where l.user_id = p_user and l.status = 'Approved'
       and d.day between l.from_day and l.to_day
     order by l.id desc limit 1) lv on true
  left join lateral (
    select t.city from public.tours t
     where t.user_id = p_user and t.status = 'Approved'
       and d.day between t.from_day and t.to_day
     order by t.id desc limit 1) tr on true
  order by d.day
$$;

-- ---------------------------------------------------------------------
-- 6. Live board: an employee on a holiday that applies to him shows "Holiday"
-- ---------------------------------------------------------------------
create or replace function public.admin_today_board(p_date date default null)
returns table (
  user_id uuid, username text, full_name text, department text, role text,
  site_employee boolean, shift_start time,
  check_in_at timestamptz, check_out_at timestamptz,
  in_time text, out_time text, status text, is_late boolean,
  work_minutes int, source text, site_name text, leave_type text
)
language plpgsql stable security definer set search_path = public as $$
declare
  v_day date := coalesce(p_date, public.ist_today());
begin
  perform public._require_admin();
  return query
  select p.id, p.username, p.full_name, p.department, p.role,
         p.site_employee, p.shift_start,
         a.check_in_at, a.check_out_at,
         to_char(a.check_in_at  at time zone 'Asia/Kolkata', 'HH24:MI'),
         to_char(a.check_out_at at time zone 'Asia/Kolkata', 'HH24:MI'),
         case when a.check_out_at is not null then 'Present'
              when a.check_in_at  is not null then 'Checked In'
              when lv.leave_type  is not null then 'Leave'
              when hol.name       is not null then 'Holiday'
              when public._is_weekly_off(p.id, v_day) then 'Rest Day'
              when tr.city        is not null then 'On Tour'
              when v_day = public.ist_today() then 'Not Checked In'
              else 'Absent' end,
         coalesce(a.is_late, false),
         case when a.check_out_at is null and a.check_in_at is not null and v_day = public.ist_today()
              then (extract(epoch from (now() - a.check_in_at)) / 60)::int
              else a.work_minutes end,
         a.source, coalesce(a.site_name, 'Tour - ' || tr.city), lv.leave_type
  from public.profiles p
  left join public.attendance a on a.user_id = p.id and a.work_date = v_day
  left join lateral (select i.name from public._holiday_info(p.id, v_day) i limit 1) hol on true
  left join lateral (
    select l.leave_type from public.leaves l
     where l.user_id = p.id and l.status = 'Approved' and v_day between l.from_day and l.to_day
     limit 1) lv on true
  left join lateral (
    select t.city from public.tours t
     where t.user_id = p.id and t.status = 'Approved' and v_day between t.from_day and t.to_day
     limit 1) tr on true
  where p.active
  order by (a.check_in_at is null), a.check_in_at desc nulls last, p.full_name;
end $$;
revoke execute on function public.admin_today_board(date) from public, anon;
grant  execute on function public.admin_today_board(date) to authenticated;

-- ---------------------------------------------------------------------
-- 7. The employee's home screen: "today is a holiday" only when it applies to him
-- ---------------------------------------------------------------------
create or replace function public.my_dashboard() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  me     public.profiles := public._require_active();
  v_today date := public.ist_today();
  t      public.attendance;
  m      record;
  v_leave int;
begin
  select * into t from public.attendance where user_id = me.id and work_date = v_today;

  select count(*) filter (where status in ('Present','Checked In'))           as present,
         count(*) filter (where day <= v_today)                              as elapsed,
         count(*) filter (where day <= v_today and status not in ('Rest Day','Holiday')) as working_days,
         count(*) filter (where is_late and status in ('Present','Checked In')) as late,
         count(*) filter (where status = 'Absent')                           as absent,
         count(*) filter (where status = 'Leave')                            as on_leave,
         coalesce(sum(hours), 0)                                             as hours
    into m
    from public._month_attendance(me.id, extract(year from v_today)::int, extract(month from v_today)::int);

  select coalesce(sum(greatest(balance,0)),0) into v_leave
    from public._leave_balance(me.id, extract(year from v_today)::int) where counts_balance;

  return jsonb_build_object(
    'profile', to_jsonb(me),
    'today', v_today,
    'server_time', now(),
    'attendance', case when t.id is null then null else to_jsonb(t) end,
    'month', jsonb_build_object('present', m.present, 'elapsed', m.elapsed,
                                'working_days', m.working_days, 'late', m.late,
                                'absent', m.absent, 'leave', m.on_leave, 'hours', m.hours),
    'leave_balance_total', v_leave,
    'is_holiday', (select i.name from public._holiday_info(me.id, v_today) i limit 1)
  );
end $$;
revoke execute on function public.my_dashboard() from public, anon;
grant  execute on function public.my_dashboard() to authenticated;

notify pgrst, 'reload schema';


-- ########## PART 2: LEAVE ELIGIBILITY + PAYROLL ##########
-- =====================================================================
-- LEAVE ELIGIBILITY AND SALARY DEDUCTION (from the joining date, fully automatic)
--   * Eligible from = joining date + 6 months (the day the 6 months are completed). Nothing is switched on by hand.
--   * BEFORE that day: every leave day is UNPAID. The employee may still apply (the leave balance is not checked), the leave days are
--     not taken from the leave balance, and the salary of those days is deducted in payroll.
--   * FROM that day: normal leave rules. Up to `paid_leaves_per_month` (2) approved leave days a month are paid; leave beyond that and
--     Loss of Pay stay unpaid. Paid leave is taken from the leave balance of the year, counted from the eligibility day.
--   * Leave balances, the leave screens, payroll, the salary sheet and the salary slips (which use payroll) all follow these rules by themselves.
--   * An employee without a joining date is treated as eligible (nothing can be calculated without the date): enter the joining date in Employees.
-- Run in Supabase Dashboard -> SQL Editor -> New query -> Run.  Safe to run again.  Run it AFTER cvp_attendance_schema.sql and salary_management.sql.
-- To change the rule later: update public.payroll_settings set paid_leaves_per_month = 2 where id = 1;  (the 6 months are in _leave_eligible_from below)
-- =====================================================================

-- The leave type that uses the monthly paid allowance (2 paid days a month, after 6 months of service)
insert into public.leave_types (name, annual_quota, counts_balance, sort_order, active)
values ('Monthly Paid Leave', 24, true, 5, true)
on conflict (name) do nothing;

-- The day an employee becomes eligible for paid leave (null = no joining date)
create or replace function public._leave_eligible_from(p_user uuid) returns date
language sql stable security definer set search_path = public as $$
  select (p.joining_date + interval '6 months')::date from public.profiles p where p.id = p_user
$$;
revoke execute on function public._leave_eligible_from(uuid) from public, anon, authenticated;

-- Leave days of one person between two dates: (counted leave types, Loss of Pay). Empty range = zeros.
create or replace function public._leave_days_split(p_user uuid, p_from date, p_to date)
returns table (counted int, lop int)
language sql stable security definer set search_path = public as $$
  select coalesce(sum(u.days) filter (where lt.counts_balance), 0)::int,
         coalesce(sum(u.days) filter (where not lt.counts_balance), 0)::int
    from public._leave_usage(p_user, p_from, p_to, array['Approved']) u
    join public.leave_types lt on lt.name = u.leave_type
$$;
revoke execute on function public._leave_days_split(uuid, date, date) from public, anon, authenticated;

-- Leave balance: leave taken before the eligibility day does not use the balance (it is unpaid)
create or replace function public._leave_balance(p_user uuid, p_year int)
returns table (leave_type text, granted int, used int, balance int, counts_balance boolean)
language sql stable security definer set search_path = public as $$
  select t.name,
         g.q,
         coalesce(u.days, 0)::int,
         (g.q - coalesce(u.days, 0))::int,
         t.counts_balance
  from public.leave_types t
  cross join lateral (
    select coalesce((select q.quota from public.employee_leave_quota q
                      where q.user_id = p_user and q.year = p_year and q.leave_type = t.name),
                    t.annual_quota)::int as q) g
  left join public._leave_usage(p_user,
              greatest(make_date(p_year, 1, 1), coalesce(public._leave_eligible_from(p_user), date '1900-01-01')),
              make_date(p_year, 12, 31)) u on u.leave_type = t.name
  where t.active
    -- Monthly Paid Leave exists only for an employee who has completed 6 months of service (joining date known)
    and (t.name <> 'Monthly Paid Leave'
         or (public._leave_eligible_from(p_user) is not null and public._leave_eligible_from(p_user) <= public.ist_today()))
  order by t.sort_order, t.name
$$;
revoke execute on function public._leave_balance(uuid, int) from public, anon, authenticated;

-- Apply for leave: before the eligibility day the leave is allowed but unpaid, so the balance is not checked
create or replace function public.apply_leave(p_leave_type text, p_from date, p_to date, p_reason text)
returns public.leaves
language plpgsql security definer set search_path = public as $$
declare
  me     public.profiles := public._require_active();
  t      public.leave_types;
  v_days int;
  v_bal  int;
  v_elig date := public._leave_eligible_from(auth.uid());
  r      public.leaves;
begin
  select * into t from public.leave_types where name = p_leave_type and active;
  if t.name is null then raise exception 'Unknown leave type'; end if;
  if p_to < p_from then raise exception 'End date cannot be before start date'; end if;
  if p_from < public.ist_today() + 2 then
    raise exception 'Leave must be applied at least 2 days in advance. The earliest start date is %', to_char(public.ist_today() + 2, 'DD-MM-YYYY');
  end if;
  if nullif(trim(p_reason),'') is null then raise exception 'Enter a reason'; end if;
  if extract(year from p_from) <> extract(year from p_to) then
    raise exception 'Submit one calendar year per request';
  end if;
  select coalesce(sum(u.days), 0)::int into v_days
    from public._leave_usage(me.id, p_from - 10, p_to + 10, array['Approved','Pending'], p_from, p_to, null) u
   where u.leave_type = 'NEW';
  if v_days = 0 then raise exception 'No working days in the selected period (weekly off / holiday only)'; end if;

  if exists (select 1 from public.leaves
              where user_id = me.id and status in ('Pending','Approved')
                and from_day <= p_to and to_day >= p_from) then
    raise exception 'These dates overlap with another leave request';
  end if;

  -- Monthly Paid Leave: only after 6 months of service, only inside one month, at most paid_leaves_per_month days a month
  if t.name = 'Monthly Paid Leave' then
    declare v_per int := (select s.paid_leaves_per_month from public.payroll_settings s where s.id = 1); v_used int;
    begin
      if v_elig is null then
        raise exception 'Monthly Paid Leave needs the joining date. Ask HR / Admin to enter it in Employees';
      end if;
      if p_from < v_elig then
        raise exception 'Monthly Paid Leave starts after 6 months of service (from %). Choose another leave type, it will be unpaid', to_char(v_elig, 'DD-MM-YYYY');
      end if;
      if date_trunc('month', p_from::timestamp) <> date_trunc('month', p_to::timestamp) then
        raise exception 'Monthly Paid Leave must be within one month. Submit one request for each month';
      end if;
      select coalesce(sum(l.days), 0)::int into v_used from public.leaves l
       where l.user_id = me.id and l.leave_type = 'Monthly Paid Leave' and l.status in ('Pending', 'Approved')
         and date_trunc('month', l.from_day::timestamp) = date_trunc('month', p_from::timestamp);
      if v_used + v_days > v_per then
        raise exception 'Only % Monthly Paid Leave day(s) a month. You have % left in this month', v_per, greatest(v_per - v_used, 0);
      end if;
    end;
  end if;

  -- paid leave needs a balance; leave before the 6 months are completed is unpaid and needs none
  if t.counts_balance and (v_elig is null or p_from >= v_elig) then
    select b.balance into v_bal from public._leave_balance(me.id, extract(year from p_from)::int) b
     where b.leave_type = t.name;
    if v_days > coalesce(v_bal, 0) then
      raise exception 'Insufficient leave balance (% day(s) available)', coalesce(v_bal,0);
    end if;
  end if;

  insert into public.leaves (user_id, leave_type, from_day, to_day, days, reason)
  values (me.id, t.name, p_from, p_to, v_days, trim(p_reason))
  returning * into r;
  perform public._audit('LEAVE_REQUEST', t.name || ' ' || p_from || ' to ' || p_to
    || case when v_elig is not null and p_from < v_elig then ' (unpaid: before 6 months of service)' else '' end);
  return r;
end $$;

-- Approve / reject: the same eligibility rule for the balance check
create or replace function public.review_leave(p_id bigint, p_approve boolean, p_note text default null)
returns public.leaves
language plpgsql security definer set search_path = public as $$
declare
  me    public.profiles := public._require_admin();
  r     public.leaves;
  t     public.leave_types;
  v_bal int;
  v_elig date;
begin
  select * into r from public.leaves where id = p_id for update;
  if r.id is null then raise exception 'Leave request not found'; end if;
  if r.status <> 'Pending' then raise exception 'This request is already %', lower(r.status); end if;
  v_elig := public._leave_eligible_from(r.user_id);

  if p_approve then
    select coalesce(sum(u.days), 0)::int into r.days
      from public._leave_usage(r.user_id, r.from_day - 10, r.to_day + 10, array['Approved'], r.from_day, r.to_day, r.id) u
     where u.leave_type = 'NEW';
    if r.days = 0 then raise exception 'This request has no working days (weekly off / holiday only)'; end if;
    update public.leaves set days = r.days where id = r.id;
    select * into t from public.leave_types where name = r.leave_type;
    if t.counts_balance and (v_elig is null or r.from_day >= v_elig) then
      select b.balance into v_bal from public._leave_balance(r.user_id, extract(year from r.from_day)::int) b
       where b.leave_type = r.leave_type;
      if r.days > coalesce(v_bal, 0) then
        raise exception 'Insufficient balance: cannot approve (% day(s) available)', coalesce(v_bal,0);
      end if;
    end if;
  end if;

  update public.leaves
     set status = case when p_approve then 'Approved' else 'Rejected' end,
         reviewed_by = me.id, reviewed_at = now(), review_note = nullif(trim(p_note),'')
   where id = p_id
  returning * into r;
  perform public._audit(case when p_approve then 'APPROVE_LEAVE' else 'REJECT_LEAVE' end, p_id::text);
  return r;
end $$;

-- Unpaid holiday days of one person between two dates (holiday_setup.sql). Returns 0 until that file has been run.
create or replace function public._unpaid_holiday_days(p_user uuid, p_from date, p_to date) returns int
language plpgsql stable security definer set search_path = public as $$
begin
  if to_regclass('public.employee_holidays') is null or p_to < p_from then return 0; end if;
  return (select count(*)::int
            from generate_series(p_from::timestamp, p_to::timestamp, interval '1 day') g
           where not public._is_weekly_off(p_user, g::date)
             and exists (select 1 from public._holiday_info(p_user, g::date) i where i.htype = 'Unpaid'));
end $$;
revoke execute on function public._unpaid_holiday_days(uuid, date, date) from public, anon, authenticated;

-- Salary sheet: leave before the eligibility day is unpaid; from that day 2 paid leave days a month; unpaid holidays are deducted
drop function if exists public.admin_payroll(int, int);
create or replace function public.admin_payroll(p_year int, p_month int)
returns table (
  user_id uuid, username text, full_name text, department text,
  monthly_salary numeric, days_in_month int, present int, absent int,
  leave_days int, paid_leave int, unpaid_leave int, not_joined int, unpaid_days int, payable_days int,
  overtime_hours numeric, overtime_pay numeric, deduction numeric, net_salary numeric, left_on date
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
  v_sal   numeric; v_pres int; v_abs int; v_l int; v_lop int; v_paid int; v_unpaid int; v_nj int; v_after int;
  v_unpd  int; v_work int; v_ot int; v_hr numeric; v_otpay numeric; v_ded numeric; v_shift_h numeric; v_uh int;
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
                          0, 0, 0, 0, v_dim, 0, 0::numeric, 0::numeric, 0::numeric, 0::numeric, v_left;
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

    -- leave: the part of the month BEFORE the 6 months are completed is unpaid, the rest follows the 2-paid-leaves rule
    v_elig := public._leave_eligible_from(rec.id);
    v_pre_end := case when v_elig is null or v_elig <= m0 then m0 - 1
                      when v_elig > m1 then m1
                      else v_elig - 1 end;
    select s.counted, s.lop into v_pre_l, v_pre_lop from public._leave_days_split(rec.id, m0, v_pre_end) s;
    v_pre := v_pre_l + v_pre_lop;
    select s.counted, s.lop into v_l, v_lop from public._leave_days_split(rec.id, v_pre_end + 1, m1) s;

    v_paid   := least(v_l, st.paid_leaves_per_month);
    v_unpaid := v_pre + (v_l - v_paid) + v_lop;
    v_nj     := case when rec.joining_date is null or rec.joining_date <= m0 then 0
                     else (least(rec.joining_date, m1 + 1) - m0) end;
    v_after  := case when v_left is not null and v_left < m1 then (m1 - v_left) else 0 end;
    -- unpaid holidays (Holiday Setup): the day is not worked and not paid; only days between joining and leaving are counted
    v_uh     := public._unpaid_holiday_days(rec.id, greatest(m0, coalesce(rec.joining_date, m0)), least(m1, coalesce(v_left, m1)));
    v_unpd   := least(v_dim, v_abs + v_unpaid + v_nj + v_after + v_uh);

    select count(*) into v_work
      from generate_series(m0::timestamp, m1::timestamp, interval '1 day') g
     where public._is_workday(rec.id, g::date);
    v_shift_h := extract(epoch from (rec.shift_end - rec.shift_start)) / 3600;
    select coalesce(sum(o.ot_minutes), 0) into v_ot from public._month_overtime(rec.id, p_year, p_month) o;

    v_hr    := case when v_work > 0 and v_shift_h > 0 then v_sal / (v_work * v_shift_h) else 0 end;
    v_otpay := round(v_ot / 60.0 * v_hr * st.overtime_multiplier, 2);
    v_ded   := round(v_sal / v_dim * v_unpd, 2);

    return query select rec.id, rec.username, rec.full_name, rec.department, v_sal, v_dim, v_pres, v_abs,
                        v_pre + v_l + v_lop, v_paid, v_unpaid, v_nj, v_unpd, v_dim - v_unpd,
                        round(v_ot / 60.0, 2), v_otpay, v_ded, round(v_sal - v_ded + v_otpay, 2), v_left;
  end loop;
end $$;

-- The employee's own eligibility and this month's paid leaves (for the Leave screen)
drop function if exists public.my_leave_eligibility();
create or replace function public.my_leave_eligibility()
returns table (joining_date date, eligible_from date, eligible boolean, days_left int, paid_per_month int, paid_used int, paid_left int)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare
  me      public.profiles := public._require_active();
  v_from  date := public._leave_eligible_from(auth.uid());
  v_ok    boolean := (v_from is null or v_from <= public.ist_today());
  v_m0    date := date_trunc('month', public.ist_today()::timestamp)::date;
  v_m1    date := (date_trunc('month', public.ist_today()::timestamp) + interval '1 month - 1 day')::date;
  v_per   int := (select s.paid_leaves_per_month from public.payroll_settings s where s.id = 1);
  v_used  int := 0;
begin
  if v_ok then
    select s.counted into v_used from public._leave_days_split(auth.uid(), greatest(v_m0, coalesce(v_from, v_m0)), v_m1) s;
  end if;
  return query
  select me.joining_date, v_from, v_ok,
         case when v_ok then 0 else (v_from - public.ist_today())::int end,
         v_per, least(coalesce(v_used, 0), v_per), greatest(v_per - coalesce(v_used, 0), 0);
end $$;
revoke execute on function public.apply_leave(text, date, date, text) from public, anon;
revoke execute on function public.review_leave(bigint, boolean, text) from public, anon;
revoke execute on function public.admin_payroll(int, int) from public, anon;
revoke execute on function public.my_leave_eligibility() from public, anon;
grant  execute on function public.apply_leave(text, date, date, text) to authenticated;
grant  execute on function public.review_leave(bigint, boolean, text) to authenticated;
grant  execute on function public.admin_payroll(int, int) to authenticated;
grant  execute on function public.my_leave_eligibility() to authenticated;

notify pgrst, 'reload schema';
