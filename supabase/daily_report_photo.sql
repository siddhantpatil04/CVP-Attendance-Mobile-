-- =====================================================================
-- DAILY REPORT: (1) "Work going on" is no longer required, (2) OPTIONAL photo of the report
--
-- Run AFTER daily_report.sql and site_selfie_daily_report_checkout.sql.  ONE additive file.  Safe to run again.
-- No safety lock.  No table is dropped and no data is deleted.  BACK UP THE DATABASE FIRST.
-- Supabase -> SQL Editor -> paste the WHOLE file -> Run.
--
-- WHAT CHANGES
--  1. submit_daily_report no longer asks for "work going on" (the old column stays, old reports keep their text).
--     The message "Site 1: enter the work going on" is gone.
--  2. An employee may ATTACH one or more PHOTOS of his report (paper / handwritten report, site photos).  A photo is NOT compulsory:
--       - no photo  -> the report is filled manually as before (site, sub work, work description are required);
--       - with photo(s) -> the report can be submitted with the photo(s), and filling the form as well is optional.
--     Photos are stored in the PRIVATE bucket "daily_report_photos" (an employee uploads into his own folder; Admin / HR can view).
--  3. Only the employee (own report, while it is a Draft / Reopened one) adds or removes photos.  Admin / HR read them.
-- =====================================================================

-- 1. Photos table + private bucket ------------------------------------------------------------------------------------
create table if not exists public.daily_report_photos (
  id          bigint generated always as identity primary key,
  report_id   bigint not null references public.daily_reports(id) on delete cascade,
  user_id     uuid   not null references public.profiles(id) on delete cascade,
  file_path   text   not null,
  file_name   text,
  created_at  timestamptz not null default now()
);
create index if not exists daily_report_photos_report_idx on public.daily_report_photos (report_id);
alter table public.daily_report_photos enable row level security;
drop policy if exists daily_report_photos_read on public.daily_report_photos;
create policy daily_report_photos_read on public.daily_report_photos for select to authenticated
  using (user_id = auth.uid() or public.is_staff_admin());
revoke all on public.daily_report_photos from anon;
revoke insert, update, delete on public.daily_report_photos from authenticated;
grant select on public.daily_report_photos to authenticated;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('daily_report_photos', 'daily_report_photos', false, 10485760, array['image/jpeg', 'image/png', 'image/webp', 'application/pdf'])
on conflict (id) do update set public = false;
drop policy if exists daily_report_photos_upload on storage.objects;
create policy daily_report_photos_upload on storage.objects for insert to authenticated
  with check (bucket_id = 'daily_report_photos' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists daily_report_photos_view on storage.objects;
create policy daily_report_photos_view on storage.objects for select to authenticated
  using (bucket_id = 'daily_report_photos' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_staff_admin()));
drop policy if exists daily_report_photos_remove on storage.objects;
create policy daily_report_photos_remove on storage.objects for delete to authenticated
  using (bucket_id = 'daily_report_photos' and (storage.foldername(name))[1] = auth.uid()::text);

