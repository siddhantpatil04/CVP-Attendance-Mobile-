-- =====================================================================
-- SITE SELFIE UPDATE: Daily Report only for site-access employees, and it must be submitted BEFORE check-out
--
-- ONE small, additive file.  Safe to run again (create or replace / if not exists).
-- No safety lock.  Does NOT drop tables and does NOT delete any data.
-- Do NOT edit or run cvp_attendance_schema.sql for this.
-- BACK UP THE DATABASE FIRST (Supabase -> Database -> Backups).  Publish the new app first, then run this.
-- Run in Supabase -> SQL Editor -> New query -> paste this WHOLE file -> Run.
--
-- Needs what you already have: the daily_reports tables and private._daily_visit_context (the Daily Report feature),
-- public._require_active / _require_admin / _audit, and the check-in / check-out functions.
--
-- RULES (enforced by the database, so an old app version or a direct API call cannot skip them)
--   1. Only employees with SITE ACCESS (Selfie / Site Employee = ON) can create a Daily Report.
--      Employees without site access (office employees) have no Daily Report and check in / out exactly as before.
--   2. A site-access employee who has checked in today (office point, project site or foreign location) cannot check out until today's (IST) Daily Report
--      is SUBMITTED. A saved Draft does NOT unlock check-out.
--      Message:  Please submit today's Daily Report before checking out.
--   3. Admin / HR "Allow once": one employee, one day, with a reason (saved in the audit log).
--   4. Check-out no longer waits for "Finish travel day". It depends only on: a check-in today + a submitted report.
--      Site-to-site travel stays in the Field Site section. Old travel / stop records are kept and stay visible to Admin.
-- =====================================================================

-- 1. Rule settings (one row) and Admin "Allow once" overrides --------------------------------
create table if not exists public.checkout_rule_settings (
  id              smallint primary key default 1 check (id = 1),
  report_required boolean not null default true,    -- the rule is ON
  draft_unlocks   boolean not null default false,   -- kept for the Admin screen; a Draft NEVER unlocks check-out any more
  updated_by      uuid references public.profiles(id) on delete set null,
  updated_at      timestamptz not null default now()
);
insert into public.checkout_rule_settings (id) values (1) on conflict (id) do nothing;
alter table public.checkout_rule_settings enable row level security;
drop policy if exists checkout_rule_read on public.checkout_rule_settings;
create policy checkout_rule_read on public.checkout_rule_settings for select to authenticated
  using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.role in ('Admin','HR')));

create table if not exists public.checkout_report_overrides (
  employee_id uuid not null references public.profiles(id) on delete cascade,
  work_date   date not null,
  reason      text not null check (length(trim(reason)) > 0),
  allowed_by  uuid references public.profiles(id) on delete set null,
  created_at  timestamptz not null default now(),
  primary key (employee_id, work_date)
);
alter table public.checkout_report_overrides enable row level security;
drop policy if exists checkout_override_read on public.checkout_report_overrides;
create policy checkout_override_read on public.checkout_report_overrides for select to authenticated
  using (employee_id = auth.uid()
         or exists (select 1 from public.profiles p where p.id = auth.uid() and p.role in ('Admin','HR')));
grant select on public.checkout_rule_settings, public.checkout_report_overrides to authenticated;

do $$
begin
  if not exists (select 1 from pg_publication_tables
                  where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'checkout_report_overrides') then
    alter publication supabase_realtime add table public.checkout_report_overrides;
  end if;
end $$;

-- 2. Only site-access employees can create a Daily Report; it can start right after CHECK-IN ---------
create or replace function private._daily_open_report(p_user uuid, p_report_id bigint) returns public.daily_reports
language plpgsql security definer set search_path = public as $$
declare r public.daily_reports; v_today date := public.ist_today();
begin
  if p_report_id is null then
    select * into r from public.daily_reports where user_id = p_user and report_date = v_today for update;
    if r.id is null then
      if not exists (select 1 from public.profiles where id = p_user and site_employee) then
        raise exception 'The Daily Report is only for employees with site access';
      end if;
      if not exists (select 1 from public.attendance a where a.user_id = p_user and a.work_date = v_today and a.check_in_at is not null) then
        raise exception 'Check in first, then fill the Daily Report';
      end if;
      insert into public.daily_reports (user_id, report_date) values (p_user, v_today)
      on conflict (user_id, report_date) do nothing;
      select * into r from public.daily_reports where user_id = p_user and report_date = v_today for update;
    end if;
  else
    select * into r from public.daily_reports where id = p_report_id and user_id = p_user for update;
    if r.id is null then raise exception 'Daily report not found'; end if;
  end if;
  if r.status not in ('Draft', 'Reopened') then
    raise exception 'This report is already % and can no longer be changed. Ask Admin / HR to reopen it', lower(r.status);
  end if;
  return r;
