-- =====================================================================
-- MULTI-SITE FIELD VISIT + FOREIGN LOCATION
-- Adds, on top of the existing check-in / check-out and Field Site journeys:
--   * Legs to a registered site OR to a free-text "Foreign location" (planned stop)
--   * Arrival type on every leg: Verified / Foreign - planned stop / Foreign - mismatch (reason + selfie, no approval)
--   * foreign_events  (Foreign Location Register: foreign check-in / check-out / arrivals)
--   * attendance summary columns, filled automatically at check-out (duty, late, OT, day status, km, legs, foreign stops)
--   * nightly_close(): forgotten check-out is closed at 23:59 as a Half day
--   * field_visit_settings (late time, full / half day hours, OT after)
--   * report views: v_field_visit_legs, v_daily_attendance, v_foreign_register, v_field_live_today
-- Nothing is approved or reviewed anywhere. Existing attendance rows are NOT changed (new columns stay empty for them).
-- check_in / check_out are NOT touched: they already do selfie, geofence and foreign check-out.
-- Run AFTER cvp_attendance_schema.sql and field_journeys.sql, in Supabase SQL Editor.  Safe to run again.
-- Take a database backup first.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Settings (one row)
-- ---------------------------------------------------------------------
create table if not exists public.field_visit_settings (
  id             smallint primary key default 1 check (id = 1),
  late_after     time    not null default '09:45',
  full_day_min   integer not null default 480  check (full_day_min between 60 and 1440),
  half_day_min   integer not null default 240  check (half_day_min between 30 and 1440),
  ot_after_min   integer not null default 540  check (ot_after_min between 60 and 1440),
  updated_at     timestamptz not null default now()
);
insert into public.field_visit_settings (id) values (1) on conflict (id) do nothing;
alter table public.field_visit_settings enable row level security;
drop policy if exists fv_settings_read on public.field_visit_settings;
create policy fv_settings_read on public.field_visit_settings for select to authenticated using (true);
revoke all on public.field_visit_settings from anon;
grant select on public.field_visit_settings to authenticated;

create or replace function public.admin_save_field_visit_settings(p_late time, p_full integer, p_half integer, p_ot integer)
returns public.field_visit_settings
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._require_admin(); r public.field_visit_settings;
begin
  if p_half >= p_full then raise exception 'Half-day hours must be less than full-day hours'; end if;
  if p_ot < p_full then raise exception 'Overtime must start at or after the full-day hours'; end if;
  update public.field_visit_settings set late_after = p_late, full_day_min = p_full, half_day_min = p_half,
         ot_after_min = p_ot, updated_at = now() where id = 1 returning * into r;
  perform public._audit('FIELD_VISIT_SETTINGS', me.username || ': late ' || p_late || ', full ' || p_full || ', half ' || p_half || ', OT ' || p_ot);
  return r;
end $$;
revoke execute on function public.admin_save_field_visit_settings(time, integer, integer, integer) from public, anon;
grant  execute on function public.admin_save_field_visit_settings(time, integer, integer, integer) to authenticated;

-- ---------------------------------------------------------------------
-- 2. Legs: destination can be a foreign place, arrival type, reason + selfie
-- ---------------------------------------------------------------------
alter table public.field_journeys add column if not exists to_foreign boolean not null default false;
alter table public.field_journeys add column if not exists from_foreign boolean not null default false;
alter table public.field_journeys add column if not exists arrival_type text;
alter table public.field_journeys add column if not exists arrival_reason text;
alter table public.field_journeys add column if not exists arrival_photo_path text;
alter table public.field_journeys drop constraint if exists field_journeys_arrival_type_check;
alter table public.field_journeys add constraint field_journeys_arrival_type_check
  check (arrival_type is null or arrival_type in ('Verified', 'Foreign - planned stop', 'Foreign - mismatch'));

