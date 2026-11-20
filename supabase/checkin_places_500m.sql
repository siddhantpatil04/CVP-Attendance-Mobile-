-- =====================================================================
-- CHECK-IN / CHECK-OUT: PLACES WITHIN 500 m (employee selects), NO TIME LIMIT, 8 WORKING HOURS - site and office employees
--
-- This file REPLACES the earlier "nearest allocated site auto-selected" rule of employee_allocated_sites.sql
-- (its trigger trg_enforce_allocated_site is switched off below and replaced by trg_enforce_checkin_place).
-- Needs the employee_sites table (core schema, Site Access) and site_selfie_daily_report_checkout.sql (checkout_report_overrides).
--
-- WHAT THE SERVER NOW DOES
--  1. my_places_near_me(lat, lng): only places within the range (default 500 m) that the employee may use
--       = his allocated sites + the office location. Nothing is chosen for him.
--  2. Check-in / check-out (every app version, a database trigger):
--       - place not allocated to him and not the office -> "This place is not allocated to you."
--       - more than the range from that place            -> "You are more than 500 m from this place."
--       - the place he selected at check-out (select_checkout_place) may differ from the check-in place; both are saved
--         (attendance.checkin_place_id / checkout_place_id / place_kind).
--  3. NO time window of any kind (nothing here looks at the time of day).  Times are server time (Asia/Kolkata).
--  4. Worked time = check-out minus check-in (attendance.work_minutes, already calculated by the database).
--       Required hours per day = working_time_rules.required_minutes (default 8h 00m), separate for site / office.
--       Day status: Full day (8h or more) | Short hours (less than 8h, short_reason is saved) | Working | No check-out | Not checked in.
--       A check-out before 8h needs a reason first (set_short_hours_reason) - "Allowed with reason".
--  5. Admin / HR: working_time_rules (range, required hours, before-8h behaviour) and "Today - working hours" + KPIs.
--
-- NOT TOUCHED: selfie camera, leave, salary and payroll formulas, cvp_attendance_schema.sql.
--   (Payroll already uses hours elsewhere: payroll_settings.standard_minutes / unpaid break and field_visit_settings full_day_min.
--    This file does not change them.)
--
-- ONE additive file.  Safe to run again.  No safety lock.  No table is dropped and no data is deleted.
-- BACK UP THE DATABASE FIRST.   Supabase -> SQL Editor -> paste the WHOLE file -> Run.
-- =====================================================================

-- 1. Rules: one row for site employees, one for office employees ---------------------------------------------------
create table if not exists public.working_time_rules (
  kind             text primary key check (kind in ('site', 'office')),
  range_m          integer not null default 500  check (range_m between 50 and 5000),
  required_minutes integer not null default 480  check (required_minutes between 60 and 1440),
  before_required  text    not null default 'reason' check (before_required in ('reason', 'block')),   -- reason = allowed with a reason (Short hours)
  updated_by       uuid references public.profiles(id) on delete set null,
  updated_at       timestamptz not null default now()
);
insert into public.working_time_rules (kind) values ('site'), ('office') on conflict (kind) do nothing;
alter table public.working_time_rules enable row level security;
drop policy if exists working_time_rules_read on public.working_time_rules;
create policy working_time_rules_read on public.working_time_rules for select to authenticated using (true);
revoke all on public.working_time_rules from anon;
revoke insert, update, delete on public.working_time_rules from authenticated;
grant select on public.working_time_rules to authenticated;

-- the rule row that applies to one employee (site employees -> 'site', everybody else -> 'office')
create or replace function public._rule_for(p_user uuid) returns public.working_time_rules
language sql stable security definer set search_path = public as $$
  select r.* from public.working_time_rules r
   where r.kind = case when coalesce((select p.site_employee from public.profiles p where p.id = p_user), false) then 'site' else 'office' end
$$;

-- 2. Attendance columns (only what is missing; work_minutes, checkin_place, checkout_place, day_status already exist) ------
alter table public.attendance add column if not exists checkin_place_id  bigint references public.sites(id) on delete set null;
alter table public.attendance add column if not exists checkout_place_id bigint references public.sites(id) on delete set null;
alter table public.attendance add column if not exists place_kind        text;      -- 'site' | 'office'  (place_type is the older Foreign Location mark and is not reused)
alter table public.attendance add column if not exists short_reason      text;
alter table public.attendance add column if not exists check_out_site_name text;
alter table public.attendance drop constraint if exists attendance_place_kind_check;
alter table public.attendance add constraint attendance_place_kind_check check (place_kind is null or place_kind in ('site', 'office'));