end $$;

-- the form needs to know whether the employee has checked in (it opens after check-in)
create or replace function private.daily_report_context() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me public.profiles := public._require_active(); v_today date := public.ist_today();
begin
  return private._daily_visit_context(me.id, v_today)
      || jsonb_build_object(
           'date', v_today,
           'checked_in', exists (select 1 from public.attendance a
                                  where a.user_id = me.id and a.work_date = v_today and a.check_in_at is not null),
           'checked_out', exists (select 1 from public.attendance a
                                   where a.user_id = me.id and a.work_date = v_today and a.check_out_at is not null));
end $$;

-- 3. THE RULE: no check-out without a SUBMITTED report (every site-access employee) ----
create or replace function public._enforce_report_before_checkout() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  cfg public.checkout_rule_settings;
begin
  -- only the employee's own check-out is checked; Admin edits, regularisation and server jobs (no signed-in user) are untouched
  if auth.uid() is null or auth.uid() <> new.user_id then return new; end if;
  -- the check-out is being made now (works for every check-out function, old or new app)
  if not (new.check_out_at is not null and old.check_out_at is null) then return new; end if;

  select * into cfg from public.checkout_rule_settings where id = 1;
  if cfg.report_required is not true then return new; end if;

  -- employees without site access never need a report
  if not exists (select 1 from public.profiles pr where pr.id = new.user_id and pr.site_employee) then return new; end if;
  -- today's (IST) report must be SUBMITTED (or reviewed). A Draft does not count.
  if exists (select 1 from public.daily_reports r
              where r.user_id = new.user_id and r.report_date = new.work_date and r.status in ('Submitted', 'Reviewed')) then
    return new;
  end if;

  -- Admin "Allow once"
  if exists (select 1 from public.checkout_report_overrides o
              where o.employee_id = new.user_id and o.work_date = new.work_date) then
    return new;
  end if;

  raise exception 'Please submit today''s Daily Report before checking out.';
end $$;
revoke all on function public._enforce_report_before_checkout() from public, anon, authenticated;

drop trigger if exists trg_report_before_checkout on public.attendance;
create trigger trg_report_before_checkout
  before update on public.attendance
  for each row execute function public._enforce_report_before_checkout();

-- 4. removed - travel check-in no longer used.
--    This section used to re-create public._travel_guard() (it blocked office employees that have Travel Access).
--    The guard is switched off for good by 9_working_hours_backend/00_remove_travel_checkin_block.sql.
-- create or replace function public._travel_guard() returns trigger
-- language plpgsql security definer set search_path = public as $$
-- declare p public.profiles;
-- begin
--   if auth.uid() is null or auth.uid() <> new.user_id then return new; end if;
--   if coalesce(current_setting('app.travel_rpc', true), '') = 'on' then return new; end if;
--   select * into p from public.profiles where id = new.user_id;
--   if p.travel_access and not coalesce(p.site_employee, false) then
--     if tg_op = 'INSERT' then
--       raise exception 'Travel employees must use the travel check-in';
--     elsif new.check_out_at is distinct from old.check_out_at then
--       raise exception 'Travel employees must use the travel check-out';
--     end if;
--   end if;
--   return new;
-- end $$;
-- revoke all on function public._travel_guard() from public, anon, authenticated;

-- 5. App functions ----------------------------------------------------------------------------------
-- Employee: is check-out locked today, and why
create or replace function public.checkout_report_status() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  me  public.profiles := public._require_active();
  cfg public.checkout_rule_settings;
  a   public.attendance;
  v_today date := public.ist_today();
  v_status text; v_override boolean; v_req boolean; v_ok boolean;