-- ---------------------------------------------------------------------
-- 3. Foreign Location Register
-- ---------------------------------------------------------------------
create table if not exists public.foreign_events (
  id              bigint generated always as identity primary key,
  user_id         uuid not null references public.profiles(id) on delete cascade,
  work_date       date not null,
  kind            text not null check (kind in ('CHECK_IN', 'CHECK_OUT', 'ARRIVAL_PLANNED', 'ARRIVAL_MISMATCH')),
  place_name      text not null,
  event_at        timestamptz not null default clock_timestamp(),
  lat             double precision,
  lng             double precision,
  dist_to_site_m  integer,
  nearest_site    text,
  reason          text,
  photo_path      text,
  leg_id          bigint references public.field_journeys(id) on delete set null,
  attendance_id   bigint references public.attendance(id) on delete set null,
  created_at      timestamptz not null default now()
);
create index if not exists foreign_events_user_date_idx on public.foreign_events (user_id, work_date desc);
create index if not exists foreign_events_date_idx on public.foreign_events (work_date desc);
alter table public.foreign_events enable row level security;
drop policy if exists foreign_events_read on public.foreign_events;
create policy foreign_events_read on public.foreign_events for select to authenticated
  using (user_id = auth.uid() or private.is_staff_admin());
revoke all on public.foreign_events from anon;
grant select on public.foreign_events to authenticated;

-- A foreign / outside check-in or check-out (already stored by the existing check_in / check_out) goes into the register too
create or replace function public._fv_selfie_to_foreign() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_date date;
begin
  if not (coalesce(new.outside, false) or coalesce(new.foreign_loc, false)) then return new; end if;
  select a.work_date into v_date from public.attendance a where a.id = new.attendance_id;
  insert into public.foreign_events (user_id, work_date, kind, place_name, event_at, lat, lng, dist_to_site_m, nearest_site,
                                     reason, photo_path, attendance_id)
  values (new.user_id, coalesce(v_date, (new.captured_at at time zone 'Asia/Kolkata')::date),
          case when new.kind = 'IN' then 'CHECK_IN' else 'CHECK_OUT' end,
          coalesce(nullif(trim(new.note), ''), 'Outside ' || new.site_name),
          new.captured_at, new.lat, new.lng, new.distance_m, new.site_name, new.reason, new.photo_path, new.attendance_id);
  -- the place where the day was checked out
  if new.kind = 'OUT' and new.attendance_id is not null then
    update public.attendance set checkout_place = new.site_name where id = new.attendance_id;
  end if;
  return new;
end $$;
revoke execute on function public._fv_selfie_to_foreign() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 4. Attendance summary columns (filled at check-out; old rows stay empty)
-- ---------------------------------------------------------------------
alter table public.attendance add column if not exists checkin_place  text;
alter table public.attendance add column if not exists checkout_place text;
alter table public.attendance add column if not exists legs_count     integer;
alter table public.attendance add column if not exists total_km       numeric(8,1);
alter table public.attendance add column if not exists travel_min     integer;
alter table public.attendance add column if not exists duty_min       integer;
alter table public.attendance add column if not exists late_min       integer;
alter table public.attendance add column if not exists ot_min         integer;
alter table public.attendance add column if not exists day_status     text;
alter table public.attendance add column if not exists foreign_stops  integer;
alter table public.attendance add column if not exists foreign_min    integer;
alter table public.attendance add column if not exists auto_closed    boolean not null default false;

-- selfie_records.foreign_loc / reason exist only after the schema's foreign-location part: make sure they exist
alter table public.selfie_records add column if not exists foreign_loc boolean not null default false;
alter table public.selfie_records add column if not exists reason text;

drop trigger if exists selfie_to_foreign on public.selfie_records;
create trigger selfie_to_foreign after insert on public.selfie_records
  for each row execute function public._fv_selfie_to_foreign();

-- The day is calculated by the server the moment check-out is saved (no approval, nothing manual)
create or replace function public._fv_attendance_summary() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  s        public.field_visit_settings;
  v_in_t   time;
  v_first  timestamptz;
  v_fm     integer := 0;