-- 3. Reason for a check-out before the required hours (written BEFORE the check-out) -------------------------------
create table if not exists public.attendance_short_reasons (
  user_id    uuid not null references public.profiles(id) on delete cascade,
  work_date  date not null,
  reason     text not null check (length(trim(reason)) > 0),
  created_at timestamptz not null default now(),
  primary key (user_id, work_date)
);
alter table public.attendance_short_reasons enable row level security;
drop policy if exists short_reasons_read on public.attendance_short_reasons;
create policy short_reasons_read on public.attendance_short_reasons for select to authenticated
  using (user_id = auth.uid() or exists (select 1 from public.profiles p where p.id = auth.uid() and p.active and p.role in ('Admin', 'HR')));
revoke all on public.attendance_short_reasons from anon;
revoke insert, update, delete on public.attendance_short_reasons from authenticated;
grant select on public.attendance_short_reasons to authenticated;

create or replace function public.set_short_hours_reason(p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._require_active();
begin
  if nullif(trim(coalesce(p_reason, '')), '') is null then raise exception 'Enter the reason'; end if;
  insert into public.attendance_short_reasons (user_id, work_date, reason)
  values (me.id, public.ist_today(), trim(p_reason))
  on conflict (user_id, work_date) do update set reason = excluded.reason, created_at = now();
end $$;

-- 4. The place the employee selected for CHECK-OUT (kept until the check-out is saved) ------------------------------
create table if not exists public.checkout_place_choice (
  user_id   uuid   not null references public.profiles(id) on delete cascade,
  work_date date   not null,
  site_id   bigint not null references public.sites(id) on delete cascade,
  chosen_at timestamptz not null default now(),
  primary key (user_id, work_date)
);
alter table public.checkout_place_choice enable row level security;
revoke all on public.checkout_place_choice from anon, authenticated;

-- 5. Which places may this employee use?  (allocated sites + the office location) -----------------------------------
--    Same fallbacks as before, so nobody is locked out the day this runs:
--      * an office is allowed when it is allocated to him, when no office is allocated to him (then every office),
--        and ALWAYS for a site employee: when he comes to the office area he can check in and out at that office (no selfie)
--      * a site employee with NO allocated site at all can use any active (non-office) site, until Admin allocates sites
create or replace function public._place_allowed(p_user uuid, p_site bigint) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1
      from public.sites s
      join public.profiles p on p.id = p_user
     where s.id = p_site and s.active
       and (
         exists (select 1 from public.employee_sites e where e.user_id = p_user and e.site_id = s.id)
         or (s.is_office and coalesce(p.site_employee, false))                                    -- a site employee may use any office he is at
         or (s.is_office and not exists (select 1 from public.employee_sites e join public.sites o on o.id = e.site_id and o.is_office where e.user_id = p_user))
         or (not s.is_office and coalesce(p.site_employee, false) and not exists (select 1 from public.employee_sites e where e.user_id = p_user))
       )
  )
$$;

-- 6. The phone's list: places within the range, nearest first, NOTHING selected -------------------------------------
create or replace function public.my_places_near_me(p_lat double precision, p_lng double precision)
returns table (site_id bigint, name text, place_kind text, distance_m integer, radius_m integer, range_m integer, lat double precision, lng double precision, is_office boolean)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare
  me   public.profiles := public._require_active();
  rl public.working_time_rules := public._rule_for(me.id);
begin
  if p_lat is null or p_lng is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 then
    raise exception 'GPS is not available. Turn on location and try again';
  end if;
  return query
  select s.id, s.name, case when coalesce(s.is_office, false) then 'office' else 'site' end,
         round(d.m)::integer, s.radius_m, rl.range_m, s.lat, s.lng, coalesce(s.is_office, false)
    from public.sites s
    cross join lateral (select public._distance_m(p_lat, p_lng, s.lat, s.lng) as m) d
   where s.active
     and d.m <= rl.range_m
     and public._place_allowed(me.id, s.id)
     and (coalesce(me.site_employee, false) or coalesce(s.is_office, false))     -- an office employee checks in at the office location
   order by d.m;