-- 2. Add / remove a photo (the employee, his own report, only while it can still be edited) --------------------------------
create or replace function public.add_daily_report_photo(p_report_id bigint, p_path text, p_name text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._require_active(); r public.daily_reports; v_id bigint;
begin
  select * into r from public.daily_reports where id = p_report_id and user_id = me.id for update;
  if r.id is null then raise exception 'Daily report not found'; end if;
  if r.status not in ('Draft', 'Reopened') then raise exception 'This report is already % and can no longer be changed', lower(r.status); end if;
  if p_path is null or split_part(p_path, '/', 1) <> me.id::text then raise exception 'The photo was not uploaded'; end if;
  if (select count(*) from public.daily_report_photos where report_id = r.id) >= 10 then raise exception 'At most 10 photos in one report'; end if;
  insert into public.daily_report_photos (report_id, user_id, file_path, file_name) values (r.id, me.id, p_path, nullif(trim(coalesce(p_name, '')), ''))
  returning id into v_id;
  return jsonb_build_object('id', v_id, 'file_path', p_path);
end $$;

create or replace function public.remove_daily_report_photo(p_id bigint) returns text
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._require_active(); ph public.daily_report_photos; r public.daily_reports;
begin
  select * into ph from public.daily_report_photos where id = p_id and user_id = me.id;
  if ph.id is null then raise exception 'Photo not found'; end if;
  select * into r from public.daily_reports where id = ph.report_id;
  if r.status not in ('Draft', 'Reopened') then raise exception 'This report is already % and can no longer be changed', lower(r.status); end if;
  delete from public.daily_report_photos where id = p_id;
  return ph.file_path;                                   -- the app then deletes the file
end $$;

-- 3. Submit: "work going on" is not required; a photo can replace the typed text ------------------------------------------------
create or replace function private.submit_daily_report(p_report_id bigint, p_sites jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._require_active(); r public.daily_reports; ctx jsonb; s record; n int; v_photos int;
begin
  r := private._daily_open_report(me.id, p_report_id);
  ctx := private._daily_visit_context(me.id, r.report_date);
  perform private._daily_write_sites(r.id, ctx, p_sites);

  select count(*) into n from public.daily_report_sites where report_id = r.id;
  select count(*) into v_photos from public.daily_report_photos where report_id = r.id;
  if n = 0 and v_photos = 0 then raise exception 'Add at least one site entry, or upload a photo of the report'; end if;

  -- no photo: the report is filled manually (site, sub work, work description); with a photo the typed fields are optional
  if v_photos = 0 then
    for s in select * from public.daily_report_sites where report_id = r.id order by seq loop
      if nullif(trim(s.site_name), '') is null then raise exception 'Site %: choose or enter the site location', s.seq; end if;
      if s.sub_work is null then raise exception 'Site %: enter the sub work (subcontract details)', s.seq; end if;
      if s.work_description is null then raise exception 'Site %: enter the work description (work completed today)', s.seq; end if;
    end loop;
  end if;

  update public.daily_reports
     set status = 'Submitted', submitted_at = now(), reviewed_by = null, reviewed_at = null,
         gps_km = (ctx->>'gps_km')::numeric, has_gps = coalesce((ctx->>'has_gps')::boolean, false), updated_at = now()
   where id = r.id;
  perform public._audit('DAILY_REPORT_SUBMIT', me.username || ' ' || r.report_date || ' (' || n || ' site(s), ' || v_photos || ' photo(s))');
  return private._daily_report_json(r.id);
end $$;

-- 4. The report json now also lists its photos (the app shows them to the employee and to Admin / HR) -----------------------------
create or replace function private._daily_report_json(p_id bigint) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
           'id', r.id, 'user_id', r.user_id, 'report_date', r.report_date, 'status', r.status,
           'review_note', r.review_note, 'submitted_at', r.submitted_at, 'gps_km', r.gps_km, 'has_gps', r.has_gps,
           'sites', coalesce((select jsonb_agg(to_jsonb(s) order by s.seq) from public.daily_report_sites s where s.report_id = r.id), '[]'::jsonb),
           'photos', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'file_path', p.file_path, 'file_name', p.file_name) order by p.id)
                                 from public.daily_report_photos p where p.report_id = r.id), '[]'::jsonb))
    from public.daily_reports r where r.id = p_id
$$;

-- 5. Permissions ------------------------------------------------------------------------------------------------------------------------
revoke all on function public.add_daily_report_photo(bigint, text, text) from public, anon;
revoke all on function public.remove_daily_report_photo(bigint)          from public, anon;
revoke all on function private.submit_daily_report(bigint, jsonb)        from public, anon;
grant execute on function public.add_daily_report_photo(bigint, text, text) to authenticated;
grant execute on function public.remove_daily_report_photo(bigint)          to authenticated;
grant execute on function private.submit_daily_report(bigint, jsonb)        to authenticated;

notify pgrst, 'reload schema';

-- UNDO (nothing is deleted): run daily_report.sql again to bring back the old submit rule ("work going on" required).
