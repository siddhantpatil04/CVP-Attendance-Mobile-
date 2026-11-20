-- =====================================================================
-- SALARY MANAGEMENT
--   * Salary history: first the Basic salary, then every increment with its effective date. Nothing is ever edited or deleted.
--   * Only the Admin can set a salary or add an increment (HR can view). Employees can see their own salary.
--   * Payroll uses the salary that applies on each day of the month (an increment is pro-rated from its effective date).
--   * Employees who leave stay in the Salary Management section and in every report:
--       - up to the month of leaving the salary is paid up to the leaving date,
--       - from the next month every salary column shows "-" and the row says "Resigned".
-- Run this file once in the Supabase SQL Editor.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Leaving date
--    Employee Form "Resign date" is used first; otherwise the day the account was deleted (deactivated).
-- ---------------------------------------------------------------------
alter table public.profiles add column if not exists left_on date;

-- accounts that were already deleted before this update
update public.profiles p
   set left_on = coalesce((select d.resign_date from public.employee_details d where d.user_id = p.id), p.updated_at::date)
 where not p.active and p.left_on is null;

create or replace function public._track_left_on() returns trigger
language plpgsql as $$
begin
  if new.active then
    new.left_on := null;
  elsif tg_op = 'UPDATE' and old.active then
    new.left_on := coalesce((select d.resign_date from public.employee_details d where d.user_id = new.id),
                            (now() at time zone 'Asia/Kolkata')::date);
  end if;
  return new;
end $$;

drop trigger if exists profiles_track_left_on on public.profiles;
create trigger profiles_track_left_on before update on public.profiles
  for each row execute function public._track_left_on();

-- ---------------------------------------------------------------------
-- 2. Salary history
-- ---------------------------------------------------------------------
create table if not exists public.salary_history (
  id              bigint generated always as identity primary key,
  user_id         uuid not null references public.profiles(id) on delete cascade,
  kind            text not null check (kind in ('Basic', 'Increment')),
  salary          numeric(12,2) not null check (salary >= 0),   -- monthly salary from the effective date
  increment       numeric(12,2) not null default 0,             -- raise over the salary before it
  effective_date  date not null,
  note            text,
  created_by      uuid references public.profiles(id),
  created_at      timestamptz not null default now(),
  unique (user_id, effective_date)
);
create index if not exists salary_history_user_idx on public.salary_history (user_id, effective_date);

-- keep the salaries that were already saved: they become the Basic salary
insert into public.salary_history (user_id, kind, salary, increment, effective_date, note)
select es.user_id, 'Basic', es.monthly_salary, 0, date '2000-01-01', 'Existing salary'
  from public.employee_salary es
 where es.monthly_salary > 0
   and not exists (select 1 from public.salary_history h where h.user_id = es.user_id);

alter table public.salary_history enable row level security;
drop policy if exists salary_history_read on public.salary_history;
create policy salary_history_read on public.salary_history for select to authenticated
  using (public.is_full_admin() or user_id = auth.uid());
-- nobody writes to the table directly: only admin_increment_salary() below
revoke all on public.salary_history from anon, authenticated;
grant select on public.salary_history to authenticated;

-- the old "set salary" function would bypass the history: switch it off
revoke execute on function public.admin_set_salary(uuid, numeric) from public, anon, authenticated;

-- Salary that applies on one day (0 before the first entry)
create or replace function public._salary_on(p_user uuid, p_day date) returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce((select h.salary from public.salary_history h
                    where h.user_id = p_user and h.effective_date <= p_day
                    order by h.effective_date desc limit 1), 0)
$$;
revoke execute on function public._salary_on(uuid, date) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 3. Admin only: set the Basic salary (first time) or add an increment with an effective date
-- ---------------------------------------------------------------------
create or replace function public.admin_increment_salary(
  p_user uuid, p_salary numeric, p_effective date default null, p_note text default null
) returns public.salary_history
language plpgsql security definer set search_path = public as $$
declare
  me public.profiles := public._require_active();
  target public.profiles;
  last_h public.salary_history;
  res public.salary_history;
  v_eff date;
