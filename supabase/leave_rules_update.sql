-- =====================================================================
-- LEAVE RULES UPDATE  (policy settings, day-by-day preview, comp-off grants, rupee rounding)
--   Adds what the leave rules needed on top of leave_eligibility.sql / monthly_leave_no_carry.sql / holiday_setup:
--   1. LEAVE POLICY (Admin edits, HR / employees read): paid days a month, months of service before paid leave starts,
--      days of notice, the yearly quotas (Casual / Sick / Annual) and whether weekly offs BETWEEN leave days count as leave.
--   2. Eligibility = joining date + N months on the same calendar day; a day that does not exist in that month becomes the month's last day.
--   3. Yearly balances (Casual / Sick / Annual) are 0 until the employee is eligible; they count from the eligibility day.
--   4. Weekly offs and holidays INSIDE the leave dates are NOT counted as leave days (the old "sandwich" counting is now a policy switch, default OFF).
--   5. leave_preview(): day-by-day Paid / Unpaid / Weekly off / Holiday with the per-day salary (the app adds the deduction).
--   6. Compensatory Off: HR / Admin grant days with a reason (history kept in comp_off_grants).
--   7. Payroll: deduction rounded to the nearest rupee; unpaid holidays shown as their own column. Salary after deduction = salary - deduction.
--   8. apply_leave reads the notice days / months from the policy and says "Apply as two requests" when the dates cross a year.
--   ADDITIVE: new columns / table / functions; existing leave, attendance and payroll rows are never changed.
--   NOTE: admin_payroll is recalculated live, so a month that is not locked can show different numbers after the switch in (4) or the
--   rupee rounding. Finalized months only lock increments (payroll_months.sql); check them before and after.
-- Run AFTER cvp_attendance_schema.sql, holiday_setup.sql, leave_eligibility.sql and monthly_leave_no_carry.sql, in Supabase SQL Editor.
-- Safe to run again.  Take a database backup first (and try it on a staging copy).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Policy settings (extra columns on the existing payroll_settings row)
-- ---------------------------------------------------------------------
alter table public.payroll_settings add column if not exists leave_eligibility_months integer not null default 6  check (leave_eligibility_months between 0 and 60);
alter table public.payroll_settings add column if not exists leave_notice_days        integer not null default 2  check (leave_notice_days between 0 and 60);
alter table public.payroll_settings add column if not exists count_weekly_off_between_leave boolean not null default false;

-- Eligible from = joining date + N months (Postgres moves a missing day, e.g. 31 Aug + 6 months, to the month's last day)
create or replace function public._leave_eligible_from(p_user uuid) returns date
language sql stable security definer set search_path = public as $$
  select (p.joining_date + make_interval(months => (select s.leave_eligibility_months from public.payroll_settings s where s.id = 1)))::date
    from public.profiles p where p.id = p_user
$$;
revoke execute on function public._leave_eligible_from(uuid) from public, anon, authenticated;

create or replace function public.get_leave_policy() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me public.profiles := public._require_active(); s public.payroll_settings;
begin
  select * into s from public.payroll_settings where id = 1;
  return jsonb_build_object(
    'paid_leaves_per_month', s.paid_leaves_per_month,
    'eligibility_months', s.leave_eligibility_months,
    'notice_days', s.leave_notice_days,
    'count_weekly_off_between_leave', s.count_weekly_off_between_leave,
    'quotas', (select coalesce(jsonb_object_agg(t.name, t.annual_quota), '{}'::jsonb)
                 from public.leave_types t where t.active and t.name in ('Casual Leave', 'Sick Leave', 'Annual Leave')));
end $$;

-- Admin only
create or replace function public.admin_set_leave_policy(
  p_paid_per_month int, p_eligibility_months int, p_notice_days int, p_count_weekly_off boolean, p_quotas jsonb
) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare me public.profiles := public._require_full_admin(); k text;
begin
  if p_paid_per_month is null or p_paid_per_month < 0 or p_paid_per_month > 31 then raise exception 'Paid leave a month must be between 0 and 31'; end if;
  if p_eligibility_months is null or p_eligibility_months < 0 or p_eligibility_months > 60 then raise exception 'Months of service must be between 0 and 60'; end if;
  if p_notice_days is null or p_notice_days < 0 or p_notice_days > 60 then raise exception 'Notice days must be between 0 and 60'; end if;
  update public.payroll_settings
     set paid_leaves_per_month = p_paid_per_month, leave_eligibility_months = p_eligibility_months,
         leave_notice_days = p_notice_days, count_weekly_off_between_leave = coalesce(p_count_weekly_off, false)
   where id = 1;
  for k in select jsonb_object_keys(coalesce(p_quotas, '{}'::jsonb)) loop
    if k in ('Casual Leave', 'Sick Leave', 'Annual Leave') then
      update public.leave_types set annual_quota = greatest(0, least(366, (p_quotas->>k)::int)) where name = k;
    end if;
  end loop;
  perform public._audit('LEAVE_POLICY', p_paid_per_month || ' paid / month, ' || p_eligibility_months || ' months, ' || p_notice_days || ' days notice');
  return public.get_leave_policy();
end $$;

-- ---------------------------------------------------------------------
-- 2. Leave day counting: weekly offs / holidays inside the dates are not leave days
--    (the old "sandwich" rule is kept, but only when the policy switch is ON)
-- ---------------------------------------------------------------------
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
      and coalesce((select s.count_weekly_off_between_leave from public.payroll_settings s where s.id = 1), false)
  )
  select x.lt, sum(x.c)::integer
  from (select lt, count(*) as c from lw group by lt
        union all
        select lt, sum(n) from sand group by lt) x
  group by x.lt
