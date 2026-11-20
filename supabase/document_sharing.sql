-- =====================================================================
-- DOCUMENT SHARING - STAGE 1: "FROM C V PATIL" (company -> chosen employees)
--
-- Admin / HR (and a Project Manager = an HR-level user with admin-menu access) publish a document and choose exactly who sees it:
--   all employees  |  a project team (= the employees allocated to the chosen work sites)  |  a department  |  selected employees.
-- No approval step: it is visible at once.  The sender is shown as "C V PATIL & ASSOCIATES"; the real uploader is stored.
--
-- * document_types: seeded list (a LOCKED type, can_all = false, can never be shared with "All employees" - the SERVER refuses it).
-- * shared_documents / shared_document_audience / shared_document_views: what is shared, with whom, and who opened it.
-- * Files are in the private bucket "shared_docs" and opened only through open_shared_document() + a 2-minute signed link.
-- * Existing documents (employee_documents) are NOT touched.
--
-- NOT in this file yet (later stages): "To C V Patil" recipients (Admin / HR / PM only), re-share, notifications, Document Types editor.
--
-- ONE additive file.  Safe to run again.  No safety lock.  No table is dropped and no data is deleted.
-- Do NOT edit or run cvp_attendance_schema.sql for this.   BACK UP THE DATABASE FIRST.
-- Supabase -> SQL Editor -> paste the WHOLE file -> Run.
-- =====================================================================

-- 1. Document types ------------------------------------------------------------------------------------------------
create table if not exists public.document_types (
  id                 bigint generated always as identity primary key,
  name               text not null unique,
  direction          text not null check (direction in ('from_cvp', 'to_cvp')),
  default_visibility text not null default 'all' check (default_visibility in ('all', 'site', 'department', 'employee', 'recipients', 'admin_hr')),
  can_all            boolean not null default true,        -- false = LOCKED: never "All employees"
  allow_reshare      boolean not null default false,
  publishers         text[] not null default array['Admin', 'HR'],
  active             boolean not null default true
);
alter table public.document_types enable row level security;
drop policy if exists document_types_read on public.document_types;
create policy document_types_read on public.document_types for select to authenticated using (true);
revoke all on public.document_types from anon;
revoke insert, update, delete on public.document_types from authenticated;
grant select on public.document_types to authenticated;

insert into public.document_types (name, direction, default_visibility, can_all, allow_reshare, publishers) values
  ('Company Policy',                'from_cvp', 'all',        true,  false, array['Admin', 'HR']),
  ('Company Circular / Notice',     'from_cvp', 'all',        true,  false, array['Admin', 'HR', 'PM']),
  ('Holiday List',                  'from_cvp', 'all',        true,  false, array['Admin', 'HR']),
  ('HR Forms (leave, claim)',       'from_cvp', 'all',        true,  false, array['Admin', 'HR']),
  ('Project Drawing / Report',      'from_cvp', 'site',       true,  false, array['Admin', 'PM']),
  ('Site Instruction',              'from_cvp', 'site',       true,  false, array['Admin', 'PM']),
  ('Salary Slip / Offer Letter',    'from_cvp', 'employee',   false, false, array['Admin', 'HR']),
  ('Leave Application',             'to_cvp',   'recipients', false, false, array['Employee']),
  ('Aadhaar / PAN / Bank proof',    'to_cvp',   'admin_hr',   false, false, array['Employee']),
  ('Bill / Expense claim',          'to_cvp',   'recipients', false, false, array['Employee']),
  ('Site Report / Photos',          'to_cvp',   'recipients', false, true,  array['Employee'])
on conflict (name) do nothing;

