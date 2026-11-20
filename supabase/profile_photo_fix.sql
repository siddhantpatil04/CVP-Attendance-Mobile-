-- =====================================================================
-- PROFILE PHOTO: make sure a saved photo can be READ again (own photo, and Admin / HR see everybody's)
--
-- The profile photo is the "photo" document of the Employee Form:
--   table   public.employee_detail_files   (one row per person and kind; kind = 'photo')
--   bucket  storage "employee_detail_docs" (private)  path: <employee-uuid>/photo-<timestamp>-<name>
--   RPCs    set_employee_detail_file / delete_employee_detail_file   (already created by employee_details.sql, section 45)
--
-- This file creates nothing new in your data. It only re-applies the bucket, the read / upload / delete rules and the
-- execute rights that the photo needs, in the form that works after the "private schema" move (sections 43 / 44):
--   * the rules call is_staff_admin() from whichever schema really has it (private, else public)
--   * "authenticated" gets USAGE on schema private and EXECUTE on that function (without it the read rule fails, the
--     signed link cannot be made and the app silently shows initials although the photo is saved)
--
-- RUN AFTER: the core schema and employee_details.sql.   Safe to run again.  No data is deleted or changed.
-- BACK UP FIRST.   Supabase -> SQL Editor -> paste the WHOLE file -> Run.
-- =====================================================================

-- 1. The helper that tells whether the caller is Admin / HR, and the rights to use it -----------------------------
create schema if not exists private;
grant usage on schema private to authenticated, anon;

do $$
begin
  if to_regprocedure('private.is_staff_admin()') is not null then
    grant execute on function private.is_staff_admin() to authenticated;
  elsif to_regprocedure('public.is_staff_admin()') is not null then
    grant execute on function public.is_staff_admin() to authenticated;
  else
    raise exception 'is_staff_admin() was not found in schema private or public: run the core schema first';
  end if;
end $$;

-- 1b. THE ACTUAL CAUSE SEEN IN THE APP: "permission denied for function _can_see_shared" ---------------------------
--     Reading ANY file from storage evaluates ALL read rules of storage.objects, including the rule of the shared-documents bucket
--     (document_sharing.sql) which calls  public._can_see_shared().  The security clean-up of section 43 removed the right to run
--     functions whose name starts with "_" from signed-in users, so that rule fails and so does every file read (the profile photo too).
--     Fix: give signed-in users the right to run every helper that a storage / table RULE calls (a rule helper must be runnable by the
--     person who is reading). The helpers only answer true / false for the caller; they do not return or change data.
do $$
declare r record; v_n int := 0;
begin
  for r in
    select distinct n.nspname as sch, p.oid::regprocedure as sig
      from pg_policies pol
      cross join lateral regexp_matches(coalesce(pol.qual, '') || ' ' || coalesce(pol.with_check, ''), '(public|private)\.([a-z_][a-z0-9_]*)\(', 'g') m
      join pg_namespace n on n.nspname = m[1]
      join pg_proc p on p.pronamespace = n.oid and p.proname = m[2]
     where pol.schemaname in ('public', 'storage')
       and p.prokind = 'f'
  loop
    execute format('grant usage on schema %I to authenticated', r.sch);
    execute format('grant execute on function %s to authenticated', r.sig);
    v_n := v_n + 1;
  end loop;
  raise notice 'execute right re-applied on % rule helper function(s)', v_n;
end $$;

-- the one named in the error, explicitly (also when no rule text mentions it any more)
do $$
begin
  if to_regprocedure('public._can_see_shared(bigint, uuid)') is not null then
    grant execute on function public._can_see_shared(bigint, uuid) to authenticated;
  end if;
end $$;

-- 2. The private bucket (jpeg / png / webp for photos, pdf / word for the other documents) ------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('employee_detail_docs', 'employee_detail_docs', false, 10485760, array[
  'application/pdf', 'image/jpeg', 'image/jpg', 'image/png', 'image/webp',
  'application/msword', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document'])
on conflict (id) do update
  set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

-- 3. Rules (own folder, or Admin / HR) ----------------------------------------------------------------------------
do $$
declare v_fn text := case when to_regprocedure('private.is_staff_admin()') is not null
                          then 'private.is_staff_admin()' else 'public.is_staff_admin()' end;
begin
  -- the table: a person reads his own rows, Admin / HR read everybody's
  execute 'alter table public.employee_detail_files enable row level security';
  execute 'drop policy if exists employee_detail_files_read on public.employee_detail_files';
  execute format('create policy employee_detail_files_read on public.employee_detail_files for select to authenticated using (user_id = auth.uid() or %s)', v_fn);

  -- the storage files
  execute 'drop policy if exists employee_detail_docs_upload on storage.objects';
  execute format($p$create policy employee_detail_docs_upload on storage.objects for insert to authenticated
    with check (bucket_id = 'employee_detail_docs'
      and (%s or ((storage.foldername(name))[1] = auth.uid()::text
                  and exists (select 1 from public.profiles p where p.id = auth.uid() and p.active))))$p$, v_fn);

  execute 'drop policy if exists employee_detail_docs_read on storage.objects';
  execute format($p$create policy employee_detail_docs_read on storage.objects for select to authenticated
    using (bucket_id = 'employee_detail_docs' and ((storage.foldername(name))[1] = auth.uid()::text or %s))$p$, v_fn);

  execute 'drop policy if exists employee_detail_docs_delete on storage.objects';
  execute format($p$create policy employee_detail_docs_delete on storage.objects for delete to authenticated
    using (bucket_id = 'employee_detail_docs' and ((storage.foldername(name))[1] = auth.uid()::text or %s))$p$, v_fn);
end $$;

revoke all on public.employee_detail_files from anon;
grant select on public.employee_detail_files to authenticated;

-- 4. The functions the app calls to attach / remove a photo (they already exist: only the rights are re-applied) ---
do $$
declare f text;
begin
  foreach f in array array[
    'public.save_employee_details(uuid, jsonb)',
    'public.set_employee_detail_file(uuid, text, text, text)',
    'public.delete_employee_detail_file(uuid, text)'
  ] loop
    if to_regprocedure(f) is not null then
      execute format('revoke execute on function %s from public, anon', f);
      execute format('grant execute on function %s to authenticated', f);
    end if;
  end loop;
end $$;

-- 5. Live refresh of the Employee list when a photo is added --------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_publication_tables
                  where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'employee_detail_files') then
    alter publication supabase_realtime add table public.employee_detail_files;
  end if;
end $$;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------
-- CHECKS (read-only; run them one by one after the file above)
--   select user_id, kind, file_path, created_at from public.employee_detail_files where kind = 'photo' order by created_at desc;
--   select name, created_at from storage.objects where bucket_id = 'employee_detail_docs' order by created_at desc limit 10;
--   select policyname, cmd from pg_policies where tablename in ('employee_detail_files', 'objects') and policyname like 'employee_detail%';
--   select has_function_privilege('authenticated', 'private.is_staff_admin()', 'execute');   -- must be true (if the function is in private)
--   select has_function_privilege('authenticated', 'public._can_see_shared(bigint, uuid)', 'execute');   -- must be true
-- ---------------------------------------------------------------------