$$;
revoke execute on function public._leave_usage(uuid, date, date, text[], date, date, bigint) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 3. Yearly balances: 0 until eligible; counted from the eligibility day
--    _leave_balance_at(user, year, as_of): as_of = the date the balance is judged on (today for the screen, the first leave day when applying)
-- ---------------------------------------------------------------------
create or replace function public._leave_balance_at(p_user uuid, p_year int, p_asof date)
returns table (leave_type text, granted int, used int, balance int, counts_balance boolean)
language sql stable security definer set search_path = public as $$
  select t.name,
         g.q,
         coalesce(u.days, 0)::int,
         (g.q - coalesce(u.days, 0))::int,
         t.counts_balance
  from public.leave_types t
  cross join lateral (
    select case
             when t.name in ('Casual Leave', 'Sick Leave', 'Annual Leave')
                  and public._leave_eligible_from(p_user) is not null and public._leave_eligible_from(p_user) > p_asof then 0
             else coalesce((select q.quota from public.employee_leave_quota q
                             where q.user_id = p_user and q.year = p_year and q.leave_type = t.name), t.annual_quota)
           end::int as q) g
  left join public._leave_usage(p_user,
              greatest(make_date(p_year, 1, 1), coalesce(public._leave_eligible_from(p_user), date '1900-01-01')),
              make_date(p_year, 12, 31)) u on u.leave_type = t.name
  where t.active
    and (t.name <> 'Monthly Paid Leave'
         or (public._leave_eligible_from(p_user) is not null and public._leave_eligible_from(p_user) <= p_asof))
  order by t.sort_order, t.name
$$;
revoke execute on function public._leave_balance_at(uuid, int, date) from public, anon, authenticated;

create or replace function public._leave_balance(p_user uuid, p_year int)
returns table (leave_type text, granted int, used int, balance int, counts_balance boolean)
language sql stable security definer set search_path = public as $$
  select * from public._leave_balance_at(p_user, p_year, public.ist_today())
$$;
revoke execute on function public._leave_balance(uuid, int) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 4. Apply for leave (notice days and months of service come from the policy)
-- ---------------------------------------------------------------------
create or replace function public.apply_leave(p_leave_type text, p_from date, p_to date, p_reason text)
returns public.leaves
language plpgsql security definer set search_path = public as $$
declare
  me     public.profiles := public._require_active();
  st     public.payroll_settings;
  t      public.leave_types;
  v_days int;
  v_bal  int;
  v_elig date := public._leave_eligible_from(auth.uid());
  r      public.leaves;