begin
  if me.role not in ('Admin', 'HR') then raise exception 'Only the Admin / HR can change salaries' using errcode = '42501'; end if;
  if p_salary is null or p_salary < 0 then raise exception 'Enter a valid salary'; end if;
  select * into target from public.profiles where id = p_user;
  if target.id is null then raise exception 'Employee not found'; end if;

  select * into last_h from public.salary_history where user_id = p_user order by effective_date desc limit 1;
  if last_h.id is null then
    insert into public.salary_history (user_id, kind, salary, increment, effective_date, note, created_by)
    values (p_user, 'Basic', round(p_salary, 2), 0, date '2000-01-01', nullif(trim(p_note), ''), me.id)
    returning * into res;
    perform public._audit('SET_SALARY', target.username || ' basic = ' || round(p_salary, 2));
  else
    v_eff := coalesce(p_effective, public.ist_today());
    if v_eff <= last_h.effective_date and last_h.kind <> 'Basic' then
      raise exception 'The effective date must be after the last salary change (%)', to_char(last_h.effective_date, 'DD-MM-YYYY');
    end if;
    if v_eff <= last_h.effective_date then v_eff := last_h.effective_date + 1; end if;
    if round(p_salary, 2) = last_h.salary then raise exception 'The new salary is the same as the current salary'; end if;
    insert into public.salary_history (user_id, kind, salary, increment, effective_date, note, created_by)
    values (p_user, 'Increment', round(p_salary, 2), round(p_salary, 2) - last_h.salary, v_eff, nullif(trim(p_note), ''), me.id)
    returning * into res;
    perform public._audit('SALARY_INCREMENT', target.username || ': ' || last_h.salary || ' -> ' || round(p_salary, 2) || ' from ' || v_eff);
  end if;
  return res;
end $$;
revoke execute on function public.admin_increment_salary(uuid, numeric, date, text) from public, anon;
grant  execute on function public.admin_increment_salary(uuid, numeric, date, text) to authenticated;

-- ---------------------------------------------------------------------
-- 4. Salary Management table (Admin / HR can view)
-- ---------------------------------------------------------------------
drop function if exists public.admin_salary_overview();
create or replace function public.admin_salary_overview()
returns table (
  user_id uuid, username text, full_name text, department text, active boolean, joining_date date, left_on date,
  basic numeric, inc1 numeric, inc1_on date, inc2 numeric, inc2_on date, increments int,
  current_salary numeric, current_from date
)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  perform public._require_full_admin();
  return query
  select p.id, p.username, p.full_name, p.department, p.active, p.joining_date, l.left_d,
         (select h.salary from public.salary_history h where h.user_id = p.id order by h.effective_date limit 1),
         (select i.increment from public.salary_history i where i.user_id = p.id and i.kind = 'Increment' order by i.effective_date limit 1),
         (select i.effective_date from public.salary_history i where i.user_id = p.id and i.kind = 'Increment' order by i.effective_date limit 1),
         (select i.increment from public.salary_history i where i.user_id = p.id and i.kind = 'Increment' order by i.effective_date offset 1 limit 1),
         (select i.effective_date from public.salary_history i where i.user_id = p.id and i.kind = 'Increment' order by i.effective_date offset 1 limit 1),
         (select count(*)::int from public.salary_history i where i.user_id = p.id and i.kind = 'Increment'),
         -- after the month of leaving there is no current salary any more
         case when l.left_d is not null and date_trunc('month', l.left_d::timestamp) < date_trunc('month', public.ist_today()::timestamp)
              then null else public._salary_on(p.id, public.ist_today()) end,
         (select h.effective_date from public.salary_history h where h.user_id = p.id and h.effective_date <= public.ist_today() order by h.effective_date desc limit 1)
    from public.profiles p
    left join public.employee_details d on d.user_id = p.id
    cross join lateral (select coalesce(d.resign_date, p.left_on) as left_d) l
   where p.active or l.left_d is not null
   order by p.full_name;
end $$;
revoke execute on function public.admin_salary_overview() from public, anon;
grant  execute on function public.admin_salary_overview() to authenticated;

-- Complete history of one employee
drop function if exists public.admin_salary_history(uuid);
create or replace function public.admin_salary_history(p_user uuid)
returns table (id bigint, kind text, salary numeric, increment numeric, effective_date date, note text, created_at timestamptz, set_by text)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  perform public._require_full_admin();
  return query
  select h.id, h.kind, h.salary, h.increment, h.effective_date, h.note, h.created_at, c.full_name
    from public.salary_history h left join public.profiles c on c.id = h.created_by
   where h.user_id = p_user
   order by h.effective_date desc;
end $$;
revoke execute on function public.admin_salary_history(uuid) from public, anon;
grant  execute on function public.admin_salary_history(uuid) to authenticated;

-- Employee: own salary history (only the changes that have already started)
drop function if exists public.my_salary();
create or replace function public.my_salary()
returns table (kind text, salary numeric, increment numeric, effective_date date)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  perform public._require_active();
  return query
  select h.kind, h.salary, h.increment, h.effective_date
    from public.salary_history h
   where h.user_id = auth.uid() and h.effective_date <= public.ist_today()
   order by h.effective_date desc;
