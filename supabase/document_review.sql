-- ---------------------------------------------------------------------
-- DOCUMENT SUBMISSION AND MANAGEMENT: category + review workflow for submitted documents
--   * An employee (with Documents access) submits a document with a category and a remark -> status "Submitted".
--   * Admin / HR open it, set the status (Under Review / Approved / Rejected) and write a note. The employee sees both.
--   * Everything that already exists (upload, view, download, delete, Documents Report, private storage) is kept.
-- Run in Supabase Dashboard -> SQL Editor -> New query -> Run.  Safe to run again.
-- ---------------------------------------------------------------------
alter table public.employee_documents add column if not exists category    text;
alter table public.employee_documents add column if not exists status      text not null default 'Submitted';
alter table public.employee_documents add column if not exists review_note text;
alter table public.employee_documents add column if not exists reviewed_by uuid references public.profiles(id) on delete set null;
alter table public.employee_documents add column if not exists reviewed_at timestamptz;

alter table public.employee_documents drop constraint if exists employee_documents_status_check;
alter table public.employee_documents add constraint employee_documents_status_check
  check (status in ('Submitted', 'Under Review', 'Approved', 'Rejected', 'Sent'));

-- documents that Admin / HR sent to an employee are not reviewed: they are "Sent"
update public.employee_documents set status = 'Sent' where direction = 'from_admin' and status = 'Submitted';

create index if not exists employee_documents_status_idx on public.employee_documents (status);

-- Upload (replaces the old 5-argument version: a new optional category is added)
drop function if exists public.add_employee_document(uuid, text, text, text, text);
create or replace function public.add_employee_document(
  p_user uuid, p_title text, p_remark text, p_path text, p_file_name text default null, p_category text default null
) returns public.employee_documents
language plpgsql security definer set search_path = public as $$
declare
  me     public.profiles := public._require_active();
  v_for  uuid := coalesce(p_user, me.id);
  v_dir  text;
  t      public.profiles;
  r      public.employee_documents;
begin
  if v_for = me.id then
    if not me.documents_access then raise exception 'Documents are not enabled for your account. Ask your Admin'; end if;
    v_dir := 'from_employee';
  else
    me := public._require_admin();
    select * into t from public.profiles where id = v_for and active;
    if t.id is null then raise exception 'User not found'; end if;
    if me.role not in ('Admin', 'HR') and t.role <> 'Employee' then raise exception 'Only an Admin can change HR / Admin accounts'; end if;
    v_dir := 'from_admin';
  end if;
  if nullif(trim(p_title),'') is null then raise exception 'Enter the document name'; end if;
  if p_path is null or split_part(p_path, '/', 1) <> v_for::text then raise exception 'Attach the document first'; end if;
  insert into public.employee_documents (user_id, direction, title, remark, file_path, file_name, uploaded_by, category, status)
  values (v_for, v_dir, trim(p_title), nullif(trim(p_remark),''), p_path, nullif(trim(p_file_name),''), me.id,
          nullif(trim(p_category),''), case when v_dir = 'from_admin' then 'Sent' else 'Submitted' end)
  returning * into r;
  perform public._audit('EMPLOYEE_DOCUMENT', v_dir || ' ' || r.title);
  return r;
end $$;

-- Admin / HR: review a document an employee submitted
create or replace function public.review_employee_document(p_id bigint, p_status text, p_note text default null)
returns public.employee_documents
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._require_admin(); r public.employee_documents;
begin
  if p_status not in ('Under Review', 'Approved', 'Rejected') then raise exception 'Choose Under Review, Approved or Rejected'; end if;
  update public.employee_documents
     set status = p_status, review_note = nullif(trim(p_note),''), reviewed_by = me.id, reviewed_at = now()
   where id = p_id and direction = 'from_employee'
  returning * into r;
  if r.id is null then raise exception 'Document not found (only documents submitted by employees can be reviewed)'; end if;
  perform public._audit('REVIEW_DOCUMENT', r.title || ' -> ' || p_status);
  return r;
end $$;

revoke execute on function public.add_employee_document(uuid, text, text, text, text, text) from public, anon;
revoke execute on function public.review_employee_document(bigint, text, text) from public, anon;
grant  execute on function public.add_employee_document(uuid, text, text, text, text, text) to authenticated;
grant  execute on function public.review_employee_document(bigint, text, text) to authenticated;

notify pgrst, 'reload schema';