end $$;

-- "I am at THIS place" for the check-out (the app calls it, then check_out).  Checked again by the trigger below.
create or replace function public.select_checkout_place(p_site_id bigint, p_lat double precision, p_lng double precision) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me   public.profiles := public._require_active();
  rl public.working_time_rules := public._rule_for(me.id);
  s    public.sites;
  d    double precision;
begin
  select * into s from public.sites where id = p_site_id and active;
  if s.id is null or not public._place_allowed(me.id, s.id) then raise exception 'This place is not allocated to you.'; end if;
  d := public._distance_m(p_lat, p_lng, s.lat, s.lng);
  if d is null or d > rl.range_m then raise exception 'You are more than % m from this place.', rl.range_m; end if;
  insert into public.checkout_place_choice (user_id, work_date, site_id) values (me.id, public.ist_today(), s.id)
  on conflict (user_id, work_date) do update set site_id = excluded.site_id, chosen_at = now();
  return jsonb_build_object('site_id', s.id, 'name', s.name, 'distance_m', round(d)::integer);
end $$;

-- 7. The range is the Admin setting everywhere a check-in / check-out measures distance ---------------------------------
--    (_geofence_check: site punches, selfie decision "inside / outside";  _office_check: office punches).  Only the radius changes.
create or replace function public._geofence_check(
  p_site_id bigint, p_lat double precision, p_lng double precision
) returns table (site_name text, distance_m integer, inside boolean)
language plpgsql stable security definer set search_path = public as $$
declare s public.sites; d double precision; rng integer;
begin
  if p_site_id is null then
    if exists (select 1 from public.sites where active) then
      raise exception 'Select your work site before submitting';
    end if;
    return query select null::text, null::integer, true;
    return;
  end if;
  select * into s from public.sites where id = p_site_id and active;
  if s.id is null then raise exception 'This site is not active. Select another site'; end if;
  if exists (select 1 from public.employee_sites where user_id = auth.uid())
     and not exists (select 1 from public.employee_sites where user_id = auth.uid() and site_id = p_site_id) then
    raise exception 'You do not have access to this site. Ask HR / Admin';
  end if;
  d := public._distance_m(p_lat, p_lng, s.lat, s.lng);
  rng := coalesce((public._rule_for(auth.uid())).range_m, s.radius_m);
  return query select s.name, round(d)::integer, (d is not null and d <= rng);
end $$;

create or replace function public._office_check(p_user uuid, p_lat double precision, p_lng double precision)
returns table (site_name text, distance_m integer)
language plpgsql stable security definer set search_path = public as $$
declare has_assign boolean; best_name text; best_d double precision; best_r integer;
begin
  if not exists (select 1 from public.sites where active and is_office) then
    return query select null::text, null::integer;          -- no office defined yet: not enforced
    return;
  end if;
  if p_lat is null or p_lng is null then
    raise exception 'Location is required to check in or out at the office. Turn on location and try again';
  end if;
  -- an office employee uses his assigned office(s); a site employee may use ANY office (he checks in / out there with no selfie)
  has_assign := not coalesce((select p.site_employee from public.profiles p where p.id = p_user), false)
                and exists (select 1 from public.employee_sites e join public.sites s on s.id = e.site_id
                             where e.user_id = p_user and s.is_office);
  select s.name, public._distance_m(p_lat, p_lng, s.lat, s.lng), s.radius_m
    into best_name, best_d, best_r
    from public.sites s
   where s.active and s.is_office
     and (not has_assign or exists (select 1 from public.employee_sites e where e.user_id = p_user and e.site_id = s.id))
   order by public._distance_m(p_lat, p_lng, s.lat, s.lng)
   limit 1;
  if best_name is null then raise exception 'No office location is assigned to you. Ask HR / Admin'; end if;
  best_r := coalesce((public._rule_for(p_user)).range_m, best_r);
  if best_d > best_r then
    raise exception 'You are more than % m from this place.', best_r;
  end if;
  return query select best_name, round(best_d)::integer;
end $$;

