-- ---------------------------------------------------------------------
-- CHECK-IN / CHECK-OUT AND WORKING HOURS
--   * No fixed check-in / check-out times: nobody is marked "late" for arriving after a shift start any more.
--     Employees check in and out when they really start and finish at their assigned site.
--   * Working hours = check-out minus check-in, MINUS the unpaid break (a company setting, see below).
--   * 8 hours is the standard working day; everything beyond it is overtime. Time worked on a weekly off / holiday is all overtime.
--   * Admin / HR report: admin_working_hours_report (employee, site, date, check-in, check-out, total, regular, overtime hours).
-- Run in Supabase Dashboard -> SQL Editor -> New query -> Run.  Safe to run again.
--
-- To change the rules later, edit the one settings row, for example:
--   update public.payroll_settings set standard_minutes = 480, unpaid_break_minutes = 30, break_after_minutes = 300 where id = 1;
--   (unpaid_break_minutes = 0 means no break is deducted)
-- ---------------------------------------------------------------------
alter table public.payroll_settings add column if not exists standard_minutes     integer not null default 480 check (standard_minutes > 0);
alter table public.payroll_settings add column if not exists unpaid_break_minutes integer not null default 60  check (unpaid_break_minutes >= 0);
-- the unpaid break is deducted only on a day when the person worked MORE than this many minutes (default 5 hours)
alter table public.payroll_settings add column if not exists break_after_minutes  integer not null default 300 check (break_after_minutes >= 0);

-- worked minutes after the unpaid break
create or replace function public._work_net_minutes(p_gross integer) returns integer
language sql stable security definer set search_path = public as $$
  select case
           when p_gross is null then null
           when p_gross > s.break_after_minutes then greatest(p_gross - s.unpaid_break_minutes, 0)
           else p_gross end
  from public.payroll_settings s where s.id = 1
$$;

-- No fixed times: a check-in is never "late"
create or replace function public._no_fixed_times() returns trigger
language plpgsql as $$ begin new.is_late := false; return new; end $$;
drop trigger if exists attendance_no_late on public.attendance;
create trigger attendance_no_late before insert or update on public.attendance
  for each row execute function public._no_fixed_times();

-- Overtime per day (used by the Salary Report and every overtime figure): minutes beyond the standard day,
-- all minutes on a weekly off / holiday. Working minutes are counted after the unpaid break.
create or replace function public._month_overtime(p_user uuid, p_year int, p_month int)
returns table (day date, work_minutes int, shift_minutes int, ot_minutes int)
language sql stable security definer set search_path = public as $$
  select a.work_date,
         public._work_net_minutes(a.work_minutes),
         s.standard_minutes,
         case when not public._is_workday(a.user_id, a.work_date) then public._work_net_minutes(a.work_minutes)
              else greatest(public._work_net_minutes(a.work_minutes) - s.standard_minutes, 0) end
  from public.attendance a
  cross join public.payroll_settings s
  where s.id = 1 and a.user_id = p_user and a.work_minutes is not null
    and a.work_date between make_date(p_year, p_month, 1)
                        and (make_date(p_year, p_month, 1) + interval '1 month - 1 day')::date
$$;

-- Working Hours and Overtime Report: one row per employee per day
drop function if exists public.admin_working_hours_report(date, date, uuid);
create or replace function public.admin_working_hours_report(p_from date, p_to date, p_user uuid default null)
returns table (
  user_id uuid, username text, full_name text, department text, site_name text, work_date date,
  check_in text, check_out text,
  gross_minutes int, break_minutes int, total_minutes int, regular_minutes int, overtime_minutes int
)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare std int;
begin
  perform public._require_admin();
  select standard_minutes into std from public.payroll_settings where id = 1;
  return query
  select p.id, p.username, p.full_name, p.department,
         coalesce(nullif(trim(a.site_name), ''),
                  (select string_agg(distinct l.site_name, ', ') from public.attendance_legs l where l.attendance_id = a.id and l.site_name is not null),
                  'Office'),
         a.work_date,
         to_char(a.check_in_at  at time zone 'Asia/Kolkata', 'HH24:MI'),
         to_char(a.check_out_at at time zone 'Asia/Kolkata', 'HH24:MI'),
         a.work_minutes,
         a.work_minutes - public._work_net_minutes(a.work_minutes),
         public._work_net_minutes(a.work_minutes),
         case when public._work_net_minutes(a.work_minutes) is null then null
              when not public._is_workday(a.user_id, a.work_date) then 0
              else least(public._work_net_minutes(a.work_minutes), std) end,
         case when public._work_net_minutes(a.work_minutes) is null then null
              when not public._is_workday(a.user_id, a.work_date) then public._work_net_minutes(a.work_minutes)
              else greatest(public._work_net_minutes(a.work_minutes) - std, 0) end
  from public.attendance a
  join public.profiles p on p.id = a.user_id
  where a.work_date between p_from and p_to and a.check_in_at is not null
    and (p_user is null or a.user_id = p_user)
  order by p.full_name, a.work_date;
end $$;

revoke execute on function public._work_net_minutes(integer) from public, anon, authenticated;
revoke execute on function public._no_fixed_times() from public, anon, authenticated;
revoke execute on function public.admin_working_hours_report(date, date, uuid) from public, anon;
grant  execute on function public.admin_working_hours_report(date, date, uuid) to authenticated;

notify pgrst, 'reload schema';
