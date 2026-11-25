-- =====================================================================
-- ROLLBACK of two_companies.sql
-- Removes the company functions, triggers, history table, profiles.company_id and the companies table.
-- WARNING: company assignments (CVPCE moves) and the edited company details are lost. Old Audit Trail lines stay.
-- Attendance, check-in / check-out, leave, working hours and salary are NOT touched.
-- =====================================================================

drop trigger if exists profiles_company_guard         on public.profiles;
drop trigger if exists profiles_company_history_start on public.profiles;
drop trigger if exists profiles_company_default       on public.profiles;
drop function if exists public._profiles_company_guard();
drop function if exists public._profiles_company_history_start();
drop function if exists public._profiles_company_default();

drop function if exists public.admin_create_company(text, text, text);
drop function if exists public.admin_update_company(bigint, text, text, text);
drop function if exists public.admin_set_employee_company(uuid, bigint, date);
drop function if exists public.get_employee_company(uuid, date);

drop table if exists public.employee_company_history;
alter table public.profiles drop column if exists company_id;
drop table if exists public.companies;