begin
  select * into st from public.payroll_settings where id = 1;
  select * into t from public.leave_types where name = p_leave_type and active;
  if t.name is null then raise exception 'Unknown leave type'; end if;
  if p_to < p_from then raise exception 'End date cannot be before start date'; end if;
  if p_from < public.ist_today() + st.leave_notice_days then
    raise exception 'Leave must be applied at least % day(s) in advance. The earliest start date is %', st.leave_notice_days,
      to_char(public.ist_today() + st.leave_notice_days, 'DD-MM-YYYY');
  end if;
  if nullif(trim(p_reason),'') is null then raise exception 'Enter a reason'; end if;
  if extract(year from p_from) <> extract(year from p_to) then
    raise exception 'The dates are in two calendar years. Apply as two requests';
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

  if t.name = 'Monthly Paid Leave' then
    declare v_per int := st.paid_leaves_per_month; v_used int;
    begin
      if v_elig is null then
        raise exception 'Monthly Paid Leave needs the joining date. Ask HR / Admin to enter it in Employees';
      end if;
      if p_from < v_elig then
        raise exception 'Monthly Paid Leave starts after % months of service (from %). Choose another leave type, it will be unpaid',
          st.leave_eligibility_months, to_char(v_elig, 'DD-MM-YYYY');
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

  -- a yearly balance is needed only for leave on or after the eligibility day (earlier leave is unpaid and needs none)
  if t.counts_balance and t.name <> 'Monthly Paid Leave' and (v_elig is null or p_from >= v_elig) then
    select b.balance into v_bal from public._leave_balance_at(me.id, extract(year from p_from)::int, p_from) b
     where b.leave_type = t.name;
    if v_days > coalesce(v_bal, 0) then
      raise exception 'Insufficient leave balance (% day(s) available)', coalesce(v_bal,0);
    end if;
  end if;

  insert into public.leaves (user_id, leave_type, from_day, to_day, days, reason)
  values (me.id, t.name, p_from, p_to, v_days, trim(p_reason))
  returning * into r;
  perform public._audit('LEAVE_REQUEST', t.name || ' ' || p_from || ' to ' || p_to
    || case when v_elig is not null and p_from < v_elig then ' (unpaid: before ' || st.leave_eligibility_months || ' months of service)' else '' end);
  return r;
end $$;

-- ---------------------------------------------------------------------
-- 5. Day-by-day preview: Paid / Unpaid / Weekly off / Holiday + the per-day salary of that day's month
--    p_user: only HR / Admin may preview for somebody else (used by the approval screen)
-- ---------------------------------------------------------------------
create or replace function public.leave_preview(p_type text, p_from date, p_to date, p_user uuid default null)
returns table (day date, status text, per_day numeric)
language plpgsql stable security definer set search_path = public as $$
declare
  me     public.profiles := public._require_active();
  v_user uuid := coalesce(p_user, me.id);
  t      public.leave_types;
  v_per  int  := (select s.paid_leaves_per_month from public.payroll_settings s where s.id = 1);
  v_elig date;
  d      date;
  v_mon  date := null;
  v_used int := 0;
  v_dim  int;
begin
  if p_user is not null and p_user <> me.id and me.role not in ('HR', 'Admin') then
    raise exception 'You can only preview your own leave' using errcode = '42501';
  end if;
  if p_to < p_from or p_to - p_from > 370 then return; end if;
  select * into t from public.leave_types where name = p_type;
  v_elig := public._leave_eligible_from(v_user);

  for d in select g::date from generate_series(p_from::timestamp, p_to::timestamp, interval '1 day') g loop
    v_dim := extract(day from (date_trunc('month', d::timestamp) + interval '1 month - 1 day'))::int;
    if v_mon is distinct from date_trunc('month', d::timestamp)::date then
      v_mon := date_trunc('month', d::timestamp)::date;
      -- paid leave already approved / pending in this month (from the eligibility day on)
      select coalesce(sum(u.days), 0)::int into v_used
        from public._leave_usage(v_user, greatest(v_mon, coalesce(v_elig, v_mon)), (v_mon + interval '1 month - 1 day')::date,
                                 array['Approved', 'Pending']) u
        join public.leave_types lt on lt.name = u.leave_type and lt.counts_balance;
      if v_elig is not null and (v_mon + interval '1 month - 1 day')::date < v_elig then v_used := 0; end if;
    end if;
    day := d;
    per_day := round(coalesce(public._salary_on(v_user, d), 0) / v_dim, 2);
    if exists (select 1 from public._holiday_info(v_user, d)) then
      status := 'Holiday';
    elsif not public._is_workday(v_user, d) then
      status := 'Weekly off';
    elsif t.name is null or not t.counts_balance or (v_elig is not null and d < v_elig) then
      status := 'Unpaid';
    elsif v_used < v_per then
      status := 'Paid'; v_used := v_used + 1;
    else
      status := 'Unpaid';
    end if;
    return next;
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- 6. Compensatory Off: HR / Admin grant days with a reason
-- ---------------------------------------------------------------------
create table if not exists public.comp_off_grants (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references public.profiles(id) on delete cascade,
  year       integer not null,
  days       integer not null check (days between 1 and 30),
  reason     text not null check (length(trim(reason)) > 0),
  granted_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);
