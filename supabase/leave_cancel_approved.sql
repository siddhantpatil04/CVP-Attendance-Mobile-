-- =====================================================================
-- CANCEL AN APPROVED LEAVE: the employee REQUESTS, Admin / HR decides (ONE approval)
--
--   Pending leave ............ "Cancel request" (as before, cancel_leave(), no change)
--   Approved leave ........... "Request cancellation" + reason (request_leave_cancel)
--                              The leave STAYS Approved while the request waits: balance, attendance and salary do not change.
--                              (leaves.cancel_status = 'requested')
--   Admin / HR decides ....... review_leave_cancel(id, true)   -> status Cancelled, days returned to the same leave type
--                              review_leave_cancel(id, false)  -> "Keep leave": back to a normal Approved leave,
--                                                                 note "Cancellation not approved by <name>"
--   A leave touching a FINALIZED payroll month cannot be cancelled ("Cannot cancel - salary finalized").
--
-- Days returned = the "used" rows of leave_ledger are REVERSED by a new row of the same leave type (a negative "used" row).
-- Nothing in leave_ledger is deleted or edited. The per-day allocation (leave_day_alloc) of the leave is removed, so the Unpaid (LOP)
-- deduction of a month that is not finalized disappears by itself; attendance reads status = 'Approved', so it follows too.
-- Every request / approval / keep writes an Audit Trail entry and a notification (Admin / HR for a request, the employee for the answer).
--
-- Needs: leave_policy_24.sql + leave_rules_v3.sql + notifications.sql (+ payroll_months.sql for the finalized check).
-- Safe to run again, and safe if an earlier version of this file was already run.
-- BACK UP FIRST.   Supabase -> SQL Editor -> paste the WHOLE file -> Run.
-- Undo: the ROLLBACK block at the END of this file (commented out so it does not run with the file).
-- =====================================================================

-- 1. New columns on leaves ------------------------------------------------------------------------------------------------
alter table public.leaves add column if not exists cancel_status       text check (cancel_status is null or cancel_status in ('requested', 'approved', 'kept'));
alter table public.leaves add column if not exists cancel_reason       text;            -- why the employee asks to cancel
alter table public.leaves add column if not exists cancel_requested_at timestamptz;
alter table public.leaves add column if not exists cancel_reviewed_by  uuid references public.profiles(id) on delete set null;   -- Admin / HR who decided
alter table public.leaves add column if not exists cancel_reviewed_at  timestamptz;
alter table public.leaves add column if not exists cancel_review_note  text;            -- optional note of the decision
alter table public.leaves add column if not exists cancel_returned     numeric(6,2);    -- days given back to the balance

-- 1b. If an earlier version of this file was run (it used a status "Cancel requested"): move those leaves to the new form, drop its trigger
drop trigger if exists leaves_block_cancel_requested on public.leaves;
drop function if exists public._leaves_block_cancel_requested();
update public.leaves set status = 'Approved', cancel_status = 'requested' where status = 'Cancel requested';

-- 2. New notification kinds -----------------------------------------------------------------------------------------------
do $$
begin
  if to_regclass('public.notifications') is not null then
    alter table public.notifications drop constraint if exists notifications_kind_check;
    alter table public.notifications add constraint notifications_kind_check
      check (kind in ('LEAVE_APPROVED', 'LEAVE_REJECTED', 'REG_APPROVED', 'REG_REJECTED', 'TEST', 'SLIP_READY', 'SLIP_REMINDER', 'SLIP_QUERY', 'SLIP_ANSWER',
                      'LEAVE_CANCEL_REQUEST', 'LEAVE_CANCEL_APPROVED', 'LEAVE_CANCEL_KEPT', 'LEAVE_CANCELLED', 'LEAVE_CANCEL_REJECTED'));
  end if;
end $$;

