-- =====================================================================
-- ROLLBACK of attendance_type.sql
-- Removes the function and the column profiles.attendance_type. Employees go back to "as the Site employee switch".
-- WARNING: the Attendance types that were chosen (office / site) are lost. Old Audit Trail lines stay.
-- Check-in / check-out, attendance records, salary and leave are NOT touched.
-- =====================================================================

drop function if exists public.admin_set_attendance_type(uuid, text);
alter table public.profiles drop constraint if exists profiles_attendance_type_chk;
alter table public.profiles drop column if exists attendance_type;