begin
  select * into cfg from public.checkout_rule_settings where id = 1;
  select * into a from public.attendance where user_id = me.id and work_date = v_today;
  -- the rule applies to every site-access employee once he has checked in today (whichever place he checked in at)
  v_req := coalesce(cfg.report_required, true) and coalesce(me.site_employee, false)
           and a.id is not null and a.check_in_at is not null;
  select r.status into v_status from public.daily_reports r where r.user_id = me.id and r.report_date = v_today;
  v_override := exists (select 1 from public.checkout_report_overrides o where o.employee_id = me.id and o.work_date = v_today);
  v_ok := v_status in ('Submitted', 'Reviewed');
  return jsonb_build_object(
    'date', v_today,
    'required', v_req,
    'report_status', v_status,
    'submitted_at', (select r.submitted_at from public.daily_reports r where r.user_id = me.id and r.report_date = v_today),
    'allowed_by_admin', v_override,
    'unlocked', not v_req or v_ok or v_override);
end $$;

-- Admin / HR: today's site-access employees and their report / check-out state
create or replace function public.admin_checkout_report_today(p_date date default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_day date := coalesce(p_date, public.ist_today()); out jsonb;
begin
  perform public._require_admin();
  select coalesce(jsonb_agg(x order by x->>'full_name'), '[]'::jsonb) into out
  from (
    select jsonb_build_object(
      'user_id', a.user_id, 'full_name', p.full_name, 'username', p.username,
      'site_name', coalesce((select s.site_name from public.selfie_records s where s.attendance_id = a.id and s.kind = 'IN' order by s.captured_at limit 1), a.site_name),
      'check_in_at', a.check_in_at, 'check_out_at', a.check_out_at,
      'report_status', r.status, 'report_submitted_at', r.submitted_at,
      'allowed_by_admin', o.employee_id is not null, 'override_reason', o.reason,
      'override_by', (select ap.full_name from public.profiles ap where ap.id = o.allowed_by), 'override_at', o.created_at
    ) as x
    from public.attendance a
    join public.profiles p on p.id = a.user_id
    left join public.daily_reports r on r.user_id = a.user_id and r.report_date = a.work_date
    left join public.checkout_report_overrides o on o.employee_id = a.user_id and o.work_date = a.work_date
    where a.work_date = v_day and a.check_in_at is not null
      and p.site_employee
  ) t;
  return out;
end $$;

-- Admin / HR: allow ONE employee to check out today without the report (reason + who + when are saved)
create or replace function public.admin_allow_checkout_once(p_user uuid, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._require_admin(); v_today date := public.ist_today(); emp public.profiles;
begin
  if nullif(trim(p_reason), '') is null then raise exception 'Enter the reason'; end if;
  select * into emp from public.profiles where id = p_user;
  if emp.id is null then raise exception 'Employee not found'; end if;
  insert into public.checkout_report_overrides (employee_id, work_date, reason, allowed_by)
  values (p_user, v_today, trim(p_reason), me.id)
  on conflict (employee_id, work_date) do update set reason = excluded.reason, allowed_by = excluded.allowed_by, created_at = now();
  perform public._audit('CHECKOUT_REPORT_ALLOWED', emp.username || ' ' || v_today || ': ' || trim(p_reason));
end $$;

-- Admin / HR: the rule ON / OFF (a Draft never unlocks check-out, so that part is always saved as OFF)
create or replace function public.admin_set_checkout_rule(p_required boolean, p_draft_unlocks boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._require_admin(); cfg public.checkout_rule_settings;
begin
  update public.checkout_rule_settings
     set report_required = coalesce(p_required, report_required), draft_unlocks = false,
         updated_by = me.id, updated_at = now()
   where id = 1 returning * into cfg;
  perform public._audit('CHECKOUT_RULE_CHANGED', 'report required: ' || cfg.report_required);
  return to_jsonb(cfg);
end $$;

revoke all on function public.checkout_report_status() from public, anon;
revoke all on function public.admin_checkout_report_today(date) from public, anon;
revoke all on function public.admin_allow_checkout_once(uuid, text) from public, anon;
revoke all on function public.admin_set_checkout_rule(boolean, boolean) from public, anon;
grant execute on function public.checkout_report_status() to authenticated;
grant execute on function public.admin_checkout_report_today(date) to authenticated;
grant execute on function public.admin_allow_checkout_once(uuid, text) to authenticated;
grant execute on function public.admin_set_checkout_rule(boolean, boolean) to authenticated;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------
-- UNDO (only if needed - select these lines and run them on their own; no data is touched):
-- drop trigger if exists trg_report_before_checkout on public.attendance;
-- update public.checkout_rule_settings set report_required = false where id = 1;
-- ---------------------------------------------------------------------