begin
  if new.checkin_place is null then new.checkin_place := new.site_name; end if;
  if new.check_in_at is null or new.check_out_at is null then return new; end if;
  if tg_op = 'UPDATE' and old.check_out_at is not distinct from new.check_out_at then return new; end if;

  select * into s from public.field_visit_settings where id = 1;
  new.checkout_place := coalesce(new.checkout_place, new.site_name);

  new.duty_min := greatest(0, round(extract(epoch from (new.check_out_at - new.check_in_at)) / 60))::int;
  v_in_t := (new.check_in_at at time zone 'Asia/Kolkata')::time;
  new.late_min := case when v_in_t > s.late_after then floor(extract(epoch from (v_in_t - s.late_after)) / 60)::int else 0 end;
  new.ot_min := greatest(0, new.duty_min - s.ot_after_min);

  select count(*) filter (where j.status = 'Completed'),
         coalesce(sum(j.travel_km), 0),
         coalesce(sum(case when j.end_at is not null then extract(epoch from (j.end_at - j.start_at)) / 60 end), 0)::int
    into new.legs_count, new.total_km, new.travel_min
    from public.field_journeys j where j.user_id = new.user_id and j.journey_date = new.work_date;

  select count(*)::int into new.foreign_stops from public.foreign_events e
   where e.user_id = new.user_id and e.work_date = new.work_date;

  -- time spent at foreign places = until the next leg starts (or until check-out)
  select coalesce(sum(greatest(0, extract(epoch from (coalesce(q.nx, new.check_out_at) - q.end_at)) / 60)), 0)::int into v_fm
    from (select j.end_at, j.arrival_type, lead(j.start_at) over (order by j.start_at) as nx
            from public.field_journeys j
           where j.user_id = new.user_id and j.journey_date = new.work_date and j.status = 'Completed') q
   where q.arrival_type like 'Foreign%';
  select min(j.start_at) into v_first from public.field_journeys j where j.user_id = new.user_id and j.journey_date = new.work_date;
  if exists (select 1 from public.foreign_events e where e.user_id = new.user_id and e.work_date = new.work_date and e.kind = 'CHECK_IN') then
    v_fm := v_fm + greatest(0, round(extract(epoch from (coalesce(v_first, new.check_out_at) - new.check_in_at)) / 60))::int;
  end if;
  new.foreign_min := v_fm;

  if new.auto_closed then
    new.duty_min := s.half_day_min;            -- forgot to check out: Half day, the half-day hours are counted
    new.ot_min := 0;
    new.day_status := 'Half day';
  else
    new.day_status := case when new.duty_min >= s.full_day_min then 'Full day'
                           when new.duty_min >= s.half_day_min then 'Half day'
                           else 'Short day' end;
  end if;
  return new;
end $$;
revoke execute on function public._fv_attendance_summary() from public, anon, authenticated;
drop trigger if exists attendance_fv_summary on public.attendance;
create trigger attendance_fv_summary before insert or update on public.attendance
  for each row execute function public._fv_attendance_summary();

-- ---------------------------------------------------------------------
-- 5. start_leg: FROM = where the employee is now (automatic), TO = a registered site or a foreign place
-- ---------------------------------------------------------------------
create or replace function public.start_leg(
  p_to_site bigint, p_to_place text,
  p_lat double precision, p_lng double precision, p_accuracy integer default null, p_key text default null
) returns public.field_journeys
language plpgsql security definer set search_path = public as $$
declare
  me   public.profiles := public._require_journey_access();
  d    date := public.ist_today();
  a    public.attendance;
  prev public.field_journeys;
  ts   public.sites;
  r    public.field_journeys;
  v_from_id bigint; v_from_name text; v_from_foreign boolean := false;
begin
  if p_key is not null then
    select * into r from public.field_journeys where user_id = me.id and start_key = p_key;
    if r.id is not null then return r; end if;
  end if;
  select * into a from public.attendance where user_id = me.id and work_date = d;
  if a.id is null or a.check_in_at is null then raise exception 'Check in first, then start a field visit'; end if;
  if a.check_out_at is not null then raise exception 'You have already checked out today'; end if;
  if exists (select 1 from public.field_journeys where user_id = me.id and end_at is null) then
    raise exception 'You already have a visit in progress. Press Reached Destination first';
  end if;
  if p_lat is null or p_lng is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 then
    raise exception 'Location is required to start a visit. Turn on GPS and try again';
  end if;

  select * into prev from public.field_journeys
   where user_id = me.id and journey_date = d and status = 'Completed' order by end_at desc limit 1;
  if prev.id is not null then
    v_from_id := prev.to_site_id; v_from_name := prev.to_site_name; v_from_foreign := prev.to_foreign;
  else
    v_from_name := coalesce(nullif(trim(a.checkin_place), ''), nullif(trim(a.site_name), ''), 'Check-in location');
    select s.id into v_from_id from public.sites s where lower(s.name) = lower(v_from_name) limit 1;
    v_from_foreign := v_from_id is null
      and exists (select 1 from public.foreign_events e where e.attendance_id = a.id and e.kind = 'CHECK_IN');
  end if;

  if p_to_site is not null then
    select * into ts from public.sites where id = p_to_site and active;
    if ts.id is null then raise exception 'Choose an active site as the destination'; end if;
    if v_from_id is not null and v_from_id = ts.id then raise exception 'The destination must be different from the place you start from'; end if;
  elsif nullif(trim(p_to_place), '') is null then
    raise exception 'Choose a destination site, or enter the name of the foreign place';
  end if;

  insert into public.field_journeys (user_id, journey_date, from_site_id, from_site_name, from_foreign, to_site_id, to_site_name, to_foreign,
                                     client, purpose, start_lat, start_lng, start_acc_m, start_key)
  values (me.id, d, v_from_id, v_from_name, v_from_foreign, ts.id, coalesce(ts.name, trim(p_to_place)), ts.id is null,
          'Field visit', 'Site visit', p_lat, p_lng, p_accuracy, p_key)
  returning * into r;
  perform public._audit('LEG_START', me.username || ': ' || r.from_site_name || ' > ' || r.to_site_name || case when r.to_foreign then ' (foreign)' else '' end);
  return r;
