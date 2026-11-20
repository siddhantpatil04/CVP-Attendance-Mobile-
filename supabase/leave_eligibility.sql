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
