-- =====================================================================
-- PHONE NOTIFICATIONS: Leave / Regularization approved or rejected -> a notification for THAT employee only
--
-- This file ONLY ADDS:
--   1. push_tokens            (one row per phone: Expo push token of a signed-in user)
--   2. notifications          (one row per message; the bell list reads it; a Database Webhook sends the phone push)
--   3. RLS                    (a user reads his OWN rows; nobody inserts or updates directly)
--   4. functions              save_push_token / remove_push_token / mark_notifications_read / send_test_notification / admin_push_device_count
--   5. triggers               AFTER UPDATE OF status on leaves and regularizations (Pending -> Approved / Rejected)
--   6. realtime               notifications is added to supabase_realtime (the bell updates live)
-- The triggers never block or roll back an approval: the insert is wrapped in BEGIN ... EXCEPTION WHEN others THEN (ignored).
-- review_leave(), review_regularization(), leave rules, balances, attendance and salary are NOT changed. No existing row is touched.
--
-- BACK UP FIRST.   Supabase -> SQL Editor -> paste the WHOLE file -> Run.   Safe to run again.   Undo: see the UNDO block at the end of this file
-- Then deploy the Edge Function and create the Database Webhook (see supabase/functions/send-push/SETUP.md).
-- =====================================================================

-- 1. push tokens --------------------------------------------------------
create table if not exists public.push_tokens (
  id          bigint generated always as identity primary key,
  user_id     uuid not null references public.profiles(id) on delete cascade,
  token       text not null unique,
  platform    text not null check (platform in ('android', 'ios')),
  device_name text,
  created_at  timestamptz not null default now(),
  last_seen   timestamptz not null default now()
);
create index if not exists push_tokens_user_idx on public.push_tokens (user_id);

-- 2. notifications -------------------------------------------------------
create table if not exists public.notifications (
  id          bigint generated always as identity primary key,
  user_id     uuid not null references public.profiles(id) on delete cascade,
  kind        text not null check (kind in ('LEAVE_APPROVED', 'LEAVE_REJECTED', 'REG_APPROVED', 'REG_REJECTED', 'TEST', 'SLIP_READY', 'SLIP_REMINDER', 'SLIP_QUERY', 'SLIP_ANSWER')),
  title       text not null,
  body        text not null,
  link        text,                              -- screen name: 'MyLeave' / 'Regularization'
  data        jsonb not null default '{}'::jsonb,
  read_at     timestamptz,
  sent_at     timestamptz,
  push_error  text,
  created_at  timestamptz not null default now()
);
create index if not exists notifications_user_idx on public.notifications (user_id, id desc);

-- 3. RLS -------------------------------------------------------------------
alter table public.push_tokens   enable row level security;
alter table public.notifications enable row level security;

drop policy if exists push_tokens_own on public.push_tokens;
create policy push_tokens_own on public.push_tokens for select to authenticated using (user_id = auth.uid());

drop policy if exists notifications_own on public.notifications;
create policy notifications_own on public.notifications for select to authenticated using (user_id = auth.uid());

-- nobody writes directly: only the functions below (security definer). Even read_at is set through mark_notifications_read().
revoke all on public.push_tokens   from anon, authenticated;
revoke all on public.notifications from anon, authenticated;
grant select on public.push_tokens   to authenticated;
grant select on public.notifications to authenticated;

-- 4. functions -------------------------------------------------------------
-- a token belongs to ONE user at a time: a phone used by another employee moves to the current user
create or replace function public.save_push_token(p_token text, p_platform text, p_device_name text default null)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Not signed in' using errcode = '42501'; end if;
  if p_token is null or length(trim(p_token)) < 10 then raise exception 'Invalid push token'; end if;
  if p_platform not in ('android', 'ios') then raise exception 'Invalid platform'; end if;
  insert into public.push_tokens (user_id, token, platform, device_name)
  values (auth.uid(), trim(p_token), p_platform, nullif(trim(coalesce(p_device_name, '')), ''))
  on conflict (token) do update
    set user_id = auth.uid(), platform = excluded.platform, device_name = excluded.device_name, last_seen = now();
end $$;
revoke all on function public.save_push_token(text, text, text) from public, anon;
grant execute on function public.save_push_token(text, text, text) to authenticated;

-- only the owner of the token can remove it (called BEFORE signing out)
create or replace function public.remove_push_token(p_token text)
returns void
language sql security definer set search_path = public as $$
  delete from public.push_tokens where token = p_token and user_id = auth.uid();
$$;
revoke all on function public.remove_push_token(text) from public, anon;
grant execute on function public.remove_push_token(text) to authenticated;

-- mark some (or, with null, all) of MY notifications as read
create or replace function public.mark_notifications_read(p_ids bigint[] default null)
returns integer
language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  if auth.uid() is null then raise exception 'Not signed in' using errcode = '42501'; end if;
  update public.notifications set read_at = now()
   where user_id = auth.uid() and read_at is null and (p_ids is null or id = any (p_ids));
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.mark_notifications_read(bigint[]) from public, anon;
grant execute on function public.mark_notifications_read(bigint[]) to authenticated;

-- "Send test notification": a test row for ME only
create or replace function public.send_test_notification()
returns bigint
language plpgsql security definer set search_path = public as $$
declare nid bigint;
begin
  if auth.uid() is null then raise exception 'Not signed in' using errcode = '42501'; end if;
  insert into public.notifications (user_id, kind, title, body, link)
  values (auth.uid(), 'TEST', '🔔 Test notification', 'Notifications are working on this phone.', null)
  returning id into nid;
  return nid;