-- 8. Server rule for check-in AND check-out (a deferred constraint trigger: the place / Foreign Location flags are final by then) ---
drop trigger if exists trg_enforce_allocated_site on public.attendance;      -- the older "nearest site" rule is replaced by this one

create or replace function public._enforce_checkin_place() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  a    public.attendance;
  me   public.profiles;
  rl public.working_time_rules;
  s    public.sites;
  v_in boolean; v_out boolean; v_choice bigint; d double precision;
begin
  if auth.uid() is null or auth.uid() <> new.user_id then return new; end if;                  -- Admin edits, regularisation, jobs
  if coalesce(current_setting('app.travel_rpc', true), '') = 'on' then return new; end if;      -- Field Site travel legs: unchanged
  if tg_op = 'UPDATE' and (new.checkin_place_id is distinct from old.checkin_place_id
                        or new.checkout_place_id is distinct from old.checkout_place_id) then return new; end if;   -- our own write below

  v_in  := new.check_in_at  is not null and (tg_op = 'INSERT' or old.check_in_at is null);
  v_out := new.check_out_at is not null and tg_op = 'UPDATE' and old.check_out_at is null;
  if not (v_in or v_out) then return new; end if;

  select * into me from public.profiles where id = new.user_id;
  select * into a  from public.attendance where id = new.id;                                     -- the final row of this call
  if a.place_type = 'Foreign Location' then return new; end if;                                  -- Foreign Location: unchanged
  if coalesce(me.wide_site_access, false) then return new; end if;                               -- Foreign Location access: free place
  rl := public._rule_for(a.user_id);

  if v_in then
    -- no office defined yet and an office employee: nothing to check (as before)
    if not coalesce(me.site_employee, false) and a.site_name is null and not exists (select 1 from public.sites where active and is_office) then return new; end if;
    select * into s from public.sites where active and name = a.site_name limit 1;
    if s.id is null or not public._place_allowed(a.user_id, s.id) then raise exception 'This place is not allocated to you.'; end if;
    d := public._distance_m(a.check_in_lat, a.check_in_lng, s.lat, s.lng);                       -- calculated again on the server
    if d is null or d > rl.range_m then raise exception 'You are more than % m from this place.', rl.range_m; end if;
    update public.attendance set checkin_place_id = s.id, place_kind = case when coalesce(s.is_office, false) then 'office' else 'site' end
     where id = a.id;
  else
    if not coalesce(me.site_employee, false) and not exists (select 1 from public.sites where active and is_office) then return new; end if;
    select c.site_id into v_choice from public.checkout_place_choice c where c.user_id = a.user_id and c.work_date = a.work_date;
    if v_choice is not null then
      select * into s from public.sites where id = v_choice and active;                          -- the place he selected
      if s.id is null or not public._place_allowed(a.user_id, s.id) then raise exception 'This place is not allocated to you.'; end if;
      d := public._distance_m(a.check_out_lat, a.check_out_lng, s.lat, s.lng);
      if d is null or d > rl.range_m then raise exception 'You are more than % m from this place.', rl.range_m; end if;
    else
      -- an older app version sent no selection: the nearest place he may use within the range
      select x.* into s
        from public.sites x
       where x.active and public._place_allowed(a.user_id, x.id)
         and (coalesce(me.site_employee, false) or coalesce(x.is_office, false))
         and public._distance_m(a.check_out_lat, a.check_out_lng, x.lat, x.lng) <= rl.range_m
       order by public._distance_m(a.check_out_lat, a.check_out_lng, x.lat, x.lng) limit 1;
      if s.id is null then
        -- Admin "Allow once" (Daily Report prompt): the check-out is allowed away from a place
        if exists (select 1 from public.checkout_report_overrides o where o.employee_id = a.user_id and o.work_date = a.work_date) then
          update public.attendance set checkout_place_id = a.checkin_place_id, check_out_site_name = a.site_name where id = a.id;
          return new;
        end if;
        raise exception 'You are more than % m from this place.', rl.range_m;
      end if;
    end if;
    update public.attendance
       set checkout_place_id = s.id, check_out_site_name = s.name, checkout_place = s.name,
           place_kind = coalesce(place_kind, case when coalesce(s.is_office, false) then 'office' else 'site' end)
     where id = a.id;
  end if;
  return new;
end $$;
revoke all on function public._enforce_checkin_place() from public, anon, authenticated;