alter table public.comp_off_grants enable row level security;
drop policy if exists comp_off_grants_read on public.comp_off_grants;
create policy comp_off_grants_read on public.comp_off_grants for select to authenticated
  using (user_id = auth.uid() or public.is_staff_admin());
revoke insert, update, delete on public.comp_off_grants from anon, authenticated;
grant select on public.comp_off_grants to authenticated;

create or replace function public.admin_grant_comp_off(p_user uuid, p_days int, p_reason text)
returns public.comp_off_grants
language plpgsql volatile security definer set search_path = public as $$
declare me public.profiles := public._require_admin(); v_year int := extract(year from public.ist_today())::int; r public.comp_off_grants;
begin
  if p_days is null or p_days < 1 or p_days > 30 then raise exception 'Days must be between 1 and 30'; end if;
  if nullif(trim(p_reason), '') is null then raise exception 'Enter the reason for the Compensatory Off'; end if;
  if not exists (select 1 from public.profiles where id = p_user) then raise exception 'Employee not found'; end if;
  insert into public.comp_off_grants (user_id, year, days, reason, granted_by) values (p_user, v_year, p_days, trim(p_reason), me.id) returning * into r;
  insert into public.employee_leave_quota (user_id, year, leave_type, quota)
  values (p_user, v_year, 'Compensatory Off',
          coalesce((select t.annual_quota from public.leave_types t where t.name = 'Compensatory Off'), 0) + p_days)
  on conflict (user_id, year, leave_type) do update set quota = public.employee_leave_quota.quota + p_days;
  perform public._audit('COMP_OFF_GRANT', p_days || ' day(s): ' || trim(p_reason));
  return r;
end $$;

-- ---------------------------------------------------------------------
-- 7. Payroll: deduction in whole rupees; unpaid holidays as their own column
--    (the old function returned fewer columns, so it is dropped first)
-- ---------------------------------------------------------------------
drop function if exists public.admin_payroll(int, int);
create or replace function public.admin_payroll(p_year int, p_month int)
returns table (
  user_id uuid, username text, full_name text, department text,
  monthly_salary numeric, days_in_month int, present int, absent int,
  leave_days int, paid_leave int, unpaid_leave int, not_joined int, unpaid_days int, payable_days int,
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
                          0, 0, 0, 0, v_dim, 0, 0::numeric, 0::numeric, 0::numeric, 0::numeric, v_left, 0;
      continue;
    end if;

    select coalesce(avg(public._salary_on(rec.id, g::date)), 0) into v_sal
      from generate_series(m0::timestamp, m1::timestamp, interval '1 day') g;
    v_sal := round(v_sal, 2);

    -- each date is counted once: weekly off / holiday -> paid leave -> unpaid leave -> absent
    -- (a leave day is shown as "Leave" and a holiday as "Holiday" by the attendance calendar, so neither is also "Absent")
    select count(*) filter (where m.status in ('Present','Checked In')),
           count(*) filter (where m.status = 'Absent' and m.day < public.ist_today()
                                      and m.day >= coalesce(rec.joining_date, date '1900-01-01')
                                      and (v_left is null or m.day <= v_left))
      into v_pres, v_abs
      from public._month_attendance(rec.id, p_year, p_month) m;

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
                        v_pre + v_l + v_lop, v_paid, v_unpaid, v_nj, v_unpd, v_dim - v_unpd,
                        round(v_ot / 60.0, 2), v_otpay, v_ded, round(v_sal - v_ded + v_otpay, 2), v_left, v_uh;
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- Permissions
-- ---------------------------------------------------------------------
revoke all on function public.get_leave_policy()                                     from public, anon;
revoke all on function public.admin_set_leave_policy(int, int, int, boolean, jsonb)  from public, anon;
revoke all on function public.leave_preview(text, date, date, uuid)                  from public, anon;
revoke all on function public.admin_grant_comp_off(uuid, int, text)                  from public, anon;
revoke all on function public.apply_leave(text, date, date, text)                    from public, anon;
revoke all on function public.admin_payroll(int, int)                                from public, anon;
grant execute on function public.get_leave_policy()                                     to authenticated;
grant execute on function public.admin_set_leave_policy(int, int, int, boolean, jsonb)  to authenticated;
grant execute on function public.leave_preview(text, date, date, uuid)                  to authenticated;
grant execute on function public.admin_grant_comp_off(uuid, int, text)                  to authenticated;
grant execute on function public.apply_leave(text, date, date, text)                    to authenticated;
grant execute on function public.admin_payroll(int, int)                                to authenticated;

notify pgrst, 'reload schema';
