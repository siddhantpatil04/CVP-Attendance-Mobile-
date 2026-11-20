-- =====================================================================
-- MONTHLY PAID LEAVE: 2 DAYS A MONTH, NOTHING IS CARRIED TO THE NEXT MONTH
--   * Every month starts with a fresh allowance (payroll_settings.paid_leaves_per_month, default 2).
--   * A leave day not taken in a month is lost: it is NOT added to the next month.
--   * Payroll / salary sheet / salary slips already work this way (paid leave = the lower of the leave taken in that month and 2,
--     calculated month by month). This file fixes what the employee and the Admin / HR SEE in the leave balance:
--     "Monthly Paid Leave" used to show 24 days for the whole year (unused days looked like they were piling up).
--     Now it shows, for the current month:  granted 2 / used / balance left this month.
--   * Nothing is deleted. No leave request, salary figure or report row is changed.
-- Run in Supabase -> SQL Editor -> New query -> Run.  Safe to run again.  Run it AFTER leave_eligibility.sql.
-- =====================================================================
-- ONE paid leave day per month for every eligible employee (6 months of service). Change it later with the same line.
update public.payroll_settings set paid_leaves_per_month = 1 where id = 1;

do $do$
declare v_schema text;
begin
  -- the real (SECURITY DEFINER) function lives in schema "private" once section 44 of the main file has been run
  v_schema := case when to_regprocedure('private.get_leave_balance(integer, uuid)') is not null then 'private' else 'public' end;

  execute format($f$
    create or replace function %I.get_leave_balance(p_year int default null, p_user uuid default null)
    returns table (leave_type text, granted int, used int, balance int, counts_balance boolean)
    language plpgsql stable security definer set search_path = public as $body$
    declare
      me     public.profiles := public._require_active();
      v_user uuid := coalesce(p_user, me.id);
      v_year int  := coalesce(p_year, extract(year from public.ist_today())::int);
      v_per  int  := (select s.paid_leaves_per_month from public.payroll_settings s where s.id = 1);
      v_cur  int  := extract(year from public.ist_today())::int;
      -- the month shown: this month in the current year; December for a past year; January for a future year
      v_mon  int  := case when v_year = v_cur then extract(month from public.ist_today())::int
                          when v_year < v_cur then 12 else 1 end;
      m0     date := make_date(v_year, v_mon, 1);
      m1     date := (make_date(v_year, v_mon, 1) + interval '1 month - 1 day')::date;
      v_elig date := public._leave_eligible_from(v_user);
      v_used int;
    begin
      if p_user is not null and p_user <> me.id and me.role not in ('HR','Admin') then
        raise exception 'You can only view your own leave balance' using errcode = '42501';
      end if;
      -- paid leave of the shown month: leave taken from the eligibility day on, at most the monthly allowance
      select least(coalesce(s.counted, 0), v_per) into v_used
        from public._leave_days_split(v_user, greatest(m0, coalesce(v_elig, m0)), m1) s;
      v_used := coalesce(v_used, 0);

      return query
      select b.leave_type,
             case when b.leave_type = 'Monthly Paid Leave' then v_per else b.granted end,
             case when b.leave_type = 'Monthly Paid Leave' then v_used else b.used end,
             case when b.leave_type = 'Monthly Paid Leave' then greatest(v_per - v_used, 0) else b.balance end,
             b.counts_balance
        from public._leave_balance(v_user, v_year) b;
    end $body$
  $f$, v_schema);
end $do$;

notify pgrst, 'reload schema';

-- Check (as Admin in the SQL editor this returns nothing because there is no signed-in user; use the app's Leave screen instead).
