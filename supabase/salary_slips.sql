-- =====================================================================
-- SEND SALARY SLIPS to every employee + PROOF (sent / opened / downloaded / acknowledged)
--
-- Salary calculation and the slip layout do NOT change. This only stores the SENT slip PDF and records the proof.
-- A slip can only be sent for a FINALIZED month (payroll_months).
--
-- This file ONLY ADDS:
--   1. storage bucket "salary-slips"   (private; path <user_id>/<yyyy-mm>/<slip_no>.pdf; the employee reads only his own folder,
--                                       Admin / HR read all; there is NO update / delete policy: a sent file can never be overwritten or deleted)
--   2. table salary_slip_sends         (one ACTIVE row per employee per month; a corrected slip is a new row, the old one is kept: replaced_by)
--   3. RLS                             (an employee reads only his own rows; Admin / HR read all; only the functions below write)
--   4. functions  record_slip_sent / mark_slip_opened / mark_slip_downloaded / acknowledge_slip / raise_slip_query / answer_slip_query / send_slip_reminder
--   5. notifications                   each send / reminder / query / answer also adds a row to public.notifications (the phone notification
--                                      system, notifications.sql). If that table does not exist the notification is SKIPPED and everything else still works.
-- It does NOT touch attendance, leave, salary, payroll_months or any existing row.
-- Needs payroll_months.sql first.   notifications.sql is optional (for the phone / bell notification).
--
-- BACK UP FIRST.   Supabase -> SQL Editor -> paste the WHOLE file -> Run.   Safe to run again.   Undo: see the UNDO block at the end.
-- =====================================================================

