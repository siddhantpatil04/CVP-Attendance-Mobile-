-- =====================================================================
-- ATTENDANCE TYPE of an employee: 'office' | 'site'  (decides Site Attendance / Office Attendance in the reports)
--
-- Why: today the only marker is the "Site employee" switch (profiles.site_employee), but that switch also decides HOW the employee checks in
-- (site selfie flow). An employee like emp009 checks in with the site flow yet must be counted in OFFICE Attendance, so the REPORT type has to be
-- separate from the check-in switch.
--
-- This file ONLY:
--   1. adds ONE nullable column  profiles.attendance_type   (NULL = "as today": site_employee = on -> Site, off -> Office)
--   2. adds ONE function         admin_set_attendance_type(user, type)  (Admin / HR; written to the Audit Trail)
-- It does NOT change check_in / check_out, the 500 m rule, salary, leave or any existing row. Every existing employee keeps NULL,
-- so nothing changes on screen until somebody picks a type in Employees -> Edit employee -> Access -> "Attendance type".
--
-- To make emp009 an Office employee after running this: pick "Office employee" in his Access section (or run the optional line at the end).
--
-- BACK UP FIRST.   Supabase -> SQL Editor -> paste the WHOLE file -> Run.   Safe to run again.   Undo: attendance_type_ROLLBACK.sql
-- =====================================================================

alter table public.profiles add column if not exists attendance_type text;

alter table public.profiles drop constraint if exists profiles_attendance_type_chk;
alter table public.profiles add constraint profiles_attendance_type_chk
  check (attendance_type is null or attendance_type in ('office', 'site'));

comment on column public.profiles.attendance_type is
  'Report type: office = all days counted in Office Attendance, site = in Site Attendance, NULL = as the Site employee switch (site_employee).';

create or replace function public.admin_set_attendance_type(p_user uuid, p_type text)
returns public.profiles
language plpgsql security definer set search_path = public as $$
declare
  me     public.profiles := public._require_admin();
  target public.profiles;
begin
  if p_type is not null and p_type not in ('office', 'site') then
    raise exception 'Attendance type must be office or site';
  end if;
  select * into target from public.profiles where id = p_user for update;
  if target.id is null then raise exception 'User not found'; end if;
  -- the same rule as admin_update_profile: HR can edit employees; only an Admin touches HR / Admin accounts
  if me.role <> 'Admin' and target.id <> me.id and target.role <> 'Employee' then
    raise exception 'Only an Admin can change HR / Admin accounts';
  end if;

  update public.profiles set attendance_type = p_type where id = p_user returning * into target;

  perform public._audit('ATTENDANCE_TYPE', target.username || ' attendance_type=' || coalesce(p_type, 'default (site switch)'));
  return target;
end $$;

revoke all on function public.admin_set_attendance_type(uuid, text) from public, anon;
grant execute on function public.admin_set_attendance_type(uuid, text) to authenticated;

-- OPTIONAL (remove the leading -- to run it): make emp009 an Office employee right now
-- update public.profiles set attendance_type = 'office' where username = 'emp009';