drop trigger if exists trg_enforce_checkin_place on public.attendance;
create constraint trigger trg_enforce_checkin_place
  after insert or update on public.attendance
  deferrable initially deferred
  for each row execute function public._enforce_checkin_place();

-- Required hours of ONE day: the daily rule, or HALF of it on the date of an approved half-day leave (leave_policy_24.sql).
-- Works before that file is run too (then it is always the full rule).
create or replace function public._required_minutes_on(p_user uuid, p_day date) returns integer
language plpgsql stable security definer set search_path = public as $$
declare v_req integer; v_half boolean := false;
begin
  select r.required_minutes into v_req from public._rule_for(p_user) r;
  if to_regclass('public.leave_day_alloc') is not null then
    execute 'select exists (select 1 from public.leave_day_alloc a where a.user_id = $1 and a.day = $2 and a.half_part is not null group by a.day having sum(a.units) = 0.5)'
      into v_half using p_user, p_day;
  end if;
  return case when coalesce(v_half, false) then v_req / 2 else v_req end;
end $$;
revoke all on function public._required_minutes_on(uuid, date) from public, anon, authenticated;
-- 9. Hours and day status (server only; never trust hours sent by the phone) --------------------------------------------
--    BEFORE trigger named "zz" so it runs after attendance_fv_summary and its Full day / Half day / Short day wording is replaced.
create or replace function public._apply_working_hours() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  rl   public.working_time_rules;
  v_min  integer; v_reason text; v_self boolean; v_req text; v_need integer;
begin
  if new.check_in_at is null or new.check_out_at is null then return new; end if;
  if new.auto_closed then return new; end if;                                                    -- a forgotten check-out closed by the system keeps its status
  if tg_op = 'UPDATE' and old.check_out_at is not distinct from new.check_out_at and old.check_in_at is not distinct from new.check_in_at then
    return new;
  end if;

  rl  := public._rule_for(new.user_id);
  v_need := public._required_minutes_on(new.user_id, new.work_date);                              -- half on a half-day leave date
  v_min := (extract(epoch from (new.check_out_at - new.check_in_at)) / 60)::integer;             -- same as attendance.work_minutes
  v_req := (v_need / 60) || 'h ' || lpad((v_need % 60)::text, 2, '0') || 'm';
  v_self := auth.uid() is not null and auth.uid() = new.user_id and tg_op = 'UPDATE' and old.check_out_at is null;

  if v_min >= v_need then
    new.day_status := 'Full day';
  else
    select r.reason into v_reason from public.attendance_short_reasons r where r.user_id = new.user_id and r.work_date = new.work_date;
    if v_self then
      if rl.before_required = 'block' then
        raise exception 'You cannot check out before % of work.', v_req;
      end if;
      if v_reason is null then
        raise exception 'Less than %. Enter the reason before checking out.', v_req;
      end if;
    end if;
    new.short_reason := coalesce(v_reason, new.short_reason);
    new.day_status := 'Short hours';
  end if;
  return new;
end $$;
revoke all on function public._apply_working_hours() from public, anon, authenticated;

drop trigger if exists attendance_zz_hours on public.attendance;
create trigger attendance_zz_hours before insert or update on public.attendance
  for each row execute function public._apply_working_hours();