-- 1. private bucket ------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('salary-slips', 'salary-slips', false, 5242880, array['application/pdf'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists salary_slips_upload on storage.objects;
create policy salary_slips_upload on storage.objects for insert to authenticated
  with check (bucket_id = 'salary-slips' and public.is_staff_admin());          -- only Admin / HR add a slip
drop policy if exists salary_slips_read on storage.objects;
create policy salary_slips_read on storage.objects for select to authenticated
  using (bucket_id = 'salary-slips' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_staff_admin()));
-- (no update / delete policy on purpose)

-- 2. the table -----------------------------------------------------------------
create table if not exists public.salary_slip_sends (
  id               bigint generated always as identity primary key,
  user_id          uuid    not null references public.profiles(id) on delete cascade,
  month            date    not null check (extract(day from month) = 1),     -- the 1st of the salary month
  slip_no          text    not null,
  net_pay          numeric(12, 2) not null,
  file_path        text    not null,
  file_sha256      text    not null,
  sent_at          timestamptz not null default now(),
  sent_by          uuid    references public.profiles(id) on delete set null,
  opened_at        timestamptz,
  downloaded_at    timestamptz,
  acknowledged_at  timestamptz,
  ack_device       text,
  reminder_sent_at timestamptz,
  query_text       text,
  query_at         timestamptz,
  query_answer     text,
  answered_by      uuid    references public.profiles(id) on delete set null,
  answered_at      timestamptz,
  replaced_by      bigint,                                                    -- id of the corrected slip (NULL = the active slip; 0 only while a resend is being saved)
  created_at       timestamptz not null default now(),
  unique (slip_no, user_id)
);
create unique index if not exists salary_slip_one_active on public.salary_slip_sends (user_id, month) where replaced_by is null;
create index if not exists salary_slip_month_idx on public.salary_slip_sends (month);

-- 3. RLS --------------------------------------------------------------------------
alter table public.salary_slip_sends enable row level security;
drop policy if exists salary_slip_read on public.salary_slip_sends;
create policy salary_slip_read on public.salary_slip_sends for select to authenticated
  using (user_id = auth.uid() or public.is_staff_admin());
revoke all on public.salary_slip_sends from anon, authenticated;
grant select on public.salary_slip_sends to authenticated;

-- 5. notification helper (skipped when the notifications table is not installed) ---------------------------
-- the allowed kinds of notifications get the slip kinds
do $$
begin
  if to_regclass('public.notifications') is not null then
    alter table public.notifications drop constraint if exists notifications_kind_check;
    alter table public.notifications add constraint notifications_kind_check
      check (kind in ('LEAVE_APPROVED', 'LEAVE_REJECTED', 'REG_APPROVED', 'REG_REJECTED', 'TEST', 'SLIP_READY', 'SLIP_REMINDER', 'SLIP_QUERY', 'SLIP_ANSWER'));
  end if;
end $$;

create or replace function public._slip_notify(p_user uuid, p_kind text, p_title text, p_body text, p_link text, p_data jsonb)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if to_regclass('public.notifications') is null then return; end if;
  begin
    execute 'insert into public.notifications (user_id, kind, title, body, link, data) values ($1, $2, $3, $4, $5, $6)' using p_user, p_kind, p_title, p_body, p_link, p_data;
  exception when others then
    raise warning 'slip notification not created: %', sqlerrm;     -- never fail the slip itself
  end;
end $$;
revoke all on function public._slip_notify(uuid, text, text, text, text, jsonb) from public, anon, authenticated;

-- 4. functions ------------------------------------------------------------------------
-- Admin / HR: the slip PDF is already in the bucket; this records it. The month must be finalized.
-- A second send for the same employee + month (a CORRECTED slip, new slip_no) keeps the old row and marks it replaced_by.
create or replace function public.record_slip_sent(p_user uuid, p_month date, p_slip_no text, p_net numeric, p_path text, p_sha256 text)
returns public.salary_slip_sends
language plpgsql security definer set search_path = public as $$
declare
  me   public.profiles := public._require_admin();
  m0   date := date_trunc('month', p_month::timestamp)::date;
  old  public.salary_slip_sends;
  newr public.salary_slip_sends;
  nm   text;
begin
  if not exists (select 1 from public.payroll_months where year = extract(year from m0)::int and month = extract(month from m0)::int) then
    raise exception 'Finalize % first, then send slips', to_char(m0, 'FMMonth YYYY');
  end if;
  if not exists (select 1 from public.profiles where id = p_user and active) then raise exception 'Employee not found'; end if;
  if p_path is null or split_part(p_path, '/', 1) <> p_user::text then raise exception 'The slip file is not in this employee''s folder'; end if;
  if coalesce(trim(p_slip_no), '') = '' or p_sha256 is null or length(p_sha256) <> 64 then raise exception 'Slip number or file checksum is missing'; end if;

  select * into old from public.salary_slip_sends where user_id = p_user and month = m0 and replaced_by is null for update;
  if old.id is not null then
    if old.slip_no = p_slip_no then raise exception 'This slip (%) was already sent. A corrected slip needs a new slip number', p_slip_no; end if;
    update public.salary_slip_sends set replaced_by = 0 where id = old.id;          -- frees the "one active slip" slot while the new row is added
  end if;

  insert into public.salary_slip_sends (user_id, month, slip_no, net_pay, file_path, file_sha256, sent_by)
  values (p_user, m0, p_slip_no, p_net, p_path, lower(p_sha256), me.id) returning * into newr;
  if old.id is not null then update public.salary_slip_sends set replaced_by = newr.id where id = old.id; end if;

  select full_name into nm from public.profiles where id = p_user;
  perform public._audit(case when old.id is null then 'SALARY_SLIP_SENT' else 'SALARY_SLIP_RESENT' end,
    coalesce(nm, '') || ' ' || to_char(m0, 'Mon YYYY') || ' slip ' || p_slip_no);
  perform public._slip_notify(p_user, 'SLIP_READY', '💰 Salary slip ready',
    'Your salary slip for ' || to_char(m0, 'FMMonth YYYY') || ' is ready. Net pay Rs ' || to_char(p_net, 'FM99,99,999.00') || '. Tap to view.',
    'MySalary', jsonb_build_object('slip_id', newr.id, 'link', 'MySalary'));
  return newr;
end $$;
revoke all on function public.record_slip_sent(uuid, date, text, numeric, text, text) from public, anon;
grant execute on function public.record_slip_sent(uuid, date, text, numeric, text, text) to authenticated;

-- the employee himself; only the FIRST time is kept
create or replace function public.mark_slip_opened(p_id bigint) returns void
language sql security definer set search_path = public as $$
  update public.salary_slip_sends set opened_at = now() where id = p_id and user_id = auth.uid() and opened_at is null;
$$;
revoke all on function public.mark_slip_opened(bigint) from public, anon;
grant execute on function public.mark_slip_opened(bigint) to authenticated;

create or replace function public.mark_slip_downloaded(p_id bigint) returns void
language sql security definer set search_path = public as $$
  update public.salary_slip_sends set downloaded_at = now(), opened_at = coalesce(opened_at, now())
   where id = p_id and user_id = auth.uid() and downloaded_at is null;
$$;
revoke all on function public.mark_slip_downloaded(bigint) from public, anon;
grant execute on function public.mark_slip_downloaded(bigint) to authenticated;

-- the employee himself, once
create or replace function public.acknowledge_slip(p_id bigint, p_device text default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  update public.salary_slip_sends
     set acknowledged_at = now(), ack_device = nullif(left(trim(coalesce(p_device, '')), 200), ''), opened_at = coalesce(opened_at, now())
   where id = p_id and user_id = auth.uid() and acknowledged_at is null;
end $$;
revoke all on function public.acknowledge_slip(bigint, text) from public, anon;
grant execute on function public.acknowledge_slip(bigint, text) to authenticated;

-- the employee raises a query on his slip; HR / Admin are notified
create or replace function public.raise_slip_query(p_id bigint, p_text text) returns void
language plpgsql security definer set search_path = public as $$
declare s public.salary_slip_sends; nm text; a record;
begin
  if coalesce(trim(p_text), '') = '' then raise exception 'Type your query'; end if;
  update public.salary_slip_sends set query_text = left(trim(p_text), 1000), query_at = now(), query_answer = null, answered_by = null, answered_at = null
   where id = p_id and user_id = auth.uid() returning * into s;
  if s.id is null then raise exception 'Salary slip not found'; end if;
  select full_name into nm from public.profiles where id = s.user_id;
  perform public._audit('SALARY_SLIP_QUERY', coalesce(nm, '') || ' ' || to_char(s.month, 'Mon YYYY'));
  for a in select id from public.profiles where active and role in ('HR', 'Admin') loop
    perform public._slip_notify(a.id, 'SLIP_QUERY', '❓ Salary slip query', coalesce(nm, 'An employee') || ' raised a query on the ' || to_char(s.month, 'FMMonth YYYY') || ' slip.', 'SalaryManagement', jsonb_build_object('slip_id', s.id));
  end loop;
end $$;
revoke all on function public.raise_slip_query(bigint, text) from public, anon;
grant execute on function public.raise_slip_query(bigint, text) to authenticated;

-- HR / Admin answer; the employee is notified
create or replace function public.answer_slip_query(p_id bigint, p_answer text) returns void
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._require_admin(); s public.salary_slip_sends;
begin
  if coalesce(trim(p_answer), '') = '' then raise exception 'Type the answer'; end if;
  update public.salary_slip_sends set query_answer = left(trim(p_answer), 1000), answered_by = me.id, answered_at = now()
   where id = p_id and query_text is not null returning * into s;
  if s.id is null then raise exception 'There is no query to answer'; end if;
  perform public._audit('SALARY_SLIP_ANSWER', to_char(s.month, 'Mon YYYY') || ' slip ' || s.slip_no);
  perform public._slip_notify(s.user_id, 'SLIP_ANSWER', '💬 Your salary slip query was answered', left(trim(p_answer), 180), 'MySalary', jsonb_build_object('slip_id', s.id, 'link', 'MySalary'));
end $$;
revoke all on function public.answer_slip_query(bigint, text) from public, anon;
grant execute on function public.answer_slip_query(bigint, text) to authenticated;

-- HR / Admin: remind the employees who have not acknowledged
create or replace function public.send_slip_reminder(p_ids bigint[]) returns integer
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._require_admin(); s public.salary_slip_sends; n integer := 0;
begin
  for s in select * from public.salary_slip_sends where id = any (p_ids) and replaced_by is null and acknowledged_at is null loop
    update public.salary_slip_sends set reminder_sent_at = now() where id = s.id;
    perform public._slip_notify(s.user_id, 'SLIP_REMINDER', '🔔 Salary slip reminder',
      'Please open and acknowledge your ' || to_char(s.month, 'FMMonth YYYY') || ' salary slip.', 'MySalary', jsonb_build_object('slip_id', s.id, 'link', 'MySalary'));
    n := n + 1;
  end loop;
  if n > 0 then perform public._audit('SALARY_SLIP_REMINDER', n || ' reminder(s)'); end if;
  return n;
end $$;
revoke all on function public.send_slip_reminder(bigint[]) from public, anon;
grant execute on function public.send_slip_reminder(bigint[]) to authenticated;

notify pgrst, 'reload schema';

-- CHECK after running:
--   select id, public from storage.buckets where id = 'salary-slips';      -- public = false
--   select count(*) from public.salary_slip_sends;                          -- 0

-- =====================================================================
-- UNDO (rollback): commented out so it does NOT run with the file. To remove the feature, select the lines below (without the leading "-- "),
-- paste them in the SQL Editor on their own and Run. Sent-slip records are lost; the PDF files in the bucket must be emptied first
-- in Storage > salary-slips (Supabase does not allow dropping a bucket that still holds files).
-- =====================================================================
-- drop function if exists public.send_slip_reminder(bigint[]);
-- drop function if exists public.answer_slip_query(bigint, text);
-- drop function if exists public.raise_slip_query(bigint, text);
-- drop function if exists public.acknowledge_slip(bigint, text);
-- drop function if exists public.mark_slip_downloaded(bigint);
-- drop function if exists public.mark_slip_opened(bigint);
-- drop function if exists public.record_slip_sent(uuid, date, text, numeric, text, text);
-- drop function if exists public._slip_notify(uuid, text, text, text, text, jsonb);
-- drop table if exists public.salary_slip_sends;
-- drop policy if exists salary_slips_upload on storage.objects;
-- drop policy if exists salary_slips_read on storage.objects;
-- delete from storage.buckets where id = 'salary-slips';
-- notify pgrst, 'reload schema';