end $$;

-- ---------------------------------------------------------------------
-- 6. reach_destination: arrival type decided by the server; reason + selfie when foreign / mismatch
-- ---------------------------------------------------------------------
create or replace function public.reach_destination(
  p_lat double precision, p_lng double precision, p_accuracy integer default null, p_key text default null,
  p_reason text default null, p_photo_path text default null
) returns public.field_journeys
language plpgsql security definer set search_path = public as $$
declare
  me     public.profiles := public._require_journey_access();
  j      public.field_journeys;
  ts     public.sites;
  v_dist double precision;
  v_type text;
  ns     record;
begin
  if p_key is not null then
    select * into j from public.field_journeys where user_id = me.id and end_key = p_key;
    if j.id is not null then return j; end if;
  end if;
  select * into j from public.field_journeys where user_id = me.id and end_at is null for update;
  if j.id is null then raise exception 'You have no visit in progress'; end if;
  if p_lat is null or p_lng is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 then
    raise exception 'Location is required to confirm arrival. Turn on GPS and try again';
  end if;

  if j.to_foreign then
    v_type := 'Foreign - planned stop';
  else
    select * into ts from public.sites where id = j.to_site_id;
    if ts.id is not null and public._distance_m(p_lat, p_lng, ts.lat, ts.lng) <= ts.radius_m then
      v_type := 'Verified';
    else
      v_type := 'Foreign - mismatch';
    end if;
  end if;

  if v_type <> 'Verified' then
    if nullif(trim(p_reason), '') is null then raise exception 'Give the reason for this foreign location'; end if;
    if p_photo_path is null or split_part(p_photo_path, '/', 1) <> me.id::text then raise exception 'Take a selfie first'; end if;
  end if;

  j := public.reach_site(p_lat, p_lng, p_accuracy, p_key);       -- time, GPS route km, geofence distance

  update public.field_journeys set
      arrival_type = v_type,
      arrival_reason = case when v_type <> 'Verified' then trim(p_reason) end,
      arrival_photo_path = case when v_type <> 'Verified' then p_photo_path end,
      verify_note = case when to_foreign
                         then nullif(trim(both '; ' from replace(coalesce(verify_note, ''), 'Destination site was removed: arrival could not be checked', '')), '')
                         else verify_note end
    where id = j.id returning * into j;

  if v_type <> 'Verified' then
    select s.name as name, public._distance_m(p_lat, p_lng, s.lat, s.lng) as dist into ns
      from public.sites s where s.active order by public._distance_m(p_lat, p_lng, s.lat, s.lng) limit 1;
    insert into public.foreign_events (user_id, work_date, kind, place_name, event_at, lat, lng, dist_to_site_m, nearest_site, reason, photo_path, leg_id)
    values (me.id, j.journey_date,
            case when j.to_foreign then 'ARRIVAL_PLANNED' else 'ARRIVAL_MISMATCH' end,
            j.to_site_name, j.end_at, p_lat, p_lng,
            case when j.to_foreign then round(ns.dist)::int else j.dest_dist_m end,
            case when j.to_foreign then ns.name else j.to_site_name end,
            trim(p_reason), p_photo_path, j.id);
  end if;
  perform public._audit('LEG_REACHED', me.username || ': ' || j.from_site_name || ' > ' || j.to_site_name || ' (' || v_type || ')');
  return j;
end $$;