-- 3. Helpers (not callable from the app) ----------------------------------------------------------------------------------
-- is any month of this leave finalized in payroll?
create or replace function public._lv_finalized(p_from date, p_to date) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare v boolean := false;
begin
  if to_regclass('public.payroll_months') is null then return false; end if;
  execute 'select exists (select 1 from public.payroll_months pm
                           where make_date(pm.year, pm.month, 1) between date_trunc(''month'', $1::timestamp)::date and date_trunc(''month'', $2::timestamp)::date)'
    into v using p_from, p_to;
  return coalesce(v, false);
end $$;
revoke execute on function public._lv_finalized(date, date) from public, anon, authenticated;

-- give the days of a leave back: reverse its "used" ledger rows (same type, same month), then drop the per-day allocation. Returns the days returned.
create or replace function public._lv_return_days(p_leave bigint, p_reason text, p_by uuid) returns numeric
language plpgsql security definer set search_path = public as $$
declare r public.leaves; x record; v_total numeric := 0;
begin
  select * into r from public.leaves where id = p_leave;
  for x in select g.leave_type, g.month, sum(g.used) as u
             from public.leave_ledger g
            where g.leave_id = p_leave and g.kind = 'used'
            group by g.leave_type, g.month
           having sum(g.used) > 0 loop
    perform public._lv_add(r.user_id, x.leave_type, x.month, 'used', -x.u, p_reason, p_leave, p_by);   -- negative "used" = the days come back
    v_total := v_total + x.u;
  end loop;
  delete from public.leave_day_alloc where leave_id = p_leave;       -- salary (Unpaid days) and half-day rules stop counting this leave
  return v_total;
end $$;
revoke execute on function public._lv_return_days(bigint, text, uuid) from public, anon, authenticated;

