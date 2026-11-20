-- READ-ONLY check (changes nothing): why does the register page say "details do not match" for a mobile number?
-- Replace 7385349570 below with the number you typed, then Run. Send me the result rows (or a screenshot).
--
-- The register page accepts an employee only when ALL of these are true:
--   role = Employee, active = true, approval_status = Approved,
--   (login_claimed = false  OR  the person has never signed in),
--   exactly ONE person has this number (profile phone or Employee Form "Cell no.").
select p.username, p.full_name, p.role, p.active, p.approval_status, p.login_claimed,
       (u.last_sign_in_at is not null) as has_signed_in_before,
       p.phone as profile_phone, d.cell_no as form_cell_no
  from public.profiles p
  left join public.employee_details d on d.user_id = p.id
  left join auth.users u on u.id = p.id
 where right(regexp_replace(coalesce(p.phone, ''), '\D', '', 'g'), 10) = '7385349570'
    or right(regexp_replace(coalesce(d.cell_no, ''), '\D', '', 'g'), 10) = '7385349570';

-- Is the registration setup installed? (all three must say true)
select to_regprocedure('public.check_registration_details(text, text, text)') is not null as check_function_installed,
       to_regclass('public.employee_registrations') is not null as requests_table_installed,
       to_regprocedure('public._registration_match2(text, text, text)') is not null as match_function_installed;
