-- =====================================================================
-- PROJECT MANAGER: Admin / HR decide which admin-menu items he gets
--
-- An employee whose DESIGNATION is "Project Manager" can be given admin-menu items (Live Dashboard, Approvals, Employees,
-- Live Map, Selfie Attendance, Documents Report ... up to all 16).  Admin and HR choose them in the employee's Access Control.
--   * profiles.menu_access (text[]) = the items he sees.  NULL = nothing extra (a normal employee / a normal HR keeps every item).
--   * Giving at least one item makes his role HR (HR already has the same data access as Admin); removing all items puts him
--     back to Employee.  The app shows ONLY the ticked items in his menu.
--   * Only a real Project Manager can be given items, and the Admin account is never changed.
--
-- ONE small, additive file.  Safe to run again.  No safety lock.  No table is dropped and no data is deleted.
-- Do NOT edit or run cvp_attendance_schema.sql for this.   BACK UP THE DATABASE FIRST.
-- Supabase -> SQL Editor -> paste the WHOLE file -> Run.
-- =====================================================================

alter table public.profiles add column if not exists menu_access text[];

create or replace function public.admin_set_menu_access(p_user uuid, p_items text[]) returns public.profiles
language plpgsql security definer set search_path = public as $$
declare
  me    public.profiles := public._require_admin();      -- Admin or HR
  t     public.profiles;
  v_ok  text[] := array['Live', 'Approvals', 'Reports', 'EmployeeForms', 'SalaryManagement', 'TeamAttendance', 'LiveMap', 'FieldJourneyReport',
                        'SelfieRecords', 'WorkingHours', 'TourAdmin', 'DocsReport', 'SitesAdmin', 'HolidaysAdmin', 'SaturdaysAdmin', 'Audit', 'AppUpdate'];
  v_items text[];
begin
  select * into t from public.profiles where id = p_user for update;
  if t.id is null then raise exception 'Employee not found'; end if;
  if t.role = 'Admin' then raise exception 'The Admin account always has every item'; end if;
  if coalesce(t.designation, '') !~* 'project\s*manager' then
    raise exception 'Only an employee with the designation Project Manager can get admin-menu access';
  end if;
  v_items := coalesce(p_items, '{}'::text[]);
  if exists (select 1 from unnest(v_items) x where x <> all (v_ok)) then raise exception 'Unknown menu item'; end if;

  if cardinality(v_items) = 0 then
    update public.profiles
       set menu_access = null, role = case when t.menu_access is not null and t.role = 'HR' then 'Employee' else t.role end
     where id = p_user returning * into t;
  else
    update public.profiles set menu_access = v_items, role = 'HR' where id = p_user returning * into t;
  end if;
  perform public._audit('PROJECT_MANAGER_MENU_ACCESS', t.full_name || ': ' || coalesce(array_to_string(t.menu_access, ', '), 'none') || ' (by ' || me.full_name || ')');
  return t;
end $$;
revoke all on function public.admin_set_menu_access(uuid, text[]) from public, anon;
grant execute on function public.admin_set_menu_access(uuid, text[]) to authenticated;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------
-- UNDO (only if needed; no data is deleted):
--   revoke execute on function public.admin_set_menu_access(uuid, text[]) from authenticated;
-- ---------------------------------------------------------------------
