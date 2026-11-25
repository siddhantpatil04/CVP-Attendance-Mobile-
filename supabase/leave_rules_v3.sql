-- =====================================================================
-- LEAVE RULES v3: 6 months eligibility, 2 paid leaves a month (EL + CL / EL + SL), saved leaves, 5 days notice for saved leaves,
--                 ONE approval (HR or Admin), whole days only, rules editable by Admin from a date.
--
-- Run AFTER leave_policy_24.sql (already run).  Do NOT re-run any older leave file.  Rollback: the commented block at the very end of this file
-- ONE additive file, safe to run again.  Nothing is deleted, no existing row is changed.
--
-- NOT changed on purpose:  attendance, check-in / out, working hours, admin_payroll (salary formula), _leave_eligible_from,
--   _lv_plan, _leave_usage.  OLD requests (policy_v2 = false) and the old half-day requests are counted and paid exactly as before.
--   Salary keeps using approved Unpaid (LOP) days (leave_day_alloc, bucket 'LOP') exactly as now.
--
-- PAID LEAVE = EARNED LEAVE ONLY (2 a month). Casual / Sick leave stay as request types but are UNPAID (LOP, salary deducted).
--
-- WHAT IS NEW
--   leave_rules ............ rule sets with an "apply from" date; get_leave_policy(date) returns the set valid on that date
--   admin_save_leave_rules .. Admin only; apply_from = 1st of a month, not in the past; Audit Trail old -> new
--   _leave_credit_from ...... date of the FIRST paid credit  = 1st of the month AFTER the eligibility months are completed
--   leave_buckets ........... per type: this_month / saved / total
--   leave_preview_v3, leave_check ... day chips (this month / saved / LOP) and the blocking message for the Apply screen
--   apply_leave ............. whole days, notice rules, saved-leave 5-day rule (replaced, same arguments)
--   review_leave ............ ONE approval by HR or Admin, final; role saved in leaves.reviewed_by_role (replaced)
--   _lv_credit_user / run_leave_jobs .. credit from leave_rules (whole days); 31 Dec lapse; safe to run twice (replaced)
--   leave_summary ........... same keys as before + 'buckets', 'rules', 'credit_from' (replaced)
--   Half Day - Personal work is switched OFF for new requests (active = false); nothing is deleted.
-- BACK UP THE DATABASE FIRST.  Supabase -> SQL Editor -> paste the WHOLE file -> Run.
-- =====================================================================

-- 1. Rule sets -------------------------------------------------------------------------------------------------------------------
create table if not exists public.leave_rules (
  id          bigint generated always as identity primary key,
  apply_from  date not null unique check (extract(day from apply_from) = 1),
  settings    jsonb not null,
  created_by  uuid references public.profiles(id) on delete set null,
  created_at  timestamptz not null default now()
);
alter table public.leave_rules enable row level security;
drop policy if exists leave_rules_read on public.leave_rules;
create policy leave_rules_read on public.leave_rules for select to authenticated using (true);
revoke all on public.leave_rules from anon;
revoke insert, update, delete on public.leave_rules from authenticated;
grant select on public.leave_rules to authenticated;

-- monthly = days credited in month 1..12 (array position = month).  ONLY Earned Leave is a paid leave (2 a month = 24 a year).
-- Casual / Sick leave are NOT paid: a request of those types is Unpaid (LOP, salary deducted); they get no credit (0).
insert into public.leave_rules (apply_from, settings) values (date '2000-01-01', $j$
{
  "eligibility_months": 6,
  "monthly": { "EL": [2,2,2,2,2,2,2,2,2,2,2,2], "CL": [0,0,0,0,0,0,0,0,0,0,0,0], "SL": [0,0,0,0,0,0,0,0,0,0,0,0] },
  "save_unused": true,
  "saved_notice_days": 5,
  "EL": { "notice_days": 7, "carry_next_year_max": 30, "encash": true },
  "CL": { "short_notice": true, "max_in_a_row": 3, "lapse_31_dec": true },
  "SL": { "same_day": true, "certificate_after_days": 2, "lapse_31_dec": true }
}$j$::jsonb)
on conflict (apply_from) do nothing;

-- who approved (HR / Admin) - the old rows stay empty, the app falls back to the reviewer's current role
alter table public.leaves add column if not exists reviewed_by_role text;

-- Half Day - Personal work: off for new requests (old requests keep working)
update public.leave_types set active = false where name = 'Half Day - Personal work';

-- 2. Reading the rules ------------------------------------------------------------------------------------------------------------
create or replace function public._lv_policy(p_date date default null) returns jsonb
language sql stable security definer set search_path = public as $$
  select settings from public.leave_rules where apply_from <= coalesce(p_date, public.ist_today()) order by apply_from desc limit 1
$$;
revoke execute on function public._lv_policy(date) from public, anon, authenticated;