end $$;
revoke execute on function public.my_salary() from public, anon;
grant  execute on function public.my_salary() to authenticated;

-- ---------------------------------------------------------------------
-- 5. Month summary of every report: people who have left stay in the list
--    (absent days are counted only up to the leaving date)
-- ---------------------------------------------------------------------
drop function if exists public.admin_month_summary(int, int);
create or replace function public.admin_month_summary(p_year int, p_month int)
returns table (
  user_id uuid, username text, full_name text, department text,
  present int, absent int, on_leave int, late int, holidays int, hours numeric, left_on date
)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  perform public._require_admin();
  return query
  select p.id, p.username, p.full_name, p.department,
         count(*) filter (where m.status in ('Present','Checked In'))::int,
         count(*) filter (where m.status = 'Absent' and (l.left_d is null or m.day <= l.left_d))::int,
         count(*) filter (where m.status = 'Leave')::int,
         count(*) filter (where m.is_late and m.status in ('Present','Checked In'))::int,
         count(*) filter (where m.status = 'Holiday')::int,
         coalesce(sum(m.hours), 0),
         l.left_d
  from public.profiles p
  left join public.employee_details d on d.user_id = p.id
  cross join lateral (select coalesce(d.resign_date, p.left_on) as left_d) l
  cross join lateral public._month_attendance(p.id, p_year, p_month) m
  where p.active or l.left_d is not null
  group by p.id, p.username, p.full_name, p.department, l.left_d
  order by p.full_name;
end $$;
revoke execute on function public.admin_month_summary(int, int) from public, anon;
grant  execute on function public.admin_month_summary(int, int) to authenticated;

-- ---------------------------------------------------------------------
-- 6. Salary sheet: uses the salary history, and keeps people who have left
--    * salary of a month = the salary of each day of the month averaged (an increment is paid from its effective date)
--    * month of leaving: the days after the leaving date are unpaid
--    * months after leaving: every figure is 0 (shown as "-")
-- ---------------------------------------------------------------------
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
  v_sal   numeric; v_pres int; v_abs int; v_l int; v_lop int; v_paid int; v_unpaid int; v_nj int; v_after int;
  v_unpd  int; v_work int; v_ot int; v_hr numeric; v_otpay numeric; v_ded numeric; v_shift_h numeric;
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

    -- months after the month of leaving: nothing is paid
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

    select coalesce(sum(u.days) filter (where lt.counts_balance), 0),
           coalesce(sum(u.days) filter (where not lt.counts_balance), 0)
      into v_l, v_lop
      from public._leave_usage(rec.id, m0, m1, array['Approved']) u
      join public.leave_types lt on lt.name = u.leave_type;

    v_paid   := least(v_l, st.paid_leaves_per_month);
    v_unpaid := v_l - v_paid + v_lop;
    v_nj     := case when rec.joining_date is null or rec.joining_date <= m0 then 0
                     else (least(rec.joining_date, m1 + 1) - m0) end;
    v_after  := case when v_left is not null and v_left < m1 then (m1 - v_left) else 0 end;   -- days after leaving
    v_unpd   := least(v_dim, v_abs + v_unpaid + v_nj + v_after);

    select count(*) into v_work
      from generate_series(m0::timestamp, m1::timestamp, interval '1 day') g
     where public._is_workday(rec.id, g::date);
    v_shift_h := extract(epoch from (rec.shift_end - rec.shift_start)) / 3600;
    select coalesce(sum(o.ot_minutes), 0) into v_ot from public._month_overtime(rec.id, p_year, p_month) o;

    v_hr    := case when v_work > 0 and v_shift_h > 0 then v_sal / (v_work * v_shift_h) else 0 end;
    v_otpay := round(v_ot / 60.0 * v_hr * st.overtime_multiplier, 2);
    v_ded   := round(v_sal / v_dim * v_unpd, 2);

    return query select rec.id, rec.username, rec.full_name, rec.department, v_sal, v_dim, v_pres, v_abs,
                        v_l + v_lop, v_paid, v_unpaid, v_nj, v_unpd, v_dim - v_unpd,
                        round(v_ot / 60.0, 2), v_otpay, v_ded, round(v_sal - v_ded + v_otpay, 2), v_left;
  end loop;
end $$;
revoke execute on function public.admin_payroll(int, int) from public, anon;
grant  execute on function public.admin_payroll(int, int) to authenticated;
