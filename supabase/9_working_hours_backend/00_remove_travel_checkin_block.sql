-- =====================================================================
-- REMOVE THE OLD "TRAVEL CHECK-IN" BLOCK
--
-- Problem:  Site Selfie fails with  "Travel employees must use the travel check-in"  (or "... travel check-out").
-- Cause:    the trigger  attendance_travel_guard  on public.attendance  (function public._travel_guard) refuses every plain
--           check-in / check-out of an employee whose  profiles.travel_access = true.  It was created by sections 23 and 25 of
--           cvp_attendance_schema.sql.  The travel check-in screen no longer exists in the app, so nothing can satisfy it.
--
-- What this file does (and nothing else):
--   1. drops the trigger  attendance_travel_guard
--   2. replaces  public._travel_guard()  with a function that only "returns new", so if an old script ever attaches it again it blocks nothing
--   3. checks that the trigger is gone and that no other function still raises the travel message
--
-- Why nothing is changed in check_in / check_out:  the current public.check_in / public.check_out (foreign_checkin_checkout.sql,
--   checkin_places_500m.sql) never look at travel_access.  Their other rules stay exactly as they are: allocated place, 500 m range,
--   Daily Report before check-out (trg_report_before_checkout), one check-in per day.
--
-- KEPT (nothing deleted): column profiles.travel_access, admin_set_travel_access(), tables attendance_legs / travel_track,
--   and the old travel_* / site_travel_* / foreign_place_travel_* functions (old reports).  travel_access is still the switch that
--   Foreign Location / site-travel functions look at (foreign_place_travel_check_in / _check_out require  travel_access AND site_employee).
--
-- Safe to run again.  No data is deleted or changed.
-- BACK UP THE DATABASE FIRST.   Supabase -> SQL Editor -> paste the WHOLE file -> Run.
-- Do NOT run cvp_attendance_schema.sql afterwards: it re-creates the trigger (see supabase/README_RUN_ORDER.md).
-- =====================================================================

-- 1. the trigger ------------------------------------------------------------------------------------------------
drop trigger if exists attendance_travel_guard on public.attendance;

-- 2. the function: harmless even if a trigger is attached again -----------------------------------------------
create or replace function public._travel_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  return new;       -- removed: travel check-in is no longer used, nothing is blocked here
end $$;
revoke all on function public._travel_guard() from public, anon, authenticated;

notify pgrst, 'reload schema';

-- 3. CHECKS (run each one; the first two must return NO rows) ------------------------------------------------
--    a) the trigger must not exist
select tgname from pg_trigger where tgname = 'attendance_travel_guard';

--    b) no function may still contain the travel message
select p.oid::regprocedure as function_name
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname in ('public', 'private') and p.prokind = 'f'
   and pg_get_functiondef(p.oid) ilike '%Travel employees must use the travel%';

--    c) the plain check-in / check-out must not look at travel_access (expected: no rows)
select p.oid::regprocedure as function_name
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname in ('public', 'private') and p.prokind = 'f' and p.proname in ('check_in', 'check_out')
   and pg_get_functiondef(p.oid) ilike '%travel_access%';

-- If (a) returns a row, run again; it should not. (b) and (c) listing a function means that function needs a separate look.
