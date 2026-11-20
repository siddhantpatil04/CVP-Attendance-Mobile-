-- #####################################################################
-- SAFETY LOCK - read before you run
-- CHANGES the attendance type of employees picked by name patterns. It is out of date (it needs a file that no longer exists).
-- This script is NOT part of normal setup. To run it on purpose, DELETE the 'do $$ ... $$;' block below (the 3 lines after this comment).
-- #####################################################################
do $$ begin raise exception 'SAFETY LOCK: make_office_employees.sql is a one-time script. Read it, then delete this lock block to run it.'; end $$;

-- =====================================================================
-- OFFICE EMPLOYEES: Archana, Bhuvan, Ganesh Jawale, Lalit, Pravin, Saurabh, Suhas, Shivam, Ghanishta
-- They become OFFICE employees: no selfie, and check in / out ONLY at the office location.
-- Run in Supabase -> SQL Editor.  Needs update_office_employees.sql to be run first, and at least one work site
-- marked as "Office" (Work Sites -> edit the office site -> Type of location = Office).
--
-- STEP 1: run ONLY this select. Read the list: these are the people who will be changed.
--         If a name is missing or someone is wrong, tell me or fix the name patterns in the two places below.
-- =====================================================================
select p.username, p.full_name, p.department, p.site_employee
from public.profiles p
where p.role = 'Employee'
  and p.full_name ilike any (array['%archana%','%bhuvan%','%ganesh%jawale%','%lalit%','%prav%n%','%saurabh%','%suhas%','%shivam%','%sihvam%','%ghanish%'])
order by p.full_name;

select name as office_site from public.sites where is_office and active;   -- must show your office, otherwise mark it first

-- =====================================================================
-- STEP 2: only if both lists are right, run everything from here down.
-- =====================================================================
do $$
declare ids uuid[]; n int;
begin
  if not exists (select 1 from public.sites where is_office and active) then
    raise exception 'No active work site is marked as Office yet. Mark your office site first (Work Sites -> Type of location = Office).';
  end if;
  select array_agg(id) into ids from public.profiles
   where role = 'Employee'
     and full_name ilike any (array['%archana%','%bhuvan%','%ganesh%jawale%','%lalit%','%prav%n%','%saurabh%','%suhas%','%shivam%','%sihvam%','%ghanish%']);
  n := coalesce(array_length(ids, 1), 0);
  if n = 0 then raise exception 'No employee matched these names'; end if;

  update public.profiles set site_employee = false, travel_access = false where id = any(ids);   -- no selfie, no travel
  delete from public.employee_sites where user_id = any(ids);                                     -- drop every other site
  insert into public.employee_sites (user_id, site_id)
    select u, s.id from unnest(ids) u cross join public.sites s where s.is_office and s.active;  -- office location only
  raise notice '% employees are now office employees with office-only access', n;
end $$;

-- Check
-- select p.full_name, p.site_employee, (select string_agg(s.name, ', ') from public.employee_sites e join public.sites s on s.id = e.site_id where e.user_id = p.id) as sites
-- from public.profiles p where p.full_name ilike any (array['%archana%','%bhuvan%','%ganesh%jawale%','%lalit%','%prav%n%','%saurabh%','%suhas%','%shivam%','%sihvam%','%ghanish%']) and p.role='Employee';