revoke execute on function public.start_leg(bigint, text, double precision, double precision, integer, text) from public, anon;
revoke execute on function public.reach_destination(double precision, double precision, integer, text, text, text) from public, anon;
grant  execute on function public.start_leg(bigint, text, double precision, double precision, integer, text) to authenticated;
grant  execute on function public.reach_destination(double precision, double precision, integer, text, text, text) to authenticated;

-- Leg selfies are uploaded by employees with Field Site access (the old policy only allowed Site Employees)
drop policy if exists selfies_upload_leg on storage.objects;
create policy selfies_upload_leg on storage.objects for insert to authenticated
  with check (
    bucket_id = 'selfies'
    and (storage.foldername(name))[1] = auth.uid()::text
    and exists (select 1 from public.profiles p where p.id = auth.uid() and p.active and (p.journey_access or p.site_employee))
  );

-- ---------------------------------------------------------------------
-- 7. nightly_close: forgot to check out -> 23:59 = Half day. Run by pg_cron (below); never by an employee.
-- ---------------------------------------------------------------------
create or replace function public.nightly_close() returns integer
language plpgsql security definer set search_path = public as $$
declare a record; v_end timestamptz; n integer := 0;
begin
  for a in
    select * from public.attendance
     where check_in_at is not null and check_out_at is null
       and (work_date + time '23:59') <= public.ist_now()
  loop
    v_end := (a.work_date + time '23:59') at time zone 'Asia/Kolkata';
    continue when v_end <= a.check_in_at;
    -- a visit still open is closed with the day
    update public.field_journeys set end_at = greatest(v_end, start_at), end_lat = start_lat, end_lng = start_lng, status = 'Completed',
           verified = false, verify_note = 'Closed automatically at 23:59 (no Reached Destination)'
     where user_id = a.user_id and end_at is null;
    update public.attendance set check_out_at = v_end, auto_closed = true where id = a.id;
    n := n + 1;
  end loop;
  if n > 0 then perform public._audit('NIGHTLY_CLOSE', n || ' attendance record(s) closed at 23:59 as Half day'); end if;
  return n;
end $$;
revoke execute on function public.nightly_close() from public, anon, authenticated;

-- 23:59 India time = 18:29 UTC. Needs the pg_cron extension (Supabase: Database > Extensions > pg_cron)
do $$
begin
  begin create extension if not exists pg_cron; exception when others then raise notice 'pg_cron could not be enabled: %', sqlerrm; end;
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'fv-nightly-close';
    perform cron.schedule('fv-nightly-close', '29 18 * * *', 'select public.nightly_close()');
  else
    raise notice 'pg_cron is not enabled: turn it on in Database > Extensions and run this block again. Until then run  select public.nightly_close();  every night.';
  end if;
exception when others then raise notice 'Could not schedule nightly_close: %', sqlerrm;
end $$;

-- ---------------------------------------------------------------------
-- 8. Report views (security_invoker: an employee sees his own rows, Admin / HR see everyone)
-- ---------------------------------------------------------------------
-- A view that already exists with other columns cannot be changed by CREATE OR REPLACE (error 42P16): drop it first (views hold no data)
drop view if exists public.v_field_live_today;
drop view if exists public.v_foreign_register;
drop view if exists public.v_daily_attendance;
drop view if exists public.v_field_visit_legs;

create or replace view public.v_field_visit_legs with (security_invoker = true) as
select j.id, j.user_id, j.journey_date as work_date, p.full_name, p.username as emp_code,
       row_number() over w0 as leg_no,
       j.from_site_id, j.from_site_name, j.from_foreign, j.to_site_id, j.to_site_name, j.to_foreign,
       j.start_at, j.end_at,
       case when j.end_at is not null then round(extract(epoch from (j.end_at - j.start_at)) / 60)::int end as travel_min,
       j.travel_km, j.travel_source, j.dest_dist_m, j.status, j.verified, j.verify_note,
       coalesce(j.arrival_type, case when j.status = 'Completed' then
                  case when j.dest_inside then 'Verified' when j.dest_inside is false then 'Foreign - mismatch' end end) as arrival_type,
       j.arrival_reason, j.arrival_photo_path,
       case when j.end_at is not null and coalesce(lead(j.start_at) over w0, a.check_out_at) is not null
            then greatest(0, round(extract(epoch from (coalesce(lead(j.start_at) over w0, a.check_out_at) - j.end_at)) / 60))::int end as stay_min,
       case when lead(j.start_at) over w0 is not null then 'next leg'
            when a.check_out_at is not null then case when a.auto_closed then 'auto 23:59' else 'check-out' end end as stay_until
  from public.field_journeys j
  join public.profiles p on p.id = j.user_id
  left join public.attendance a on a.user_id = j.user_id and a.work_date = j.journey_date
