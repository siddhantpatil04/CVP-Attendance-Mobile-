-- ---------------------------------------------------------------------
-- 45. EMPLOYEE DETAILS FORM (C. V. Patil & Associates "Employee Form") + KYC DOCUMENTS
--     * employee_details       : one row per person with every field of the paper form
--                                (personal, address, PAN / Aadhar, education, skills, family, vehicle, bank, joining date).
--     * employee_detail_files  : one file per kind - photo, PAN, Aadhar, graduation, CV, bank passbook (1st page).
--                                A new upload replaces the old one.
--     * The employee fills and edits his own form (no Documents access needed). Admin / HR can fill or edit it for
--       any Employee (only an Admin can do so for HR / Admin accounts) and can view / download every file.
--     * Files live in the private "employee_detail_docs" bucket: <employee-uuid>/<kind>-<timestamp>-<name>.
--     Safe to run again. Run it after section 44.
-- ---------------------------------------------------------------------
create table if not exists public.employee_details (
  user_id            uuid primary key references public.profiles(id) on delete cascade,
  surname            text,
  first_name         text,
  father_name        text,
  mother_name        text,
  date_of_birth      date,
  gender             text,
  marital_status     text,
  permanent_address  text,
  local_address      text,
  tel_no             text,
  cell_no            text,
  email              text,
  pan_no             text,
  aadhar_no          text,
  education          jsonb not null default '[]'::jsonb,   -- [{degree, specialization, year, marks}]
  software_skills    text,
  family             jsonb not null default '[]'::jsonb,   -- [{name, relation, contact}]
  vehicle_company    text,
  vehicle_no         text,
  license_no         text,
  bank_name          text,
  bank_address       text,
  bank_branch        text,
  bank_account_no    text,
  ifsc_code          text,
  joining_date       date,
  resign_date        date,
  uan_no             text,
  declared           boolean not null default false,
  updated_at         timestamptz not null default now(),
  updated_by         uuid references public.profiles(id) on delete set null
);
alter table public.employee_details add column if not exists resign_date date;
alter table public.employee_details add column if not exists uan_no text;
alter table public.employee_details enable row level security;
drop policy if exists employee_details_read on public.employee_details;
create policy employee_details_read on public.employee_details for select to authenticated
  using (user_id = auth.uid() or private.is_staff_admin());
revoke all on public.employee_details from anon;
grant select on public.employee_details to authenticated;

create table if not exists public.employee_detail_files (
  id           bigint generated always as identity primary key,
  user_id      uuid not null references public.profiles(id) on delete cascade,
  kind         text not null check (kind in ('photo', 'pan', 'aadhar', 'graduation', 'cv', 'bank')),
  file_path    text not null,
  file_name    text,
  uploaded_by  uuid references public.profiles(id) on delete set null,
  created_at   timestamptz not null default now(),
  unique (user_id, kind)
);
alter table public.employee_detail_files enable row level security;
drop policy if exists employee_detail_files_read on public.employee_detail_files;
create policy employee_detail_files_read on public.employee_detail_files for select to authenticated
  using (user_id = auth.uid() or private.is_staff_admin());
revoke all on public.employee_detail_files from anon;
grant select on public.employee_detail_files to authenticated;

do $$
begin
  if not exists (select 1 from pg_publication_tables
                  where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'employee_detail_files') then
    alter publication supabase_realtime add table public.employee_detail_files;
  end if;
end $$;

-- Who may change the form / files of p_user: himself, or Admin / HR (HR only for plain Employees)
create or replace function public._detail_actor(p_user uuid) returns public.profiles
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._require_active(); t public.profiles;
begin
  if p_user is null or p_user = me.id then return me; end if;
  me := public._require_admin();
  select * into t from public.profiles where id = p_user and active;
  if t.id is null then raise exception 'User not found'; end if;
  if me.role <> 'Admin' and t.role <> 'Employee' then raise exception 'Only an Admin can change HR / Admin accounts'; end if;
  return me;
end $$;

-- p_user null = your own form. p_data = the form fields (see the columns above).
create or replace function public.save_employee_details(p_user uuid, p_data jsonb)
returns public.employee_details
language plpgsql security definer set search_path = public as $$
declare
  me   public.profiles := public._detail_actor(p_user);
  v_for uuid := coalesce(p_user, me.id);
  d    jsonb := coalesce(p_data, '{}'::jsonb);
  r    public.employee_details;
  v_pan text := upper(nullif(trim(d->>'pan_no'), ''));
  v_aad text := regexp_replace(coalesce(d->>'aadhar_no', ''), '\s', '', 'g');
  v_ifsc text := upper(nullif(trim(d->>'ifsc_code'), ''));
  v_dob  date := nullif(trim(d->>'date_of_birth'), '')::date;
  v_join date := nullif(trim(d->>'joining_date'), '')::date;
  v_resign date := nullif(trim(d->>'resign_date'), '')::date;
  v_uan text := nullif(regexp_replace(coalesce(d->>'uan_no', ''), '\s', '', 'g'), '');
