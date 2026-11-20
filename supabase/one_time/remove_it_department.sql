-- #####################################################################
-- SAFETY LOCK - read before you run
-- PERMANENTLY DELETES every IT-department employee and all their data. It cannot be undone.
-- This script is NOT part of normal setup. To run it on purpose, DELETE the 'do $$ ... $$;' block below (the 3 lines after this comment).
-- #####################################################################
do $$ begin raise exception 'SAFETY LOCK: remove_it_department.sql is a one-time script. Read it, then delete this lock block to run it.'; end $$;

-- =====================================================================
-- REMOVE THE "IT" DEPARTMENT: permanently deletes the employee accounts of the IT department
-- together with their attendance, leave, visits, selfie records, travel data etc.  THIS CANNOT BE UNDONE.
-- Admin accounts are never deleted.
--
-- STEP 1  (Supabase -> SQL Editor): run ONLY this select and read the list. These people will be deleted.
-- =====================================================================
select p.username, p.full_name, p.role, p.department, p.active
from public.profiles p
where lower(trim(p.department)) = 'it' and p.role <> 'Admin'
order by p.full_name;

-- =====================================================================
-- STEP 2  Only if the list above is exactly right: run the lines below.
-- =====================================================================
delete from auth.users
where id in (select id from public.profiles where lower(trim(department)) = 'it' and role <> 'Admin');

-- Check: should now return 0 rows
-- select * from public.profiles where lower(trim(department)) = 'it';