create or replace function public._lv_notify_admins(p_kind text, p_title text, p_body text, p_data jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  insert into public.notifications (user_id, kind, title, body, link, data)
  select p.id, p_kind, p_title, p_body, 'Approvals', p_data from public.profiles p where p.active and p.role in ('HR', 'Admin');
exception when others then
  raise warning 'leave cancel notification not created: %', sqlerrm;        -- never fail the request itself
end $$;
revoke execute on function public._lv_notify_admins(text, text, text, jsonb) from public, anon, authenticated;

create or replace function public._lv_notify_user(p_user uuid, p_kind text, p_title text, p_body text, p_data jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  insert into public.notifications (user_id, kind, title, body, link, data) values (p_user, p_kind, p_title, p_body, 'MyLeave', p_data);
exception when others then
  raise warning 'leave cancel notification not created: %', sqlerrm;
end $$;
revoke execute on function public._lv_notify_user(uuid, text, text, text, jsonb) from public, anon, authenticated;

-- 4. cancel_leave goes back to the original: Pending requests only (an approved leave uses request_leave_cancel) --------------
drop function if exists public.cancel_leave(bigint, text);
create or replace function public.cancel_leave(p_id bigint) returns public.leaves
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._require_active(); r public.leaves;
begin
  update public.leaves set status = 'Cancelled'
   where id = p_id and user_id = me.id and status = 'Pending'
  returning * into r;
  if r.id is null then raise exception 'Only your own pending requests can be cancelled'; end if;
  perform public._audit('CANCEL_LEAVE', p_id::text);
  return r;
end $$;
revoke all on function public.cancel_leave(bigint) from public, anon;
grant execute on function public.cancel_leave(bigint) to authenticated;

-- 5. request_leave_cancel: the employee asks; the leave stays Approved until Admin / HR decides --------------------------------
create or replace function public.request_leave_cancel(p_id bigint, p_reason text) returns public.leaves
language plpgsql security definer set search_path = public as $$
declare
  me     public.profiles := public._require_active();
  r      public.leaves;
  v_why  text := nullif(trim(coalesce(p_reason, '')), '');
  v_what text;
begin
  select * into r from public.leaves where id = p_id and user_id = me.id for update;
  if r.id is null then raise exception 'Only your own leave can be cancelled'; end if;
  if r.status <> 'Approved' then raise exception 'Only an approved leave needs a cancellation request (this one is %)', lower(r.status); end if;
  if r.cancel_status = 'requested' then raise exception 'Your cancellation request is already waiting for the Admin'; end if;
  if v_why is null then raise exception 'Enter a reason'; end if;
  if public._lv_finalized(r.from_day, r.to_day) then raise exception 'Cannot cancel - salary finalized'; end if;
  v_what := r.leave_type || ' ' || to_char(r.from_day, 'DD-MM-YYYY') || ' to ' || to_char(r.to_day, 'DD-MM-YYYY');

  update public.leaves
     set cancel_status = 'requested', cancel_reason = v_why, cancel_requested_at = now(),
         cancel_reviewed_by = null, cancel_reviewed_at = null, cancel_review_note = null, cancel_returned = null
   where id = p_id returning * into r;
  perform public._audit('REQUEST_LEAVE_CANCEL', p_id::text || ' ' || v_what || ' | ' || v_why);
  perform public._lv_notify_admins('LEAVE_CANCEL_REQUEST', 'Leave cancellation requested',
    me.full_name || ' asks to cancel ' || v_what || '. Reason: ' || v_why,
    jsonb_build_object('leave_id', r.id, 'link', 'Approvals'));
  return r;
end $$;

-- 6. review_leave_cancel: ONE approval (Admin or HR). p_approve = true -> Cancelled + days returned; false -> "Keep leave" ------------
create or replace function public.review_leave_cancel(p_id bigint, p_approve boolean, p_note text default null) returns public.leaves
language plpgsql security definer set search_path = public as $$
declare
  me     public.profiles := public._require_admin();
  r      public.leaves;
  v_note text := nullif(trim(coalesce(p_note, '')), '');
  v_ret  numeric;
  v_what text;
begin
  select * into r from public.leaves where id = p_id for update;
  if r.id is null then raise exception 'Leave request not found'; end if;
  if r.status <> 'Approved' or r.cancel_status is distinct from 'requested' then
    raise exception 'There is no cancellation request waiting for this leave (it may already be decided)';
  end if;
  v_what := r.leave_type || ' ' || to_char(r.from_day, 'DD-MM-YYYY') || ' to ' || to_char(r.to_day, 'DD-MM-YYYY');

  if p_approve then
    if public._lv_finalized(r.from_day, r.to_day) then raise exception 'Cannot cancel - salary finalized'; end if;
    v_ret := public._lv_return_days(r.id, 'Leave cancelled - days returned', me.id);
    update public.leaves
       set status = 'Cancelled', cancel_status = 'approved', cancel_returned = v_ret,
           cancel_reviewed_by = me.id, cancel_reviewed_at = now(), cancel_review_note = v_note
     where id = p_id returning * into r;
    perform public._audit('APPROVE_LEAVE_CANCEL', p_id::text || ' ' || v_what || ' by ' || me.role || ' | returned ' || v_ret::text);
    perform public._lv_notify_user(r.user_id, 'LEAVE_CANCEL_APPROVED', 'Leave cancelled',
      'Cancellation approved by ' || me.full_name || ' for your ' || v_what || '.'
        || case when v_ret > 0 then ' ' || v_ret::text || ' ' || r.leave_type || ' returned to your balance.' else '' end,
      jsonb_build_object('leave_id', r.id, 'link', 'MyLeave'));
  else
    update public.leaves
       set cancel_status = 'kept', cancel_reviewed_by = me.id, cancel_reviewed_at = now(), cancel_review_note = v_note
     where id = p_id returning * into r;
    perform public._audit('KEEP_LEAVE', p_id::text || ' ' || v_what || ' by ' || me.role || coalesce(' | ' || v_note, ''));
    perform public._lv_notify_user(r.user_id, 'LEAVE_CANCEL_KEPT', 'Cancellation not approved',
      'Cancellation not approved by ' || me.full_name || '. Your ' || v_what || ' stays approved.' || coalesce(' ' || v_note, ''),
      jsonb_build_object('leave_id', r.id, 'link', 'MyLeave'));
  end if;
  return r;
end $$;

-- 7. What My Requests needs for each leave of mine: which button -------------------------------------------------------------
--    mode: pending (Cancel request) | request (Request cancellation) | requested (waiting for Admin) | finalized (no button)
drop function if exists public.leave_cancel_options();
create or replace function public.leave_cancel_options()
returns table (leave_id bigint, mode text)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare me public.profiles := public._require_active();
begin
  return query
  select l.id,
         case when l.status = 'Pending' then 'pending'
              when l.cancel_status = 'requested' then 'requested'
              when public._lv_finalized(l.from_day, l.to_day) then 'finalized'
              else 'request' end
    from public.leaves l
   where l.user_id = me.id and l.status in ('Pending', 'Approved');
end $$;

-- 8. Permissions ---------------------------------------------------------------------------------------------------------
revoke all on function public.request_leave_cancel(bigint, text)            from public, anon;
revoke all on function public.review_leave_cancel(bigint, boolean, text)    from public, anon;
revoke all on function public.leave_cancel_options()                        from public, anon;
grant execute on function public.request_leave_cancel(bigint, text)         to authenticated;
grant execute on function public.review_leave_cancel(bigint, boolean, text) to authenticated;
grant execute on function public.leave_cancel_options()                     to authenticated;

notify pgrst, 'reload schema';

-- CHECK after running:
--   select proname from pg_proc where proname in ('request_leave_cancel', 'review_leave_cancel', 'leave_cancel_options');   -- 3 rows

-- =====================================================================
-- ROLLBACK (undo). Commented out so it does NOT run with the file. To undo: select ALL the lines below this heading,
-- remove the leading "-- " from each, paste them in the SQL Editor on their own and Run.
--   * the request / review / options functions and the helpers are removed; waiting requests are cleared (those leaves stay Approved)
--   * the notification kinds go back to the old list (cancel notifications are deleted)
-- NOT undone (on purpose): leaves ALREADY cancelled stay Cancelled and their days stay returned in leave_ledger (the reversal rows are
-- history; deleting them would change balances). The new columns on leaves stay (harmless); the lines that drop them are at the very end.
-- cancel_leave(bigint) is the same as before this feature, so it needs no undo.
-- =====================================================================
-- update public.leaves set cancel_status = null, cancel_reason = null, cancel_requested_at = null where cancel_status in ('requested', 'kept');
-- do $$
-- begin
--   if to_regclass('public.notifications') is not null then
--     delete from public.notifications where kind in ('LEAVE_CANCEL_REQUEST', 'LEAVE_CANCEL_APPROVED', 'LEAVE_CANCEL_KEPT', 'LEAVE_CANCELLED', 'LEAVE_CANCEL_REJECTED');
--     alter table public.notifications drop constraint if exists notifications_kind_check;
--     alter table public.notifications add constraint notifications_kind_check
--       check (kind in ('LEAVE_APPROVED', 'LEAVE_REJECTED', 'REG_APPROVED', 'REG_REJECTED', 'TEST', 'SLIP_READY', 'SLIP_REMINDER', 'SLIP_QUERY', 'SLIP_ANSWER'));
--   end if;
-- end $$;
-- drop function if exists public.leave_cancel_options();
-- drop function if exists public.review_leave_cancel(bigint, boolean, text);
-- drop function if exists public.request_leave_cancel(bigint, text);
-- drop function if exists public._lv_notify_user(uuid, text, text, text, jsonb);
-- drop function if exists public._lv_notify_admins(text, text, text, jsonb);
-- drop function if exists public._lv_return_days(bigint, text, uuid);
-- drop function if exists public._lv_finalized(date, date);
-- notify pgrst, 'reload schema';
--
-- -- Optional, only if you also want the new columns gone (the cancel reasons / dates are lost):
-- -- alter table public.leaves
-- --   drop column if exists cancel_status, drop column if exists cancel_reason, drop column if exists cancel_requested_at,
-- --   drop column if exists cancel_reviewed_by, drop column if exists cancel_reviewed_at, drop column if exists cancel_review_note,
-- --   drop column if exists cancel_returned;