begin
  if nullif(trim(d->>'permanent_address'), '') is null then raise exception 'Enter the permanent address'; end if;
  if nullif(trim(d->>'local_address'), '') is null then raise exception 'Enter the local address'; end if;
  if nullif(trim(d->>'cell_no'), '') is null then raise exception 'Enter the cell number'; end if;
  if v_pan is not null and v_pan !~ '^[A-Z]{5}[0-9]{4}[A-Z]$' then raise exception 'PAN number looks wrong (example ABCDE1234F)'; end if;
  if v_aad <> '' and v_aad !~ '^[0-9]{12}$' then raise exception 'Aadhar number must be 12 digits'; end if;
  if v_ifsc is not null and v_ifsc !~ '^[A-Z]{4}0[A-Z0-9]{6}$' then raise exception 'IFSC code looks wrong (example SBIN0001234)'; end if;
  if nullif(trim(d->>'bank_name'), '') is null then raise exception 'Enter the bank name'; end if;
  if nullif(trim(d->>'bank_address'), '') is null then raise exception 'Enter the bank address'; end if;
  if nullif(trim(d->>'bank_branch'), '') is null then raise exception 'Enter the bank branch'; end if;
  if nullif(trim(d->>'bank_account_no'), '') is null then raise exception 'Enter the bank account number'; end if;
  if v_ifsc is null then raise exception 'Enter the IFSC code'; end if;
  if v_join is null then raise exception 'Enter the joining date'; end if;
  if v_resign is not null and v_resign < v_join then raise exception 'Resign date cannot be before the joining date'; end if;
  if v_uan is not null and v_uan !~ '^[0-9]{12}$' then raise exception 'UAN number must be 12 digits'; end if;
  if v_dob is not null and v_dob >= public.ist_today() then raise exception 'Date of birth must be in the past'; end if;

  insert into public.employee_details as e (
    user_id, surname, first_name, father_name, mother_name, date_of_birth, gender, marital_status,
    permanent_address, local_address, tel_no, cell_no, email, pan_no, aadhar_no,
    education, software_skills, family, vehicle_company, vehicle_no, license_no,
    bank_name, bank_address, bank_branch, bank_account_no, ifsc_code, joining_date, resign_date, uan_no, declared, updated_at, updated_by
  ) values (
    v_for, nullif(trim(d->>'surname'), ''), nullif(trim(d->>'first_name'), ''), nullif(trim(d->>'father_name'), ''),
    nullif(trim(d->>'mother_name'), ''), v_dob, nullif(trim(d->>'gender'), ''), nullif(trim(d->>'marital_status'), ''),
    trim(d->>'permanent_address'), trim(d->>'local_address'), nullif(trim(d->>'tel_no'), ''), trim(d->>'cell_no'),
    nullif(trim(d->>'email'), ''), v_pan, nullif(v_aad, ''),
    case when jsonb_typeof(d->'education') = 'array' then d->'education' else '[]'::jsonb end,
    nullif(trim(d->>'software_skills'), ''),
    case when jsonb_typeof(d->'family') = 'array' then d->'family' else '[]'::jsonb end,
    nullif(trim(d->>'vehicle_company'), ''), nullif(trim(d->>'vehicle_no'), ''), nullif(trim(d->>'license_no'), ''),
    trim(d->>'bank_name'), trim(d->>'bank_address'), trim(d->>'bank_branch'), trim(d->>'bank_account_no'), v_ifsc,
    v_join, v_resign, v_uan, coalesce((d->>'declared')::boolean, false), now(), me.id
  )
  on conflict (user_id) do update set
    surname = excluded.surname, first_name = excluded.first_name, father_name = excluded.father_name,
    mother_name = excluded.mother_name, date_of_birth = excluded.date_of_birth, gender = excluded.gender,
    marital_status = excluded.marital_status, permanent_address = excluded.permanent_address,
    local_address = excluded.local_address, tel_no = excluded.tel_no, cell_no = excluded.cell_no, email = excluded.email,
    pan_no = excluded.pan_no, aadhar_no = excluded.aadhar_no, education = excluded.education,
    software_skills = excluded.software_skills, family = excluded.family, vehicle_company = excluded.vehicle_company,
    vehicle_no = excluded.vehicle_no, license_no = excluded.license_no, bank_name = excluded.bank_name,
    bank_address = excluded.bank_address, bank_branch = excluded.bank_branch, bank_account_no = excluded.bank_account_no,
    ifsc_code = excluded.ifsc_code, joining_date = excluded.joining_date, resign_date = excluded.resign_date, uan_no = excluded.uan_no, declared = excluded.declared,
    updated_at = now(), updated_by = me.id
  returning * into r;
  -- the joining date of the form is the one payroll uses
  update public.profiles set joining_date = v_join where id = v_for and joining_date is distinct from v_join;
  perform public._audit('EMPLOYEE_DETAILS', 'saved for ' || (select username from public.profiles where id = v_for));
  return r;