-- 2. Shared documents ----------------------------------------------------------------------------------------------
create table if not exists public.shared_documents (
  id             bigint generated always as identity primary key,
  type_id        bigint not null references public.document_types(id),
  title          text not null check (length(trim(title)) > 0),
  description    text,
  file_path      text not null,
  file_name      text,
  uploaded_by    uuid references public.profiles(id) on delete set null,
  sender_label   text not null default 'C V PATIL & ASSOCIATES',
  allow_download boolean not null default true,
  visible_until  date,
  audience_kind  text not null check (audience_kind in ('all', 'site', 'department', 'employee')),
  created_at     timestamptz not null default now()
);
create table if not exists public.shared_document_audience (
  document_id    bigint not null references public.shared_documents(id) on delete cascade,
  audience_type  text   not null check (audience_type in ('site', 'department', 'employee')),
  audience_value text   not null,
  primary key (document_id, audience_type, audience_value)
);
create table if not exists public.shared_document_views (
  document_id bigint not null references public.shared_documents(id) on delete cascade,
  user_id     uuid   not null references public.profiles(id) on delete cascade,
  viewed_at   timestamptz not null default now(),
  downloaded  boolean not null default false,
  primary key (document_id, user_id)
);
create index if not exists shared_documents_created_idx on public.shared_documents (created_at desc);

-- 3. Who may see a document (used by the table policy, the storage policy and every function) ---------------------
create or replace function public._can_see_shared(p_doc bigint, p_user uuid default auth.uid()) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1
      from public.shared_documents d
      join public.profiles p on p.id = p_user and p.active
     where d.id = p_doc
       and (
         p.role in ('Admin', 'HR')                                                     -- staff see everything that was shared
         or ((d.visible_until is null or d.visible_until >= public.ist_today())
             and (d.audience_kind = 'all'
                  or exists (
                       select 1 from public.shared_document_audience a
                        where a.document_id = d.id
                          and ((a.audience_type = 'employee'   and a.audience_value = p.id::text)
                            or (a.audience_type = 'department' and lower(a.audience_value) = lower(coalesce(p.department, '')))
                            or (a.audience_type = 'site'       and exists (select 1 from public.employee_sites e
                                                                            where e.user_id = p.id and e.site_id::text = a.audience_value))))))
       )
  )
$$;

-- the people an audience {"kind": "...", "values": [...]} reaches (active Employee accounts)
create or replace function public._audience_members(p_audience jsonb) returns setof uuid
language sql stable security definer set search_path = public as $$
  select p.id
    from public.profiles p
   where p.active and p.role = 'Employee'
     and (
       (p_audience ->> 'kind') = 'all'
       or ((p_audience ->> 'kind') = 'employee'   and p.id::text in (select jsonb_array_elements_text(p_audience -> 'values')))
       or ((p_audience ->> 'kind') = 'department' and lower(coalesce(p.department, '')) in (select lower(jsonb_array_elements_text(p_audience -> 'values'))))
       or ((p_audience ->> 'kind') = 'site'       and exists (select 1 from public.employee_sites e
                                                               where e.user_id = p.id and e.site_id::text in (select jsonb_array_elements_text(p_audience -> 'values'))))
     )
$$;

-- 4. Row level security ---------------------------------------------------------------------------------------------
alter table public.shared_documents enable row level security;
alter table public.shared_document_audience enable row level security;
alter table public.shared_document_views enable row level security;
drop policy if exists shared_documents_read on public.shared_documents;
create policy shared_documents_read on public.shared_documents for select to authenticated using (public._can_see_shared(id));
drop policy if exists shared_audience_read on public.shared_document_audience;
create policy shared_audience_read on public.shared_document_audience for select to authenticated using (public.is_staff_admin());
drop policy if exists shared_views_read on public.shared_document_views;
create policy shared_views_read on public.shared_document_views for select to authenticated using (user_id = auth.uid() or public.is_staff_admin());
revoke all on public.shared_documents, public.shared_document_audience, public.shared_document_views from anon;
revoke insert, update, delete on public.shared_documents, public.shared_document_audience, public.shared_document_views from authenticated;
grant select on public.shared_documents, public.shared_document_audience, public.shared_document_views to authenticated;

