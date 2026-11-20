-- =====================================================================
-- HR HAS THE SAME ACCESS AS ADMIN  (database side)
-- Work sites, audit trail, salary / payroll, app updates, roles, HR / Admin accounts, HR registrations.
-- Run in Supabase Dashboard -> SQL Editor -> New query -> Run.  Safe to run again.
-- Works whether the functions are in schema "public" or were moved to "private".
-- Nothing is deleted. Run this file ONLY (not the whole cvp_attendance_schema.sql).
-- =====================================================================

-- 1. "Full admin" = active Admin or HR
create or replace function public._require_full_admin() returns public.profiles
language plpgsql stable security definer set search_path = public as $$
declare p public.profiles;
begin
  p := public._require_active();
  if p.role not in ('Admin', 'HR') then
    raise exception 'Only an Admin / HR can do this' using errcode = '42501';
  end if;
  return p;
end $$;

do $$
begin
  -- the row-security helper lives in "private" after the security clean-up, otherwise in "public"
  if to_regprocedure('private.is_full_admin()') is not null then
    execute $f$
      create or replace function private.is_full_admin() returns boolean
      language sql stable security definer set search_path = public as $b$
        select exists (select 1 from public.profiles where id = auth.uid() and active and role in ('Admin', 'HR'))
      $b$ $f$;
  end if;
  if to_regprocedure('public.is_full_admin()') is not null then
    execute $f$
      create or replace function public.is_full_admin() returns boolean
      language sql stable security definer set search_path = public as $b$
        select exists (select 1 from public.profiles where id = auth.uid() and active and role in ('Admin', 'HR'))
      $b$ $f$;
  end if;
end $$;

-- 2. Every function that checks  me.role <> 'Admin'  (change roles, HR / Admin accounts, bulk settings,
--    HR registrations ...) is rewritten so HR passes too. Looks in "public" AND "private".
do $$
declare r record; d text;
begin
  for r in
    select p.oid
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('public', 'private') and p.prokind = 'f'
       and (pg_get_functiondef(p.oid) like '%me.role <> ''Admin''%' or pg_get_functiondef(p.oid) like '%me.role = ''Admin''%')
  loop
    d := pg_get_functiondef(r.oid);
    d := replace(d, 'me.role <> ''Admin''', 'me.role not in (''Admin'', ''HR'')');
    d := replace(d, 'me.role = ''Admin''',  'me.role in (''Admin'', ''HR'')');
    execute d;
  end loop;
end $$;

notify pgrst, 'reload schema';