end $$;

-- Attach (or replace) one document of the form. Returns the OLD file path (to delete from storage), or null.
create or replace function public.set_employee_detail_file(p_user uuid, p_kind text, p_path text, p_file_name text default null)
returns text
language plpgsql security definer set search_path = public as $$
declare
  me    public.profiles := public._detail_actor(p_user);
  v_for uuid := coalesce(p_user, me.id);
  v_old text;
begin
  if p_kind not in ('photo', 'pan', 'aadhar', 'graduation', 'cv', 'bank') then raise exception 'Unknown document'; end if;
  if p_path is null or split_part(p_path, '/', 1) <> v_for::text then raise exception 'Attach the document first'; end if;
  select file_path into v_old from public.employee_detail_files where user_id = v_for and kind = p_kind;
  insert into public.employee_detail_files (user_id, kind, file_path, file_name, uploaded_by)
  values (v_for, p_kind, p_path, nullif(trim(p_file_name), ''), me.id)
  on conflict (user_id, kind) do update
    set file_path = excluded.file_path, file_name = excluded.file_name, uploaded_by = excluded.uploaded_by, created_at = now();
  perform public._audit('EMPLOYEE_DETAIL_FILE', p_kind || ' for ' || (select username from public.profiles where id = v_for));
  return v_old;
end $$;

-- Remove one document of the form. Returns the file path to delete from storage.
create or replace function public.delete_employee_detail_file(p_user uuid, p_kind text) returns text
language plpgsql security definer set search_path = public as $$
declare
  me    public.profiles := public._detail_actor(p_user);
  v_for uuid := coalesce(p_user, me.id);
  v_path text;
begin
  delete from public.employee_detail_files where user_id = v_for and kind = p_kind returning file_path into v_path;
  if v_path is null then raise exception 'Document not found'; end if;
  perform public._audit('DELETE_EMPLOYEE_DETAIL_FILE', p_kind || ' for ' || (select username from public.profiles where id = v_for));
  return v_path;
end $$;

revoke execute on function public._detail_actor(uuid) from public, anon, authenticated;
revoke execute on function public.save_employee_details(uuid, jsonb) from public, anon;
revoke execute on function public.set_employee_detail_file(uuid, text, text, text) from public, anon;
revoke execute on function public.delete_employee_detail_file(uuid, text) from public, anon;
grant  execute on function public.save_employee_details(uuid, jsonb) to authenticated;
grant  execute on function public.set_employee_detail_file(uuid, text, text, text) to authenticated;
grant  execute on function public.delete_employee_detail_file(uuid, text) to authenticated;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('employee_detail_docs', 'employee_detail_docs', false, 10485760, array[
  'application/pdf', 'image/jpeg', 'image/png', 'image/webp',
  'application/msword', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document'])
on conflict (id) do update
  set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists employee_detail_docs_upload on storage.objects;
create policy employee_detail_docs_upload on storage.objects for insert to authenticated
  with check (
    bucket_id = 'employee_detail_docs'
    and (private.is_staff_admin()
         or ((storage.foldername(name))[1] = auth.uid()::text
             and exists (select 1 from public.profiles p where p.id = auth.uid() and p.active)))
  );
drop policy if exists employee_detail_docs_read on storage.objects;
create policy employee_detail_docs_read on storage.objects for select to authenticated
  using (bucket_id = 'employee_detail_docs' and ((storage.foldername(name))[1] = auth.uid()::text or private.is_staff_admin()));
drop policy if exists employee_detail_docs_delete on storage.objects;
create policy employee_detail_docs_delete on storage.objects for delete to authenticated
  using (bucket_id = 'employee_detail_docs' and ((storage.foldername(name))[1] = auth.uid()::text or private.is_staff_admin()));

notify pgrst, 'reload schema';