end $$;
revoke all on function public.send_test_notification() from public, anon;
grant execute on function public.send_test_notification() to authenticated;

-- how many phones does a user have (Approvals screen: "notification sent to <name> (<n> devices)"); HR / Admin only
create or replace function public.admin_push_device_count(p_user uuid)
returns integer
language plpgsql stable security definer set search_path = public as $$
begin
  perform public._require_admin();
  return (select count(*)::int from public.push_tokens where user_id = p_user);
end $$;
revoke all on function public.admin_push_device_count(uuid) from public, anon;
grant execute on function public.admin_push_device_count(uuid) to authenticated;

-- 5. triggers: leave ---------------------------------------------------------
create or replace function public._notify_leave_review() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  approver text;
  half     text := '';
  u        numeric := coalesce(new.units, new.days);
  approved boolean := (new.status = 'Approved');
begin
  if old.status = 'Pending' and new.status in ('Approved', 'Rejected') then
    begin
      select full_name into approver from public.profiles where id = coalesce(new.reviewed_by, auth.uid());
      if new.half_part is not null or u = 0.5 then half := ' (half day)'; end if;
      insert into public.notifications (user_id, kind, title, body, link, data)
      values (new.user_id,
              case when approved then 'LEAVE_APPROVED' else 'LEAVE_REJECTED' end,
              case when approved then '✅ Leave approved' else '❌ Leave rejected' end,
              'Your ' || new.leave_type || ' for ' || to_char(new.from_day, 'DD-MM-YYYY') || ' to ' || to_char(new.to_day, 'DD-MM-YYYY')
                || ' (' || u::text || case when u = 1 then ' day)' else ' days)' end || half
                || case when approved then ' was approved by ' else ' was rejected by ' end || coalesce(approver, 'Admin') || '.'
                || case when not approved and coalesce(trim(new.review_note), '') <> '' then ' ' || trim(new.review_note) else '' end,
              'MyLeave', jsonb_build_object('leave_id', new.id, 'link', 'MyLeave'));
    exception when others then
      raise warning 'notification not created for leave %: %', new.id, sqlerrm;   -- never fail the approval
    end;
  end if;
  return null;
end $$;
revoke all on function public._notify_leave_review() from public, anon, authenticated;

drop trigger if exists leaves_notify on public.leaves;
create trigger leaves_notify after update of status on public.leaves
  for each row execute function public._notify_leave_review();

-- triggers: regularization -------------------------------------------------------
create or replace function public._notify_reg_review() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  approver text;
  approved boolean := (new.status = 'Approved');
begin
  if old.status = 'Pending' and new.status in ('Approved', 'Rejected') then
    begin
      select full_name into approver from public.profiles where id = coalesce(new.reviewed_by, auth.uid());
      insert into public.notifications (user_id, kind, title, body, link, data)
      values (new.user_id,
              case when approved then 'REG_APPROVED' else 'REG_REJECTED' end,
              case when approved then '✅ Attendance correction approved' else '❌ Attendance correction rejected' end,
              'Your attendance correction for ' || to_char(new.day, 'DD-MM-YYYY') || ' (' || to_char(new.requested_in, 'HH12:MI AM') || ' to ' || to_char(new.requested_out, 'HH12:MI AM') || ')'
                || case when approved then ' was approved by ' else ' was rejected by ' end || coalesce(approver, 'Admin') || '.'
                || case when not approved and coalesce(trim(new.review_note), '') <> '' then ' ' || trim(new.review_note) else '' end,
              'Regularization', jsonb_build_object('regularization_id', new.id, 'link', 'Regularization'));
    exception when others then
      raise warning 'notification not created for regularization %: %', new.id, sqlerrm;
    end;
  end if;
  return null;
end $$;
revoke all on function public._notify_reg_review() from public, anon, authenticated;

drop trigger if exists regularizations_notify on public.regularizations;
create trigger regularizations_notify after update of status on public.regularizations
  for each row execute function public._notify_reg_review();

-- 6. realtime: the bell updates live -----------------------------------------------
do $$
begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'notifications') then
    alter publication supabase_realtime add table public.notifications;
  end if;
exception when others then
  raise notice 'Could not add notifications to supabase_realtime (add it in Database > Replication): %', sqlerrm;
end $$;

notify pgrst, 'reload schema';

-- CHECK after running:
--   select count(*) from public.notifications;      -- 0
--   select tgname from pg_trigger where tgname in ('leaves_notify', 'regularizations_notify');   -- 2 rows

-- =====================================================================
-- UNDO (rollback): commented out so it does NOT run with the file. To remove the feature, select the lines below (without the leading "-- "),
-- paste them in the SQL Editor on their own and Run. All notifications and phone tokens are lost.
-- Leave / regularization approvals themselves are NOT touched.
-- =====================================================================
-- drop trigger if exists leaves_notify          on public.leaves;
-- drop trigger if exists regularizations_notify on public.regularizations;
-- drop function if exists public._notify_leave_review();
-- drop function if exists public._notify_reg_review();
-- drop function if exists public.admin_push_device_count(uuid);
-- drop function if exists public.send_test_notification();
-- drop function if exists public.mark_notifications_read(bigint[]);
-- drop function if exists public.remove_push_token(text);
-- drop function if exists public.save_push_token(text, text, text);
-- do $$ begin alter publication supabase_realtime drop table public.notifications; exception when others then null; end $$;
-- drop table if exists public.notifications;
-- drop table if exists public.push_tokens;
-- notify pgrst, 'reload schema';