create or replace function public.get_leave_policy(p_date date default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me public.profiles := public._require_active();
begin
  return public._lv_policy(p_date);
end $$;

-- 3. Saving the rules (Admin only) --------------------------------------------------------------------------------------------------
create or replace function public._lv_int(s jsonb, p text[], lo int, hi int, lbl text) returns int
language plpgsql immutable as $$
declare v jsonb := s #> p; n numeric;
begin
  if v is null or jsonb_typeof(v) <> 'number' then raise exception '% must be a number', lbl; end if;
  n := (v #>> '{}')::numeric;
  if n <> trunc(n) then raise exception '% must be a whole number', lbl; end if;
  if n < lo or n > hi then raise exception '% must be between % and %', lbl, lo, hi; end if;
  return n::int;
end $$;
create or replace function public._lv_bool(s jsonb, p text[], lbl text) returns boolean
language plpgsql immutable as $$
declare v jsonb := s #> p;
begin
  if v is null or jsonb_typeof(v) <> 'boolean' then raise exception '% must be ON or OFF', lbl; end if;
  return (v #>> '{}')::boolean;
end $$;
revoke execute on function public._lv_int(jsonb, text[], int, int, text) from public, anon, authenticated;
revoke execute on function public._lv_bool(jsonb, text[], text) from public, anon, authenticated;

create or replace function public.admin_save_leave_rules(p_apply_from date, p_settings jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me public.profiles := public._require_active();
  v_today date := public.ist_today();
  v_old jsonb; v_diff text := ''; k text; t text; i int; v_ignore int;
begin
  if me.role <> 'Admin' then raise exception 'Only an Admin can change the leave rules' using errcode = '42501'; end if;
  if p_apply_from is null or extract(day from p_apply_from) <> 1 then raise exception 'Apply from must be the 1st of a month'; end if;
  if p_apply_from < v_today then raise exception 'Apply from cannot be in the past'; end if;
  if p_settings is null or jsonb_typeof(p_settings) <> 'object' then raise exception 'Rules are missing'; end if;

  v_ignore := public._lv_int(p_settings, array['eligibility_months'], 1, 36, 'Paid leave starts after (months)');
  foreach t in array array['EL', 'CL', 'SL'] loop
    if jsonb_typeof(p_settings #> array['monthly', t]) <> 'array' or jsonb_array_length(p_settings #> array['monthly', t]) <> 12 then
      raise exception 'Monthly leaves of % need 12 months', t;
    end if;
    for i in 0..11 loop
      v_ignore := public._lv_int(p_settings, array['monthly', t, i::text], 0, 5, t || ' month ' || (i + 1));
    end loop;
  end loop;
  perform public._lv_bool(p_settings, array['save_unused'], 'Save unused leaves');
  v_ignore := public._lv_int(p_settings, array['saved_notice_days'], 0, 30, 'Saved leaves notice (days)');
  v_ignore := public._lv_int(p_settings, array['EL', 'notice_days'], 0, 30, 'EL notice (days)');
  v_ignore := public._lv_int(p_settings, array['EL', 'carry_next_year_max'], 0, 365, 'EL carry to next year (max)');
  perform public._lv_bool(p_settings, array['EL', 'encash'], 'EL encash');
  perform public._lv_bool(p_settings, array['CL', 'short_notice'], 'CL short notice');
  v_ignore := public._lv_int(p_settings, array['CL', 'max_in_a_row'], 1, 31, 'CL max days in a row');
  perform public._lv_bool(p_settings, array['CL', 'lapse_31_dec'], 'CL lapse 31 Dec');
  perform public._lv_bool(p_settings, array['SL', 'same_day'], 'SL same day');
  v_ignore := public._lv_int(p_settings, array['SL', 'certificate_after_days'], 0, 30, 'SL certificate after (days)');
  perform public._lv_bool(p_settings, array['SL', 'lapse_31_dec'], 'SL lapse 31 Dec');

  v_old := public._lv_policy(p_apply_from);
  for k in select jsonb_object_keys(p_settings) loop
    if (p_settings -> k) is distinct from (v_old -> k) then
      v_diff := v_diff || case when v_diff = '' then '' else ' | ' end || k || ': ' || coalesce((v_old -> k)::text, 'none') || ' -> ' || (p_settings -> k)::text;
    end if;
  end loop;
  if v_diff = '' then raise exception 'Nothing has changed'; end if;

  insert into public.leave_rules (apply_from, settings, created_by) values (p_apply_from, p_settings, me.id)
  on conflict (apply_from) do update set settings = excluded.settings, created_by = me.id, created_at = now();
  perform public._audit('LEAVE_RULES', 'apply from ' || to_char(p_apply_from, 'DD-MM-YYYY') || ' | ' || v_diff);
  return jsonb_build_object('apply_from', p_apply_from, 'settings', p_settings);
end $$;

-- 4. First paid credit date -------------------------------------------------------------------------------------------------------
-- RULE: the eligibility months must be COMPLETED; the first credit is on the 1st of the month AFTER that.
--   last day of the waiting period = joining date + N months - 1 day;  first credit = 1st of the month after that day.
--   joined 01-03-2026, 6 months -> last day 31-08-2026 -> first credit 01-09-2026
--   joined 01-09-2026, 6 months -> last day 28-02-2027 -> first credit 01-03-2027
--   joined 15-03-2026, 6 months -> last day 14-09-2026 -> first credit 01-10-2026
-- "Start paid leaves now" (paid_leave_early_from) still wins when it is earlier.
create or replace function public._leave_credit_from(p_user uuid) returns date
language sql stable security definer set search_path = public as $$
  select case when p.joining_date is null then p.paid_leave_early_from
              else least((date_trunc('month', ((p.joining_date + make_interval(months => (public._lv_policy(public.ist_today()) ->> 'eligibility_months')::int))::date - 1)::timestamp)
                          + interval '1 month')::date,
                         coalesce(p.paid_leave_early_from, date '9999-12-31')) end
    from public.profiles p where p.id = p_user
$$;
revoke execute on function public._leave_credit_from(uuid) from public, anon, authenticated;

-- 5. This month / saved / total ---------------------------------------------------------------------------------------------------
--   this month = credited on the 1st of the month of p_date (never more than the balance);  saved = the rest of the balance
create or replace function public._lv_buckets(p_user uuid, p_date date default null)
returns table (leave_type text, this_month numeric, saved numeric, total numeric)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare v_m date := date_trunc('month', coalesce(p_date, public.ist_today())::timestamp)::date;
begin
  return query
  select t.lt,
         least(b.tot, b.cm), b.tot - least(b.tot, b.cm), b.tot
    from (values ('Earned Leave'), ('Casual Leave'), ('Sick Leave')) t(lt)
   cross join lateral (
     select greatest(public._lv_bal(p_user, t.lt), 0) as tot,
            coalesce((select sum(l.credited) from public.leave_ledger l
                       where l.employee_id = p_user and l.leave_type = t.lt and l.month = v_m and l.kind = 'credit'), 0) as cm) b;
end $$;
revoke execute on function public._lv_buckets(uuid, date) from public, anon, authenticated;

create or replace function public.leave_buckets(p_user uuid default null, p_date date default null)
returns table (leave_type text, this_month numeric, saved numeric, total numeric)
language plpgsql stable security definer set search_path = public as $$
declare me public.profiles := public._require_active(); v_user uuid := coalesce(p_user, me.id);
begin
  if v_user <> me.id and me.role not in ('HR', 'Admin') then raise exception 'You can only view your own leave' using errcode = '42501'; end if;
  return query select * from public._lv_buckets(v_user, p_date);
end $$;

-- 6. Day plan of a request: working days only; each day uses THIS MONTH's leave first, then SAVED, else Unpaid (LOP) ----------------
create or replace function public._lv_dayplan(p_user uuid, p_type text, p_from date, p_to date)
returns table (day date, status text, bucket text, source text, units numeric)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare
  v_today date := public.ist_today(); v_credit date := public._leave_credit_from(p_user);
  v_paid boolean := p_type = 'Earned Leave';        -- Casual / Sick / Loss of Pay days are all Unpaid (LOP)
  v_code text := case p_type when 'Earned Leave' then 'EL' else 'LOP' end;
  tm numeric := 0; sv numeric := 0; d date;
begin
  if v_paid and v_credit is not null and v_credit <= v_today then
    select b.this_month, b.saved into tm, sv from public._lv_buckets(p_user, v_today) b where b.leave_type = p_type;
  end if;
  for d in select g::date from generate_series(p_from::timestamp, p_to::timestamp, interval '1 day') g loop
    if exists (select 1 from public._holiday_info(p_user, d)) then
      day := d; status := 'Holiday'; bucket := null; source := null; units := 0; return next; continue;
    elsif not public._is_workday(p_user, d) then
      day := d; status := 'Weekly off'; bucket := null; source := null; units := 0; return next; continue;
    end if;
    day := d; units := 1;
    if tm >= 1 then tm := tm - 1; status := 'Paid'; bucket := v_code; source := 'this_month';
    elsif sv >= 1 then sv := sv - 1; status := 'Paid'; bucket := v_code; source := 'saved';
    else status := 'Unpaid'; bucket := 'LOP'; source := 'lop'; end if;
    return next;
  end loop;
end $$;
revoke execute on function public._lv_dayplan(uuid, text, date, date) from public, anon, authenticated;

-- 7. All the apply rules in ONE place (the Apply screen and apply_leave use the same text). Returns null = allowed ------------------
create or replace function public._lv_validate(p_user uuid, p_type text, p_from date, p_to date, p_cert text default null) returns text
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare
  v_today date := public.ist_today(); pol jsonb := public._lv_policy(public.ist_today());
  st public.payroll_settings; v_credit date := public._leave_credit_from(p_user);
  v_paid boolean := p_type = 'Earned Leave';        -- the only paid leave
  v_units int; v_n int; v_first date; v_ok text;
begin
  select * into st from public.payroll_settings where id = 1;
  if p_type not in ('Earned Leave', 'Casual Leave', 'Sick Leave', 'Loss of Pay') then return 'Choose Earned, Casual, Sick or Unpaid (LOP) leave'; end if;
  select count(*) into v_units from public._lv_dayplan(p_user, p_type, p_from, p_to) x where x.bucket is not null;
  if v_units = 0 then return 'No working days in the selected period (weekly off / holiday only)'; end if;

  if v_paid and (v_credit is null or v_credit > v_today) then
    return case when v_credit is null then 'Paid leave has not started for you yet. Only Unpaid (LOP) leave can be applied.'
           else format('Paid leave starts on %s (after %s months). Until then only Unpaid (LOP) leave can be applied.',
                       to_char(v_credit, 'DD-MM-YYYY'), pol ->> 'eligibility_months') end;
  end if;

  if p_type = 'Sick Leave' then
    if p_from < v_today - st.leave_sl_apply_within then return format('Sick Leave can be applied up to %s days after the leave', st.leave_sl_apply_within); end if;
    if not coalesce((pol #>> '{SL,same_day}')::boolean, true) and p_from <= v_today then return 'Sick Leave must be applied before the leave date'; end if;
  elsif p_from < v_today then
    return 'Choose today or a later date';
  end if;

  if p_type = 'Earned Leave' then
    v_n := (pol #>> '{EL,notice_days}')::int;
    if p_from < v_today + v_n then
      return format('Earned Leave must be applied %s days before. Choose %s or later.', v_n, to_char(v_today + v_n, 'DD-MM-YYYY'));
    end if;
  elsif p_type = 'Casual Leave' then
    if not coalesce((pol #>> '{CL,short_notice}')::boolean, true) and p_from <= v_today then
      return 'Casual Leave must be applied before the leave date';
    end if;
    v_n := (pol #>> '{CL,max_in_a_row}')::int;
    if v_units > v_n then return format('Casual Leave: maximum %s days in a row.', v_n); end if;
  elsif p_type = 'Sick Leave' then
    v_n := (pol #>> '{SL,certificate_after_days}')::int;
    if v_units > v_n and (p_cert is null or split_part(p_cert, '/', 1) <> p_user::text) then
      return format('Upload the medical certificate (Sick Leave of more than %s days).', v_n);
    end if;
  end if;

  if v_paid then
    v_n := (pol ->> 'saved_notice_days')::int;
    select min(x.day) into v_first from public._lv_dayplan(p_user, p_type, p_from, p_to) x where x.source = 'saved' and x.day < v_today + v_n;
    if v_first is not null then
      select string_agg(to_char(x.day, 'DD-MM-YYYY'), ', ' order by x.day) into v_ok
        from public._lv_dayplan(p_user, p_type, p_from, p_to) x where x.source = 'this_month';
      return format('%s uses a saved leave. Saved leaves must be applied %s days before. Choose dates from %s or later%s.',
                    to_char(v_first, 'DD-MM-YYYY'), v_n, to_char(v_today + v_n, 'DD-MM-YYYY'),
                    case when v_ok is null then '' else ', or take only ' || v_ok || ' (this month''s leave)' end);
    end if;
  end if;
  return null;
end $$;
revoke execute on function public._lv_validate(uuid, text, date, date, text) from public, anon, authenticated;

create or replace function public.leave_check(p_type text, p_from date, p_to date, p_certificate text default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare me public.profiles := public._require_active();
begin
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 370 then return jsonb_build_object('error', 'Check the dates', 'units', 0, 'lop', 0); end if;
  return jsonb_build_object(
    'error', public._lv_validate(me.id, p_type, p_from, p_to, p_certificate),
    'units', (select count(*) from public._lv_dayplan(me.id, p_type, p_from, p_to) x where x.bucket is not null),
    'lop',   (select count(*) from public._lv_dayplan(me.id, p_type, p_from, p_to) x where x.bucket = 'LOP'));
end $$;

create or replace function public.leave_preview_v3(p_type text, p_from date, p_to date, p_user uuid default null)
returns table (day date, status text, bucket text, source text, units numeric, per_day numeric)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare me public.profiles := public._require_active(); v_user uuid := coalesce(p_user, me.id);
begin
  if p_user is not null and p_user <> me.id and me.role not in ('HR', 'Admin') then
    raise exception 'You can only preview your own leave' using errcode = '42501';
  end if;
  if p_to < p_from or p_to - p_from > 370 then return; end if;
  return query
  select p.day, p.status, p.bucket, p.source, p.units,
         round(coalesce(public._salary_on(v_user, p.day), 0) /
               extract(day from (date_trunc('month', p.day::timestamp) + interval '1 month - 1 day'))::numeric, 2)
    from public._lv_dayplan(v_user, p_type, p_from, p_to) p
   order by p.day;
end $$;

-- 8. Apply for leave (same arguments as before; a half day is refused) -----------------------------------------------------------------
create or replace function public.apply_leave(p_leave_type text, p_from date, p_to date, p_reason text,
                                              p_half text default null, p_personal text default null, p_certificate text default null)
returns public.leaves
language plpgsql security definer set search_path = public as $$
declare
  me     public.profiles := public._require_active();
  t      public.leave_types;
  v_units int; v_err text;
  r      public.leaves;
begin
  if p_half is not null or p_personal is not null then raise exception 'Half day leave is not available. Apply for whole days.'; end if;
  select * into t from public.leave_types where name = p_leave_type and active and name in ('Earned Leave', 'Casual Leave', 'Sick Leave', 'Loss of Pay');
  if t.name is null then raise exception 'Choose Earned, Casual, Sick or Unpaid (LOP) leave'; end if;
  if p_to < p_from then raise exception 'End date cannot be before start date'; end if;
  if nullif(trim(coalesce(p_reason, '')), '') is null then raise exception 'Enter a reason'; end if;
  if extract(year from p_from) <> extract(year from p_to) then raise exception 'The dates are in two calendar years. Apply as two requests'; end if;

  v_err := public._lv_validate(me.id, t.name, p_from, p_to, p_certificate);
  if v_err is not null then raise exception '%', v_err; end if;
  select count(*) into v_units from public._lv_dayplan(me.id, t.name, p_from, p_to) x where x.bucket is not null;

  if exists (select 1 from public.leaves l where l.user_id = me.id and l.status in ('Pending', 'Approved') and l.from_day <= p_to and l.to_day >= p_from) then
    raise exception 'These dates overlap with another leave request';
  end if;

  insert into public.leaves (user_id, leave_type, from_day, to_day, days, reason, policy_v2, units, certificate_path)
  values (me.id, t.name, p_from, p_to, v_units, trim(p_reason), true, v_units, nullif(trim(coalesce(p_certificate, '')), ''))
  returning * into r;
  perform public._audit('LEAVE_REQUEST', t.name || ' ' || p_from || ' to ' || p_to);
  return r;
end $$;

-- 9. ONE approval: HR or Admin approves / rejects, the decision is final; the balance is used on approval ------------------------------
create or replace function public.review_leave(p_id bigint, p_approve boolean, p_note text default null)
returns public.leaves
language plpgsql security definer set search_path = public as $$
declare
  me    public.profiles := public._require_admin();
  r     public.leaves;
  t     public.leave_types;
  v_bal int;
  v_elig date;
  v_units numeric;
  x     record;
  v_who text;
begin
  select * into r from public.leaves where id = p_id for update;
  if r.id is null then raise exception 'Leave request not found'; end if;
  if r.status <> 'Pending' then
    select coalesce(r.reviewed_by_role, pr.role) || ' (' || pr.full_name || ')' into v_who from public.profiles pr where pr.id = r.reviewed_by;
    raise exception 'This request is already % by %', lower(r.status), coalesce(v_who, 'another reviewer');
  end if;

  if p_approve and r.policy_v2 and r.half_part is null and r.leave_type in ('Casual Leave', 'Sick Leave', 'Loss of Pay') then
    -- Casual / Sick / Unpaid are not paid leaves: every working day is Unpaid (LOP)
    insert into public.leave_day_alloc (leave_id, user_id, day, bucket, units)
    select r.id, r.user_id, d.day, 'LOP', 1 from public._lv_dayplan(r.user_id, r.leave_type, r.from_day, r.to_day) d where d.bucket is not null
    on conflict (leave_id, day, bucket) do nothing;
    select count(*) into v_units from public.leave_day_alloc a where a.leave_id = r.id;
    if v_units = 0 then raise exception 'This request has no working days (weekly off / holiday only)'; end if;
    update public.leaves set units = v_units, days = greatest(1, ceil(v_units))::int where id = r.id;
  elsif p_approve and r.policy_v2 then
    select coalesce(sum(pl.units), 0) into v_units from public._lv_plan(r.user_id, r.leave_type, r.from_day, r.to_day, r.half_part) pl where pl.bucket is not null;
    if v_units = 0 then raise exception 'This request has no working days (weekly off / holiday only)'; end if;
    for x in select pl.day, pl.bucket, pl.units from public._lv_plan(r.user_id, r.leave_type, r.from_day, r.to_day, r.half_part) pl where pl.bucket is not null loop
      insert into public.leave_day_alloc (leave_id, user_id, day, bucket, units, half_part)
      values (r.id, r.user_id, x.day, x.bucket, x.units, r.half_part)
      on conflict (leave_id, day, bucket) do nothing;
    end loop;
    for x in select a.bucket, sum(a.units) as u from public.leave_day_alloc a where a.leave_id = r.id and a.bucket <> 'LOP' group by a.bucket loop
      perform public._lv_add(r.user_id, case x.bucket when 'EL' then 'Earned Leave' when 'CL' then 'Casual Leave' else 'Sick Leave' end,
                             r.from_day, 'used', x.u, r.leave_type, r.id, me.id);
    end loop;
    update public.leaves set units = v_units, days = greatest(1, ceil(v_units))::int where id = r.id;
  elsif p_approve then
    -- OLD requests (before the 24-day policy): exactly the previous rule
    v_elig := public._leave_eligible_from(r.user_id);
    select coalesce(sum(u.days), 0)::int into r.days
      from public._leave_usage(r.user_id, r.from_day - 10, r.to_day + 10, array['Approved'], r.from_day, r.to_day, r.id) u
     where u.leave_type = 'NEW';
    if r.days = 0 then raise exception 'This request has no working days (weekly off / holiday only)'; end if;
    update public.leaves set days = r.days where id = r.id;
    select * into t from public.leave_types where name = r.leave_type;
    if t.counts_balance and (v_elig is null or r.from_day >= v_elig) then
      select b.balance into v_bal from public._leave_balance(r.user_id, extract(year from r.from_day)::int) b where b.leave_type = r.leave_type;
      if r.days > coalesce(v_bal, 0) then
        raise exception 'Insufficient balance: cannot approve (% day(s) available)', coalesce(v_bal, 0);
      end if;
    end if;
  end if;

  update public.leaves
     set status = case when p_approve then 'Approved' else 'Rejected' end,
         reviewed_by = me.id, reviewed_by_role = me.role, reviewed_at = now(), review_note = nullif(trim(p_note), '')
   where id = p_id and status = 'Pending'
  returning * into r;
  perform public._audit(case when p_approve then 'APPROVE_LEAVE' else 'REJECT_LEAVE' end, p_id::text || ' by ' || me.role);
  return r;
end $$;

-- 10. Monthly credit + lapse (whole days, from leave_rules; safe to run twice) ----------------------------------------------------------
create or replace function public._lv_credit_user(p_user uuid, p_asof date) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_credit date := public._leave_credit_from(p_user);
  v_month date := date_trunc('month', p_asof::timestamp)::date;
  pol jsonb := public._lv_policy(v_month);
  k text; code text; amt int;
begin
  if v_credit is null or v_credit > p_asof then return; end if;
  foreach k in array array['Earned Leave', 'Casual Leave', 'Sick Leave'] loop
    code := case k when 'Earned Leave' then 'EL' when 'Casual Leave' then 'CL' else 'SL' end;
    amt := coalesce((pol #>> array['monthly', code, (extract(month from v_month)::int - 1)::text])::int, 0);
    if amt <= 0 then continue; end if;
    if exists (select 1 from public.leave_ledger where employee_id = p_user and leave_type = k and month = v_month and kind = 'credit') then continue; end if;
    perform public._lv_add(p_user, k, v_month, 'credit', amt, 'Monthly credit');
  end loop;
end $$;

-- On the 1st of a month (before the new credit):
--   * "Save unused leaves" OFF  -> everything left from the month that ended lapses
--   * the month that ended is December (31 Dec) -> CL / SL lapse (if their switch is ON); EL above the carry limit lapses
-- One lapse row per employee / type / month: running twice never lapses twice.
create or replace function public.run_leave_jobs(p_asof date default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_day date := coalesce(p_asof, public.ist_today()); v_prev date := coalesce(p_asof, public.ist_today()) - 1;
  v_pol_prev jsonb; v_save boolean; v_ye boolean; v_lapse numeric;
  p record; k text; v_bal numeric; n_cred int := 0; n_lapse int := 0;
begin
  if auth.uid() is not null then perform public._require_full_admin(); end if;      -- cron has no signed-in user
  perform pg_advisory_xact_lock(hashtext('leave_jobs'));

  if extract(day from v_day) = 1 then
    v_pol_prev := public._lv_policy(v_prev);
    v_save := coalesce((public._lv_policy(v_day) ->> 'save_unused')::boolean, true);
    v_ye := extract(month from v_prev) = 12 and extract(day from v_prev) = 31;
    if (not v_save) or v_ye then
      for p in select id from public.profiles loop
        foreach k in array array['Earned Leave', 'Casual Leave', 'Sick Leave'] loop
          v_bal := public._lv_bal(p.id, k);
          continue when v_bal <= 0;
          v_lapse := case
            when not v_save then v_bal
            when k = 'Earned Leave' then greatest(0, v_bal - coalesce((v_pol_prev #>> '{EL,carry_next_year_max}')::numeric, 30))
            when k = 'Casual Leave' and coalesce((v_pol_prev #>> '{CL,lapse_31_dec}')::boolean, true) then v_bal
            when k = 'Sick Leave'   and coalesce((v_pol_prev #>> '{SL,lapse_31_dec}')::boolean, true) then v_bal
            else 0 end;
          if v_lapse > 0 and not exists (select 1 from public.leave_ledger where employee_id = p.id and leave_type = k and kind = 'lapse'
                                          and month = date_trunc('month', v_prev::timestamp)::date) then
            perform public._lv_add(p.id, k, v_prev, 'lapse', v_lapse, case when v_ye then 'Lapsed at year end' else 'Not saved to the next month' end);
            n_lapse := n_lapse + 1;
          end if;
        end loop;
      end loop;
    end if;
  end if;

  for p in select id from public.profiles where active loop
    perform public._lv_credit_user(p.id, v_day);
  end loop;
  select count(*) into n_cred from public.leave_ledger where kind = 'credit' and month = date_trunc('month', v_day::timestamp)::date;
  return jsonb_build_object('credited_rows_this_month', n_cred, 'lapsed_now', n_lapse, 'as_of', v_day);
end $$;

-- 11. What the screens read (all the old keys stay; 'buckets', 'rules', 'credit_from' are new) --------------------------------------------
create or replace function public.leave_summary(p_user uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  me public.profiles := public._require_active(); v_user uuid := coalesce(p_user, me.id);
  emp public.profiles; v_today date := public.ist_today(); pol jsonb := public._lv_policy(public.ist_today());
  v_credit date; v_m date := date_trunc('month', public.ist_today()::timestamp)::date; v_y int := extract(year from public.ist_today())::int;
  v_el numeric; v_cl numeric; v_sl numeric; c_el numeric; c_cl numeric; c_sl numeric; v_done int;
begin
  if v_user <> me.id and me.role not in ('HR', 'Admin') then raise exception 'You can only view your own leave' using errcode = '42501'; end if;
  select * into emp from public.profiles where id = v_user;
  v_credit := public._leave_credit_from(v_user);
  v_el := public._lv_bal(v_user, 'Earned Leave'); v_cl := public._lv_bal(v_user, 'Casual Leave'); v_sl := public._lv_bal(v_user, 'Sick Leave');
  select coalesce(sum(credited), 0) into c_el from public.leave_ledger where employee_id = v_user and leave_type = 'Earned Leave' and month = v_m and kind = 'credit';
  select coalesce(sum(credited), 0) into c_cl from public.leave_ledger where employee_id = v_user and leave_type = 'Casual Leave' and month = v_m and kind = 'credit';
  select coalesce(sum(credited), 0) into c_sl from public.leave_ledger where employee_id = v_user and leave_type = 'Sick Leave' and month = v_m and kind = 'credit';
  v_done := case when emp.joining_date is null then null
                 else greatest(0, (extract(year from age(v_today, emp.joining_date)) * 12 + extract(month from age(v_today, emp.joining_date)))::int) end;
  return jsonb_build_object(
    'joining_date', emp.joining_date, 'eligible_from', v_credit, 'credit_from', v_credit, 'eligible', (v_credit is not null and v_credit <= v_today),
    'months_done', v_done, 'months_total', (pol ->> 'eligibility_months')::int, 'days_left', case when v_credit is null then null else greatest(0, v_credit - v_today) end,
    'early_start', emp.paid_leave_early_from is not null, 'early_reason', emp.paid_leave_early_reason,
    'el', jsonb_build_object('balance', v_el, 'cap', (pol #>> '{EL,carry_next_year_max}')::numeric,
            'yearly', (select coalesce(sum(e::int), 0) from jsonb_array_elements_text(pol #> '{monthly,EL}') e), 'added_this_month', c_el, 'saved_before', greatest(v_el - c_el, 0)),
    'cl', jsonb_build_object('balance', v_cl, 'yearly', (select coalesce(sum(e::int), 0) from jsonb_array_elements_text(pol #> '{monthly,CL}') e), 'added_this_month', c_cl,
            'used_year', (select coalesce(sum(used), 0) from public.leave_ledger where employee_id = v_user and leave_type = 'Casual Leave' and extract(year from month) = v_y)),
    'sl', jsonb_build_object('balance', v_sl, 'yearly', (select coalesce(sum(e::int), 0) from jsonb_array_elements_text(pol #> '{monthly,SL}') e), 'added_this_month', c_sl,
            'used_year', (select coalesce(sum(used), 0) from public.leave_ledger where employee_id = v_user and leave_type = 'Sick Leave' and extract(year from month) = v_y)),
    'lop_year', (select coalesce(sum(a.units), 0) from public.leave_day_alloc a where a.user_id = v_user and a.bucket = 'LOP' and extract(year from a.day) = v_y),
    'paid_available', v_el,
    'buckets', (select jsonb_object_agg(case b.leave_type when 'Earned Leave' then 'EL' when 'Casual Leave' then 'CL' else 'SL' end,
                                        jsonb_build_object('this_month', b.this_month, 'saved', b.saved, 'total', b.total))
                  from public._lv_buckets(v_user, v_today) b),
    'rules', pol,
    'policy', public.get_leave_policy2());
end $$;

-- 12. Permissions -------------------------------------------------------------------------------------------------------------------------
revoke all on function public.get_leave_policy(date)                                   from public, anon;
revoke all on function public.admin_save_leave_rules(date, jsonb)                      from public, anon;
revoke all on function public.leave_buckets(uuid, date)                                from public, anon;
revoke all on function public.leave_check(text, date, date, text)                      from public, anon;
revoke all on function public.leave_preview_v3(text, date, date, uuid)                 from public, anon;
revoke all on function public.apply_leave(text, date, date, text, text, text, text)    from public, anon;
revoke all on function public.review_leave(bigint, boolean, text)                      from public, anon;
revoke all on function public.run_leave_jobs(date)                                     from public, anon;
revoke all on function public.leave_summary(uuid)                                      from public, anon;
grant execute on function public.get_leave_policy(date)                                to authenticated;
grant execute on function public.admin_save_leave_rules(date, jsonb)                   to authenticated;
grant execute on function public.leave_buckets(uuid, date)                             to authenticated;
grant execute on function public.leave_check(text, date, date, text)                   to authenticated;
grant execute on function public.leave_preview_v3(text, date, date, uuid)              to authenticated;
grant execute on function public.apply_leave(text, date, date, text, text, text, text) to authenticated;
grant execute on function public.review_leave(bigint, boolean, text)                   to authenticated;
grant execute on function public.run_leave_jobs(date)                                  to authenticated;
grant execute on function public.leave_summary(uuid)                                   to authenticated;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------
-- READ-ONLY CHECKS (nothing below runs by itself) - existing balances with 0.5 are NOT changed; YOU decide:
--
-- select p.full_name, p.username, l.leave_type,
--        sum(l.credited + l.adjusted - l.used - l.lapsed - l.encashed) as balance
--   from public.leave_ledger l join public.profiles p on p.id = l.employee_id
--  group by p.full_name, p.username, l.leave_type
-- having sum(l.credited + l.adjusted - l.used - l.lapsed - l.encashed) <> trunc(sum(l.credited + l.adjusted - l.used - l.lapsed - l.encashed))
--  order by p.full_name, l.leave_type;
--
-- -- AFTER you decide (one employee / one type at a time): round a .5 balance UP to the next whole day with one "adjust" row.
-- -- (run in the SQL Editor; replace the uuid, the type and the amount, e.g. balance 0.5 -> +0.5, balance 2.5 -> +0.5)
-- select public._lv_add('<employee uuid>'::uuid, 'Casual Leave', public.ist_today(), 'adjust', 0.5, 'Rounded to whole day', null, null);
--
-- -- half-day requests still waiting (they are still approved by the old half-day logic):
-- select l.id, p.full_name, l.leave_type, l.from_day, l.half_part, l.status
--   from public.leaves l join public.profiles p on p.id = l.user_id where l.half_part is not null and l.status = 'Pending';
-- ---------------------------------------------------------------------


-- =====================================================================
-- ROLLBACK (undo of this file). It is COMMENTED OUT so it never runs by accident.
-- To undo: select all the lines below, remove the leading "-- " (VS Code: Ctrl+/), paste in the Supabase SQL Editor, Run.
-- Restores the old apply_leave / review_leave / _lv_credit_user / run_leave_jobs / leave_summary and removes the new objects.
-- Nothing is deleted from the ledger or the leave requests (the saved rule sets table leave_rules IS dropped).
-- =====================================================================
-- create or replace function public.apply_leave(p_leave_type text, p_from date, p_to date, p_reason text,
--                                               p_half text default null, p_personal text default null, p_certificate text default null)
-- returns public.leaves
-- language plpgsql security definer set search_path = public as $$
-- declare
--   me     public.profiles := public._require_active();
--   st     public.payroll_settings;
--   t      public.leave_types;
--   v_today date := public.ist_today();
--   v_units numeric := 0;
--   v_half  boolean := p_half is not null;
--   v_pm    numeric;
--   r      public.leaves;
-- begin
--   select * into st from public.payroll_settings where id = 1;
--   select * into t from public.leave_types
--    where name = p_leave_type and active and name in ('Earned Leave', 'Casual Leave', 'Sick Leave', 'Loss of Pay', 'Half Day - Personal work');
--   if t.name is null then raise exception 'Choose Earned, Casual, Sick, Unpaid or Half Day - Personal work'; end if;
--   if p_to < p_from then raise exception 'End date cannot be before start date'; end if;
--   if nullif(trim(p_reason), '') is null then raise exception 'Enter a reason'; end if;
--   if extract(year from p_from) <> extract(year from p_to) then raise exception 'The dates are in two calendar years. Apply as two requests'; end if;
--
--   if t.name = 'Half Day - Personal work' and not v_half then raise exception 'Choose which half: morning or afternoon'; end if;
--   if v_half and p_half not in ('first', 'second') then raise exception 'Choose which half: morning or afternoon'; end if;
--   if v_half and p_from <> p_to then raise exception 'A half day is for one date'; end if;
--   if t.name = 'Half Day - Personal work' and coalesce(p_personal, '') not in ('Bank / office', 'Family', 'Doctor', 'Other') then
--     raise exception 'Choose the personal work: Bank / office, Family, Doctor or Other';
--   end if;
--
--   -- notice rules
--   if t.name = 'Earned Leave' and p_from < v_today + st.leave_el_notice_days then
--     raise exception 'Earned Leave needs % days notice. Choose later dates, or use Casual Leave.', st.leave_el_notice_days;
--   elsif t.name = 'Sick Leave' and p_from < v_today - st.leave_sl_apply_within then
--     raise exception 'Sick Leave can be applied up to % days after the leave', st.leave_sl_apply_within;
--   elsif t.name not in ('Earned Leave', 'Sick Leave') and p_from < v_today then
--     raise exception 'Choose today or a later date';
--   end if;
--
--   -- units = working days (a weekly off / holiday is not leave); a half day = 0.5
--   select coalesce(sum(x.units), 0) into v_units
--     from public._lv_plan(me.id, t.name, p_from, p_to, p_half) x where x.bucket is not null;
--   if v_units = 0 then raise exception 'No working days in the selected period (weekly off / holiday only)'; end if;
--
--   if t.name = 'Casual Leave' and v_units > st.leave_cl_max_request then
--     raise exception 'Casual Leave: maximum % days at a time.', st.leave_cl_max_request;
--   end if;
--   if t.name = 'Sick Leave' and v_units > st.leave_sl_cert_after
--      and (p_certificate is null or split_part(p_certificate, '/', 1) <> me.id::text) then
--     raise exception 'Upload the medical certificate (Sick Leave of more than % days).', st.leave_sl_cert_after;
--   end if;
--   if t.name = 'Half Day - Personal work' and st.leave_personal_max_month is not null then
--     select coalesce(sum(l.units), 0) into v_pm from public.leaves l
--      where l.user_id = me.id and l.leave_type = 'Half Day - Personal work' and l.status in ('Pending', 'Approved')
--        and date_trunc('month', l.from_day::timestamp) = date_trunc('month', p_from::timestamp);
--     if (v_pm + 0.5) > st.leave_personal_max_month * 0.5 then
--       raise exception 'Only % personal half day(s) a month', st.leave_personal_max_month;
--     end if;
--   end if;
--
--   -- overlap: two different halves of the same date are allowed; anything else on the same dates is not
--   if exists (select 1 from public.leaves l
--               where l.user_id = me.id and l.status in ('Pending', 'Approved') and l.from_day <= p_to and l.to_day >= p_from
--                 and not (v_half and l.half_part is not null and l.half_part <> p_half)) then
--     raise exception 'These dates overlap with another leave request';
--   end if;
--
--   insert into public.leaves (user_id, leave_type, from_day, to_day, days, reason, policy_v2, units, half_part, personal_work, certificate_path)
--   values (me.id, t.name, p_from, p_to, greatest(1, ceil(v_units))::int, trim(p_reason), true, v_units,
--           p_half, case when t.name = 'Half Day - Personal work' then p_personal end, nullif(trim(coalesce(p_certificate, '')), ''))
--   returning * into r;
--   perform public._audit('LEAVE_REQUEST', t.name || ' ' || p_from || ' to ' || p_to || case when v_half then ' (' || p_half || ' half)' else '' end);
--   return r;
-- end $$;
--
-- create or replace function public.review_leave(p_id bigint, p_approve boolean, p_note text default null)
-- returns public.leaves
-- language plpgsql security definer set search_path = public as $$
-- declare
--   me    public.profiles := public._require_admin();
--   r     public.leaves;
--   t     public.leave_types;
--   v_bal int;
--   v_elig date;
--   v_units numeric;
--   x     record;
-- begin
--   select * into r from public.leaves where id = p_id for update;
--   if r.id is null then raise exception 'Leave request not found'; end if;
--   if r.status <> 'Pending' then raise exception 'This request is already %', lower(r.status); end if;
--
--   if p_approve and r.policy_v2 then
--     -- NEW policy: allocate every day to EL / CL / SL / Unpaid against the balances of today, then deduct
--     select coalesce(sum(pl.units), 0) into v_units from public._lv_plan(r.user_id, r.leave_type, r.from_day, r.to_day, r.half_part) pl where pl.bucket is not null;
--     if v_units = 0 then raise exception 'This request has no working days (weekly off / holiday only)'; end if;
--     for x in select pl.day, pl.bucket, pl.units from public._lv_plan(r.user_id, r.leave_type, r.from_day, r.to_day, r.half_part) pl where pl.bucket is not null loop
--       insert into public.leave_day_alloc (leave_id, user_id, day, bucket, units, half_part)
--       values (r.id, r.user_id, x.day, x.bucket, x.units, r.half_part)
--       on conflict (leave_id, day, bucket) do nothing;
--     end loop;
--     for x in select a.bucket, sum(a.units) as u from public.leave_day_alloc a where a.leave_id = r.id and a.bucket <> 'LOP' group by a.bucket loop
--       perform public._lv_add(r.user_id, case x.bucket when 'EL' then 'Earned Leave' when 'CL' then 'Casual Leave' else 'Sick Leave' end,
--                              r.from_day, 'used', x.u, r.leave_type, r.id, me.id);
--     end loop;
--     update public.leaves set units = v_units, days = greatest(1, ceil(v_units))::int where id = r.id;
--   elsif p_approve then
--     -- OLD requests (before this policy): exactly the previous rule
--     v_elig := public._leave_eligible_from(r.user_id);
--     select coalesce(sum(u.days), 0)::int into r.days
--       from public._leave_usage(r.user_id, r.from_day - 10, r.to_day + 10, array['Approved'], r.from_day, r.to_day, r.id) u
--      where u.leave_type = 'NEW';
--     if r.days = 0 then raise exception 'This request has no working days (weekly off / holiday only)'; end if;
--     update public.leaves set days = r.days where id = r.id;
--     select * into t from public.leave_types where name = r.leave_type;
--     if t.counts_balance and (v_elig is null or r.from_day >= v_elig) then
--       select b.balance into v_bal from public._leave_balance(r.user_id, extract(year from r.from_day)::int) b where b.leave_type = r.leave_type;
--       if r.days > coalesce(v_bal, 0) then
--         raise exception 'Insufficient balance: cannot approve (% day(s) available)', coalesce(v_bal, 0);
--       end if;
--     end if;
--   end if;
--
--   update public.leaves
--      set status = case when p_approve then 'Approved' else 'Rejected' end,
--          reviewed_by = me.id, reviewed_at = now(), review_note = nullif(trim(p_note), '')
--    where id = p_id
--   returning * into r;
--   perform public._audit(case when p_approve then 'APPROVE_LEAVE' else 'REJECT_LEAVE' end, p_id::text);
--   return r;
-- end $$;
--
-- create or replace function public._lv_credit_user(p_user uuid, p_asof date) returns void
-- language plpgsql security definer set search_path = public as $$
-- declare
--   st public.payroll_settings; v_elig date := public._leave_eligible_from(p_user);
--   v_month date := date_trunc('month', p_asof::timestamp)::date; v_bal numeric; v_amt numeric; k text; amt numeric;
-- begin
--   select * into st from public.payroll_settings where id = 1;
--   if v_elig is null or v_elig > p_asof then return; end if;
--   foreach k in array array['Earned Leave', 'Casual Leave', 'Sick Leave'] loop
--     if exists (select 1 from public.leave_ledger where employee_id = p_user and leave_type = k and month = v_month and kind = 'credit') then continue; end if;
--     amt := case k when 'Earned Leave' then 1 else 0.5 end;
--     v_bal := public._lv_bal(p_user, k);
--     -- EL is saved up to the cap; at the cap nothing is added until some is used
--     v_amt := case when k = 'Earned Leave' then least(amt, greatest(0, st.leave_el_cap - v_bal)) else amt end;
--     perform public._lv_add(p_user, k, v_month, 'credit', v_amt, case when v_amt < amt then 'EL balance is at the maximum' else 'Monthly credit' end);
--   end loop;
-- end $$;
--
-- create or replace function public.run_leave_jobs(p_asof date default null) returns jsonb
-- language plpgsql security definer set search_path = public as $$
-- declare
--   st public.payroll_settings; v_day date := coalesce(p_asof, public.ist_today()); v_prev date := coalesce(p_asof, public.ist_today()) - 1;
--   p record; k text; v_bal numeric; n_cred int := 0; n_lapse int := 0;
-- begin
--   if auth.uid() is not null then perform public._require_full_admin(); end if;      -- cron has no signed-in user
--   perform pg_advisory_xact_lock(hashtext('leave_jobs'));
--   select * into st from public.payroll_settings where id = 1;
--
--   -- year-end: the morning after the lapse date, unused CL / SL lapse (EL is carried, never lapsed)
--   if v_prev = make_date(extract(year from v_prev)::int, st.leave_lapse_month, least(st.leave_lapse_day, 28)) + (st.leave_lapse_day - least(st.leave_lapse_day, 28)) then
--     for p in select id from public.profiles loop
--       foreach k in array array['Casual Leave', 'Sick Leave'] loop
--         v_bal := public._lv_bal(p.id, k);
--         if v_bal > 0 and not exists (select 1 from public.leave_ledger where employee_id = p.id and leave_type = k and kind = 'lapse'
--                                        and month = date_trunc('month', v_prev::timestamp)::date) then
--           perform public._lv_add(p.id, k, v_prev, 'lapse', v_bal, 'Lapsed at year end');
--           n_lapse := n_lapse + 1;
--         end if;
--       end loop;
--     end loop;
--   end if;
--
--   -- monthly credit for everybody who is eligible (the current month only; never twice; the eligibility day mid-month is covered)
--   for p in select id from public.profiles where active loop
--     perform public._lv_credit_user(p.id, v_day);
--   end loop;
--   select count(*) into n_cred from public.leave_ledger where kind = 'credit' and month = date_trunc('month', v_day::timestamp)::date;
--   return jsonb_build_object('credited_rows_this_month', n_cred, 'lapsed_now', n_lapse, 'as_of', v_day);
-- end $$;
--
-- create or replace function public.leave_summary(p_user uuid default null) returns jsonb
-- language plpgsql stable security definer set search_path = public as $$
-- declare
--   me public.profiles := public._require_active(); v_user uuid := coalesce(p_user, me.id);
--   st public.payroll_settings; emp public.profiles; v_today date := public.ist_today();
--   v_elig date; v_m date := date_trunc('month', public.ist_today()::timestamp)::date; v_y int := extract(year from public.ist_today())::int;
--   v_el numeric; v_cl numeric; v_sl numeric; c_el numeric; c_cl numeric; c_sl numeric; v_done int;
-- begin
--   if v_user <> me.id and me.role not in ('HR', 'Admin') then raise exception 'You can only view your own leave' using errcode = '42501'; end if;
--   select * into st from public.payroll_settings where id = 1;
--   select * into emp from public.profiles where id = v_user;
--   v_elig := public._leave_eligible_from(v_user);
--   v_el := public._lv_bal(v_user, 'Earned Leave'); v_cl := public._lv_bal(v_user, 'Casual Leave'); v_sl := public._lv_bal(v_user, 'Sick Leave');
--   select coalesce(sum(credited), 0) into c_el from public.leave_ledger where employee_id = v_user and leave_type = 'Earned Leave' and month = v_m and kind = 'credit';
--   select coalesce(sum(credited), 0) into c_cl from public.leave_ledger where employee_id = v_user and leave_type = 'Casual Leave' and month = v_m and kind = 'credit';
--   select coalesce(sum(credited), 0) into c_sl from public.leave_ledger where employee_id = v_user and leave_type = 'Sick Leave' and month = v_m and kind = 'credit';
--   v_done := case when emp.joining_date is null then null
--                  else greatest(0, (extract(year from age(v_today, emp.joining_date)) * 12 + extract(month from age(v_today, emp.joining_date)))::int) end;
--   return jsonb_build_object(
--     'joining_date', emp.joining_date, 'eligible_from', v_elig, 'eligible', (v_elig is not null and v_elig <= v_today),
--     'months_done', v_done, 'months_total', st.leave_eligibility_months, 'days_left', case when v_elig is null then null else greatest(0, v_elig - v_today) end,
--     'early_start', emp.paid_leave_early_from is not null, 'early_reason', emp.paid_leave_early_reason,
--     'el', jsonb_build_object('balance', v_el, 'cap', st.leave_el_cap, 'yearly', 12, 'added_this_month', c_el, 'saved_before', greatest(v_el - c_el, 0)),
--     'cl', jsonb_build_object('balance', v_cl, 'yearly', 6, 'added_this_month', c_cl,
--             'used_year', (select coalesce(sum(used), 0) from public.leave_ledger where employee_id = v_user and leave_type = 'Casual Leave' and extract(year from month) = v_y)),
--     'sl', jsonb_build_object('balance', v_sl, 'yearly', 6, 'added_this_month', c_sl,
--             'used_year', (select coalesce(sum(used), 0) from public.leave_ledger where employee_id = v_user and leave_type = 'Sick Leave' and extract(year from month) = v_y)),
--     'lop_year', (select coalesce(sum(a.units), 0) from public.leave_day_alloc a where a.user_id = v_user and a.bucket = 'LOP' and extract(year from a.day) = v_y),
--     'paid_available', v_el + v_cl + v_sl,
--     'policy', public.get_leave_policy2());
-- end $$;
--
-- -- 2. New objects removed ----------------------------------------------------------------------------------------------------------
-- drop function if exists public.leave_preview_v3(text, date, date, uuid);
-- drop function if exists public.leave_check(text, date, date, text);
-- drop function if exists public._lv_validate(uuid, text, date, date, text);
-- drop function if exists public._lv_dayplan(uuid, text, date, date);
-- drop function if exists public.leave_buckets(uuid, date);
-- drop function if exists public._lv_buckets(uuid, date);
-- drop function if exists public._leave_credit_from(uuid);
-- drop function if exists public.admin_save_leave_rules(date, jsonb);
-- drop function if exists public._lv_int(jsonb, text[], int, int, text);
-- drop function if exists public._lv_bool(jsonb, text[], text);
-- drop function if exists public.get_leave_policy(date);
-- drop function if exists public._lv_policy(date);
-- drop table if exists public.leave_rules;
--
-- -- 3. Half Day - Personal work available again (it was active before) ----------------------------------------------------------------
-- update public.leave_types set active = true where name = 'Half Day - Personal work';
--
-- revoke all on function public.apply_leave(text, date, date, text, text, text, text) from public, anon;
-- revoke all on function public.review_leave(bigint, boolean, text)                   from public, anon;
-- revoke all on function public.run_leave_jobs(date)                                  from public, anon;
-- revoke all on function public.leave_summary(uuid)                                   from public, anon;
-- grant execute on function public.apply_leave(text, date, date, text, text, text, text) to authenticated;
-- grant execute on function public.review_leave(bigint, boolean, text)                to authenticated;
-- grant execute on function public.run_leave_jobs(date)                               to authenticated;
-- grant execute on function public.leave_summary(uuid)                                to authenticated;
--
-- notify pgrst, 'reload schema';