-- 10. Admin: rules, today's table, KPI cards -------------------------------------------------------------------------------
create or replace function public.admin_save_working_time_rules(p_kind text, p_range_m integer, p_required_minutes integer, p_before text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._require_admin(); r public.working_time_rules;
begin
  if p_kind not in ('site', 'office') then raise exception 'Choose Site employees or Office employees'; end if;
  if p_range_m is null or p_range_m not between 50 and 5000 then raise exception 'Place range must be between 50 m and 5000 m'; end if;
  if p_required_minutes is null or p_required_minutes not between 60 and 1440 then raise exception 'Required hours must be between 1 and 24'; end if;
  if p_before not in ('reason', 'block') then raise exception 'Choose what happens before the required hours'; end if;
  update public.working_time_rules
     set range_m = p_range_m, required_minutes = p_required_minutes, before_required = p_before, updated_by = me.id, updated_at = now()
   where kind = p_kind returning * into r;
  perform public._audit('WORKING_RULES_CHANGED', p_kind || ': range ' || p_range_m || ' m, required ' || p_required_minutes || ' min, before: ' || p_before);
  return to_jsonb(r);
end $$;

create or replace function public.admin_working_hours_today(p_date date default null)
returns table (user_id uuid, username text, full_name text, place text, check_in_at timestamptz, check_out_at timestamptz,
               worked_minutes integer, required_minutes integer, status text, short_reason text, short_minutes integer)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare v_day date := coalesce(p_date, public.ist_today());
begin
  perform public._require_admin();
  return query
  select p.id, p.username, p.full_name,
         nullif(trim(coalesce(nullif(a.checkin_place, ''), a.site_name, '')
                     || case when a.checkout_place is not null and a.checkout_place is distinct from coalesce(nullif(a.checkin_place, ''), a.site_name)
                             then ' > ' || a.checkout_place else '' end), ''),
         a.check_in_at, a.check_out_at,
         w.mins, r.required_minutes,
         case when a.check_in_at is null then 'Not checked in'
              when a.check_out_at is null then case when v_day < public.ist_today() then 'No check-out' else 'Working' end
              when w.mins >= r.required_minutes then 'Full day'
              else 'Short hours' end,
         a.short_reason,
         case when a.check_out_at is not null and w.mins < r.required_minutes then r.required_minutes - w.mins end
    from public.profiles p
    left join public.attendance a on a.user_id = p.id and a.work_date = v_day
    cross join lateral (select public._required_minutes_on(p.id, v_day) as required_minutes) r
    cross join lateral (select case when a.check_in_at is null then null
                                    when a.check_out_at is not null then (extract(epoch from (a.check_out_at - a.check_in_at)) / 60)::integer
                                    when v_day = public.ist_today() then floor(extract(epoch from (now() - a.check_in_at)) / 60)::integer
                               end as mins) w
   where p.active and (p.role = 'Employee' or a.id is not null)
   order by (a.check_in_at is null), p.full_name;
end $$;

create or replace function public.admin_working_hours_kpis(p_date date default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_day date := coalesce(p_date, public.ist_today()); out jsonb;
begin
  perform public._require_admin();
  select jsonb_build_object(
           'total',       count(*),
           'checked_in',  count(*) filter (where t.status <> 'Not checked in'),
           'full_day',    count(*) filter (where t.status = 'Full day'),
           'short_hours', count(*) filter (where t.status = 'Short hours'),
           'no_checkout_yesterday',
              (select count(*) from public.attendance y
                where y.work_date = public.ist_today() - 1 and y.check_in_at is not null and y.check_out_at is null))
    into out
    from public.admin_working_hours_today(v_day) t;
  return out;
end $$;

-- 11. Permissions -----------------------------------------------------------------------------------------------------------
revoke all on function public._rule_for(uuid) from public, anon, authenticated;
revoke all on function public._place_allowed(uuid, bigint) from public, anon, authenticated;
revoke all on function public.set_short_hours_reason(text) from public, anon;
revoke all on function public.my_places_near_me(double precision, double precision) from public, anon;
revoke all on function public.select_checkout_place(bigint, double precision, double precision) from public, anon;
revoke all on function public.admin_save_working_time_rules(text, integer, integer, text) from public, anon;
revoke all on function public.admin_working_hours_today(date) from public, anon;
revoke all on function public.admin_working_hours_kpis(date) from public, anon;
grant execute on function public.set_short_hours_reason(text) to authenticated;
grant execute on function public.my_places_near_me(double precision, double precision) to authenticated;
grant execute on function public.select_checkout_place(bigint, double precision, double precision) to authenticated;
grant execute on function public.admin_save_working_time_rules(text, integer, integer, text) to authenticated;
grant execute on function public.admin_working_hours_today(date) to authenticated;
grant execute on function public.admin_working_hours_kpis(date) to authenticated;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------
-- UNDO (only if needed; nothing is deleted): switch the new rules off again
--   drop trigger if exists trg_enforce_checkin_place on public.attendance;
--   drop trigger if exists attendance_zz_hours on public.attendance;
--   (to go back to the older rule: run the "create constraint trigger trg_enforce_allocated_site" part of employee_allocated_sites.sql again)
-- ---------------------------------------------------------------------