window w0 as (partition by j.user_id, j.journey_date order by j.start_at);

create or replace view public.v_daily_attendance with (security_invoker = true) as
select a.id, a.user_id, a.work_date, p.full_name, p.username as emp_code,
       a.checkin_place, a.check_in_at, a.checkout_place, a.check_out_at, a.auto_closed,
       coalesce(a.legs_count, 0) as legs_count, a.total_km, a.travel_min, a.foreign_stops, a.foreign_min,
       a.duty_min, a.late_min, a.ot_min, a.day_status,
       (select string_agg(x.s, ' > ' order by x.ord)
          from (select 0 as ord, coalesce(nullif(trim(a.checkin_place), ''), a.site_name, '') as s
                union all
                select l.leg_no, l.to_site_name || case l.arrival_type when 'Foreign - planned stop' then ' (F)'
                                                                       when 'Foreign - mismatch' then ' (M)' else '' end
                  from public.v_field_visit_legs l where l.user_id = a.user_id and l.work_date = a.work_date and l.status = 'Completed') x
         where x.s <> '') as sites_visited
  from public.attendance a
  join public.profiles p on p.id = a.user_id;

create or replace view public.v_foreign_register with (security_invoker = true) as
select e.id, e.user_id, e.work_date, p.full_name, p.username as emp_code, e.kind, e.place_name, e.event_at, e.lat, e.lng,
       e.dist_to_site_m, e.nearest_site, e.reason, e.photo_path, e.leg_id,
       case
         when e.leg_id is not null then (select l.stay_min from public.v_field_visit_legs l where l.id = e.leg_id)
         when e.kind = 'CHECK_IN' then (
           select greatest(0, round(extract(epoch from (coalesce(
                    (select min(j.start_at) from public.field_journeys j where j.user_id = e.user_id and j.journey_date = e.work_date and j.start_at > e.event_at),
                    a.check_out_at) - e.event_at)) / 60))::int
             from public.attendance a where a.user_id = e.user_id and a.work_date = e.work_date)
       end as stay_min
  from public.foreign_events e
  join public.profiles p on p.id = e.user_id;

-- Admin dashboard: who is where right now (today, IST)
create or replace view public.v_field_live_today with (security_invoker = true) as
select p.id as user_id, p.full_name, p.username as emp_code, p.role,
       a.check_in_at, a.check_out_at, a.checkin_place,
       ol.from_site_name as leg_from, ol.to_site_name as leg_to, ol.start_at as leg_started,
       ll.to_site_name as last_place, ll.end_at as last_reached, ll.arrival_type as last_arrival,
       coalesce((select sum(j.travel_km) from public.field_journeys j where j.user_id = p.id and j.journey_date = public.ist_today()), 0) as km_today,
       (select count(*) from public.field_journeys j where j.user_id = p.id and j.journey_date = public.ist_today() and j.status = 'Completed')::int as legs_done,
       coalesce(ol.start_lat, ll.end_lat, a.check_in_lat) as lat,
       coalesce(ol.start_lng, ll.end_lng, a.check_in_lng) as lng,
       case
         when a.check_in_at is null then 'Not checked in'
         when a.check_out_at is not null then 'Checked out'
         when ol.id is not null then 'On a leg'
         when ll.id is not null and (ll.to_foreign or ll.arrival_type like 'Foreign%') then 'At a foreign place'
         else 'At site'
       end as state
  from public.profiles p
  left join public.attendance a on a.user_id = p.id and a.work_date = public.ist_today()
  left join lateral (select * from public.field_journeys j where j.user_id = p.id and j.end_at is null limit 1) ol on true
  left join lateral (select * from public.field_journeys j where j.user_id = p.id and j.journey_date = public.ist_today() and j.status = 'Completed'
                      order by j.end_at desc limit 1) ll on true
 where p.active and p.role in ('Employee', 'HR');

revoke all on public.v_field_visit_legs, public.v_daily_attendance, public.v_foreign_register, public.v_field_live_today from anon;
grant select on public.v_field_visit_legs, public.v_daily_attendance, public.v_foreign_register, public.v_field_live_today to authenticated;

notify pgrst, 'reload schema';