-- 5. Private file bucket ---------------------------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('shared_docs', 'shared_docs', false, 10485760, array[
  'application/pdf', 'image/jpeg', 'image/png',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists shared_docs_upload on storage.objects;
create policy shared_docs_upload on storage.objects for insert to authenticated
  with check (bucket_id = 'shared_docs' and public.is_staff_admin());
drop policy if exists shared_docs_read on storage.objects;
create policy shared_docs_read on storage.objects for select to authenticated
  using (bucket_id = 'shared_docs' and exists (select 1 from public.shared_documents d where d.file_path = name and public._can_see_shared(d.id)));
drop policy if exists shared_docs_delete on storage.objects;
create policy shared_docs_delete on storage.objects for delete to authenticated
  using (bucket_id = 'shared_docs' and public.is_staff_admin());

-- 6. Functions ---------------------------------------------------------------------------------------------------------
-- "Will be visible to N employees"
create or replace function public.preview_document_audience(p_audience jsonb) returns integer
language plpgsql stable security definer set search_path = public as $$
begin
  perform public._require_admin();
  return (select count(*)::integer from public._audience_members(p_audience));
end $$;

-- Publish.  The role, the audience and the type rules are all checked HERE; nothing sent by the app is trusted.
create or replace function public.share_document(
  p_type bigint, p_title text, p_description text, p_path text, p_file_name text,
  p_audience jsonb, p_allow_download boolean default true, p_visible_until date default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me     public.profiles := public._require_admin();          -- Admin or HR (a Project Manager is an HR-level user)
  t      public.document_types;
  v_kind text := p_audience ->> 'kind';
  v_vals jsonb := coalesce(p_audience -> 'values', '[]'::jsonb);
  v_id   bigint;
  v_n    integer;
begin
  select * into t from public.document_types where id = p_type and active;
  if t.id is null or t.direction <> 'from_cvp' then raise exception 'Choose a document type for "From C V Patil"'; end if;
  if not ((me.role = 'Admin' and 'Admin' = any (t.publishers))
          or (me.role = 'HR' and ('HR' = any (t.publishers) or ('PM' = any (t.publishers) and (to_jsonb(me) ->> 'menu_access') is not null)))) then
    raise exception 'You cannot share this type of document';
  end if;
  if nullif(trim(coalesce(p_title, '')), '') is null then raise exception 'Enter the document title'; end if;
  if v_kind is null or v_kind not in ('all', 'site', 'department', 'employee') then raise exception 'Choose who can see this document'; end if;
  if v_kind = 'all' and not t.can_all then raise exception 'This type of document cannot be shared with all employees'; end if;
  if v_kind <> 'all' and jsonb_array_length(v_vals) = 0 then raise exception 'Choose who can see this document'; end if;
  if p_path is null or p_path !~ '^from/' or not exists (select 1 from storage.objects where bucket_id = 'shared_docs' and name = p_path) then
    raise exception 'The file was not uploaded';
  end if;

  insert into public.shared_documents (type_id, title, description, file_path, file_name, uploaded_by, allow_download, visible_until, audience_kind)
  values (p_type, trim(p_title), nullif(trim(coalesce(p_description, '')), ''), p_path, p_file_name, me.id, coalesce(p_allow_download, true), p_visible_until, v_kind)
  returning id into v_id;

  if v_kind <> 'all' then
    insert into public.shared_document_audience (document_id, audience_type, audience_value)
    select v_id, v_kind, x from jsonb_array_elements_text(v_vals) x on conflict do nothing;
  end if;
  select count(*)::integer into v_n from public._audience_members(jsonb_build_object('kind', v_kind, 'values', v_vals));
  perform public._audit('DOCUMENT_SHARED', trim(p_title) || ' (' || t.name || ') to ' || v_kind || ', ' || v_n || ' employee(s), by ' || me.full_name);
  return jsonb_build_object('id', v_id, 'visible_to', v_n);
end $$;

-- Open (or download) one document: checks access, writes the view, returns the file to open.  The app then asks for a 2-minute link.
create or replace function public.open_shared_document(p_id bigint, p_download boolean default false) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._require_active(); d public.shared_documents;
begin
  if not public._can_see_shared(p_id, me.id) then raise exception 'You cannot open this document'; end if;
  select * into d from public.shared_documents where id = p_id;
  if p_download and not d.allow_download and me.role not in ('Admin', 'HR') then raise exception 'This document can be viewed only'; end if;
  insert into public.shared_document_views (document_id, user_id, downloaded) values (p_id, me.id, coalesce(p_download, false))
  on conflict (document_id, user_id) do update
     set viewed_at = now(), downloaded = public.shared_document_views.downloaded or coalesce(p_download, false);
  perform public._audit(case when p_download then 'DOCUMENT_DOWNLOADED' else 'DOCUMENT_OPENED' end, d.title);
  return jsonb_build_object('file_path', d.file_path, 'file_name', d.file_name, 'allow_download', d.allow_download);
end $$;

-- Admin / HR: who has opened it and who has not
create or replace function public.shared_document_stats(p_id bigint) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare d public.shared_documents; v_aud jsonb; v_vals jsonb; v_total integer; v_viewed integer; v_not jsonb;
begin
  perform public._require_admin();
  select * into d from public.shared_documents where id = p_id;
  if d.id is null then raise exception 'Document not found'; end if;
  select coalesce(jsonb_agg(audience_value), '[]'::jsonb) into v_vals from public.shared_document_audience where document_id = p_id;
  v_aud := jsonb_build_object('kind', d.audience_kind, 'values', v_vals);
  select count(*)::integer into v_total from public._audience_members(v_aud);
  select count(*)::integer into v_viewed from public.shared_document_views v where v.document_id = p_id and v.user_id in (select public._audience_members(v_aud));
  select coalesce(jsonb_agg(p.full_name order by p.full_name), '[]'::jsonb) into v_not
    from public.profiles p
   where p.id in (select public._audience_members(v_aud))
     and not exists (select 1 from public.shared_document_views v where v.document_id = p_id and v.user_id = p.id);
  return jsonb_build_object('audience', v_total, 'viewed', v_viewed, 'not_viewed', v_not);
end $$;

-- Admin / HR: remove a shared document (returns the file path so the app can delete the file)
create or replace function public.delete_shared_document(p_id bigint) returns text
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._require_admin(); d public.shared_documents;
begin
  select * into d from public.shared_documents where id = p_id;
  if d.id is null then raise exception 'Document not found'; end if;
  delete from public.shared_documents where id = p_id;
  perform public._audit('DOCUMENT_SHARE_DELETED', d.title || ' (by ' || me.full_name || ')');
  return d.file_path;
end $$;

revoke all on function public._can_see_shared(bigint, uuid) from public, anon;
revoke all on function public._audience_members(jsonb) from public, anon, authenticated;
revoke all on function public.preview_document_audience(jsonb) from public, anon;
revoke all on function public.share_document(bigint, text, text, text, text, jsonb, boolean, date) from public, anon;
revoke all on function public.open_shared_document(bigint, boolean) from public, anon;
revoke all on function public.shared_document_stats(bigint) from public, anon;
revoke all on function public.delete_shared_document(bigint) from public, anon;
grant execute on function public._can_see_shared(bigint, uuid) to authenticated;
grant execute on function public.preview_document_audience(jsonb) to authenticated;
grant execute on function public.share_document(bigint, text, text, text, text, jsonb, boolean, date) to authenticated;
grant execute on function public.open_shared_document(bigint, boolean) to authenticated;
grant execute on function public.shared_document_stats(bigint) to authenticated;
grant execute on function public.delete_shared_document(bigint) to authenticated;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------
-- UNDO (only if needed; nothing is deleted): switch the sharing off again
--   revoke execute on function public.share_document(bigint, text, text, text, text, jsonb, boolean, date) from authenticated;
-- ---------------------------------------------------------------------
