-- =====================================================================
-- LEAVE POLICY - PREVIEW OF EXISTING BALANCES  (READ ONLY - this file changes NOTHING)
--
-- Run this in Supabase -> SQL Editor BEFORE running leave_policy_24.sql.  It only SELECTs.
-- It shows, for every active employee:
--   * joining date, the day paid leaves start (joining + 6 months) and how many months are done;
--   * the OLD balances of this year (Casual / Sick / Annual / Compensatory Off) and the Monthly Paid Leave used this year;
--   * a SUGGESTED mapping to the new types (you decide - nothing is applied):
--       EL  = old Annual Leave left + old Compensatory Off left   (EL can be saved, maximum 30)
--       CL  = 0   (new Casual Leave is credited 0.5 a month from the month you go live; unused CL lapses on 31 Dec anyway)
--       SL  = 0   (new Sick Leave is credited 0.5 a month from the month you go live)
--   * what the first monthly job would credit this month (EL +1, CL +0.5, SL +0.5) when the employee is eligible.
-- To apply an opening balance you approve, AFTER leave_policy_24.sql, use the Admin screen "Adjust balance" or:
--   select public.admin_adjust_leave_balance('<employee id>', 'Earned Leave', <days>, 'Opening balance from old Annual Leave');
-- =====================================================================
with cfg as (
  select s.leave_eligibility_months as months from public.payroll_settings s where s.id = 1
),
base as (
  select p.id, p.username, p.full_name, p.joining_date,
         (p.joining_date + make_interval(months => (select months from cfg)))::date as paid_leave_starts,
         case when p.joining_date is null then null
              else (extract(year from age(public.ist_today(), p.joining_date)) * 12 + extract(month from age(public.ist_today(), p.joining_date)))::int end as months_done
    from public.profiles p
   where p.active and p.role = 'Employee'
)
select b.username as emp_id, b.full_name, b.joining_date, b.paid_leave_starts, b.months_done,
       case when b.joining_date is null then 'NO JOINING DATE - enter it first'
            when b.paid_leave_starts <= public.ist_today() then 'eligible' else 'under 6 months - all leave is Unpaid' end as status,
       coalesce(max(l.balance) filter (where l.leave_type = 'Casual Leave'), 0)       as old_casual_left,
       coalesce(max(l.balance) filter (where l.leave_type = 'Sick Leave'), 0)         as old_sick_left,
       coalesce(max(l.balance) filter (where l.leave_type = 'Annual Leave'), 0)       as old_annual_left,
       coalesce(max(l.balance) filter (where l.leave_type = 'Compensatory Off'), 0)   as old_comp_off_left,
       coalesce(max(l.used)    filter (where l.leave_type = 'Monthly Paid Leave'), 0) as monthly_paid_used_this_year,
       least(30, coalesce(max(l.balance) filter (where l.leave_type = 'Annual Leave'), 0)
               + coalesce(max(l.balance) filter (where l.leave_type = 'Compensatory Off'), 0)) as suggested_EL_opening,
       0 as suggested_CL_opening,
       0 as suggested_SL_opening,
       case when b.paid_leave_starts is not null and b.paid_leave_starts <= public.ist_today()
            then 'EL +1, CL +0.5, SL +0.5' else 'nothing yet' end as first_job_credit_this_month
  from base b
  left join lateral public._leave_balance(b.id, extract(year from public.ist_today())::int) l on true
 group by b.username, b.full_name, b.joining_date, b.paid_leave_starts, b.months_done
 order by b.full_name;

-- Old requests are NOT touched: they stay in history and are still counted by the old rule.  How many exist per old type:
select leave_type, status, count(*) as requests, sum(days) as days
  from public.leaves
 group by leave_type, status
 order by leave_type, status;
