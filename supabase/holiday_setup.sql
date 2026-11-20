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
