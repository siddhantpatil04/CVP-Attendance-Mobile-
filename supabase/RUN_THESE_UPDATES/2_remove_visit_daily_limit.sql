-- =====================================================================
-- REMOVE THE "Visits / check-ins allowed per day" SETTING (1 to 6)
--
-- After this, employees have NO per-day limit for visits / site check-ins.
-- (Travel stays bounded only by the system maximum of 30 stops a day.)
--
-- Run ONCE in Supabase Dashboard -> SQL Editor -> New query -> Run.
-- Safe to run again. All-or-nothing: if anything cannot be changed safely, it stops
-- with an error and changes nothing.
-- Works whether the functions are in schema "public" or were moved to "private".
-- =====================================================================

-- 1. First remove the Admin / HR function that SET the limit (it cannot be "cleaned", it is simply deleted)
do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('public', 'private') and p.proname = 'admin_set_visit_limit'
  loop
    execute format('drop function if exists %s', r.sig);
  end loop;
end $$;

-- 2. Remove the "limit reached" check from every other function that still uses it
do $$
declare
  r       record;
  v_def   text;
  v_new   text;
  -- the old check:  if n >= me.visit_daily_limit then raise exception ... end if;
  v_if    constant text := E'(?s)\\s*if\\s+[a-z_]+\\s*>=\\s*(?:me|pr|p)\\.visit_daily_limit\\s+then.*?end\\s+if\\s*;';
  -- the old max_legs value in the travel status:  'max_legs', coalesce((select pr.visit_daily_limit ...), 3)
  v_max   constant text := E'''max_legs''\\s*,\\s*coalesce\\s*\\(\\s*\\(\\s*select\\s+[a-z_]+\\.visit_daily_limit[^)]*\\)\\s*,\\s*\\d+\\s*\\)';
begin
  for r in
    select p.oid, p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('public', 'private') and p.prokind = 'f'
       and pg_get_functiondef(p.oid) like '%visit_daily_limit%'
  loop
    v_def := pg_get_functiondef(r.oid);
    v_new := regexp_replace(v_def, v_if, E'\n', 'g');
    v_new := regexp_replace(v_new, v_max, E'''max_legs'', 30', 'g');
    if position('visit_daily_limit' in v_new) > 0 then
      raise exception 'Could not remove the daily-limit check safely from %. Nothing was changed. Send this message to your developer.', r.sig;
    end if;
    execute v_new;
  end loop;
end $$;

-- 3. The column that stored the 1-6 value
alter table public.profiles drop constraint if exists profiles_visit_daily_limit_check;
alter table public.profiles drop column if exists visit_daily_limit;

notify pgrst, 'reload schema';

-- Check: both queries below should return NO rows
-- select column_name from information_schema.columns
--  where table_schema = 'public' and table_name = 'profiles' and column_name = 'visit_daily_limit';
-- select proname from pg_proc where proname = 'admin_set_visit_limit';
