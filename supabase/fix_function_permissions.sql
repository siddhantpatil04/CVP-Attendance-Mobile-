-- =====================================================================
-- FIX: "permission denied for function admin_dashboard_stats" (or any other function) after signing in
--
-- Cause: the signed-in role ("authenticated") lost the right to EXECUTE the app functions. The main schema file contains
--        "revoke execute on all functions ... " and gives back only some of them; running it again (or a similar script)
--        leaves functions without access.
--
-- This gives the right back to signed-in users for every app function. It is safe because every admin function checks the
-- role inside itself (_require_admin / _require_full_admin) - exactly as before.
-- NOT granted (kept private on purpose):
--   * internal helpers whose name starts with "_" (except the three _require_* checks)
--   * trigger functions
--   * admin_set_salary    (salary changes go through admin_increment_salary: Admin only)
--   * submit_registration (old self-registration route, replaced by the verified registration)
-- Nothing is deleted or changed in the data. Safe to run again.
-- =====================================================================
do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.prokind = 'f'
       and p.prorettype <> 'trigger'::regtype
       and (p.proname !~ '^_' or p.proname in ('_require_active', '_require_admin', '_require_full_admin'))
       and p.proname not in ('admin_set_salary', 'submit_registration', 'request_login', 'register_with_mobile', 'review_login_request')
  loop
    execute format('grant execute on function %s to authenticated', r.sig);
  end loop;
end $$;

-- the sign-in / registration screens run before login: only these may be called by people who are not signed in
do $$
declare f text;
begin
  foreach f in array array[
    'public.login_email(text)',
    'private.login_email(text)',
    'public.check_registration_details(text, text, text)'
  ] loop
    if to_regprocedure(f) is not null then
      execute format('grant execute on function %s to anon, authenticated', f);
    end if;
  end loop;
end $$;

-- keep the two switched-off routes switched off
do $$
declare f text;
begin
  foreach f in array array['public.admin_set_salary(uuid, numeric)', 'public.submit_registration(text, text, text, text, text, text)'] loop
    if to_regprocedure(f) is not null then
      execute format('revoke execute on function %s from public, anon, authenticated', f);
    end if;
  end loop;
end $$;

-- tables: signed-in users can read (row level security still decides which rows)
grant usage on schema public to authenticated;
grant select on all tables in schema public to authenticated;

notify pgrst, 'reload schema';
