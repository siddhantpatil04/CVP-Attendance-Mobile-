-- =====================================================================
-- FOREIGN LOCATION (place type) FOR SITE SELFIE ATTENDANCE
--   * In Site Selfie the employee can choose "Foreign Location" in "Select place", then pick the work site he is working for.
--   * It is the normal site selfie attendance (same live selfie, GPS, working hours) with one extra mark:
--     the attendance row and its selfie records carry place_type = 'Foreign Location'.
--   * NO distance limit: the employee may be anywhere. Instead he must give a REASON, a live selfie and GPS.
--     The distance from the chosen site is only RECORDED, so Admin / HR can see it.
--   * The server enforces: reason + live selfie + GPS, no second check-in, no check-out without a check-in,
--     no second check-out, check-out at the site of the check-in, a new selfie at check-out.
--   * Works for ordinary site employees and for Travel Access employees (every stop can be a Foreign Location stop).
--   * ADDITIVE ONLY: new nullable columns and new functions. No existing table, row, function or policy is changed or removed.
--     The existing check_in / check_out / site_travel_* functions are called as they are.
--   * Different from the older "Foreign Location Access" switch (check in / out from ANY place): that keeps working as before.
-- Run AFTER cvp_attendance_schema.sql, multisite_field_visit.sql and foreign_checkin_checkout.sql, in Supabase SQL Editor.
-- Safe to run again.  Take a database backup first (and try it on a staging copy).
-- =====================================================================

alter table public.attendance      add column if not exists place_type      text;
alter table public.attendance      add column if not exists foreign_site_id bigint references public.sites(id) on delete set null;
alter table public.selfie_records  add column if not exists place_type      text;
alter table public.attendance_legs add column if not exists place_type      text;   -- stops of a Travel Access employee
alter table public.attendance      add column if not exists check_in_reason  text;
alter table public.attendance      add column if not exists check_out_reason text;
alter table public.selfie_records  add column if not exists reason          text;

alter table public.attendance     drop constraint if exists attendance_place_type_check;
alter table public.attendance     add  constraint attendance_place_type_check     check (place_type is null or place_type in ('Foreign Location'));
alter table public.selfie_records drop constraint if exists selfie_records_place_type_check;
alter table public.selfie_records add  constraint selfie_records_place_type_check check (place_type is null or place_type in ('Foreign Location'));

create index if not exists selfie_place_type_idx on public.selfie_records (place_type) where place_type is not null;

-- the selfie of a Foreign Location punch may be uploaded by any site employee (it is made away from the site)
-- (the existing selfies_upload_own policy already lets site employees upload into their own folder)

-- older versions of these functions (before the reason was added)
drop function if exists public.foreign_place_check_in(double precision, double precision, bigint, text, text);
drop function if exists public.foreign_place_check_out(double precision, double precision, text, text);
drop function if exists public.foreign_place_travel_check_in(double precision, double precision, bigint, text, text);
drop function if exists public.foreign_place_travel_check_out(double precision, double precision, text, text);

-- ---------------------------------------------------------------------
-- Foreign Location check-in (ordinary site employee)
-- ---------------------------------------------------------------------
create or replace function public.foreign_place_check_in(
  p_lat        double precision,
  p_lng        double precision,
  p_site_id    bigint,
  p_note       text default null,
  p_photo_path text default null,
  p_reason     text default null
) returns public.attendance
language plpgsql volatile security definer set search_path = public as $$
declare
  me public.profiles := public._require_active();
  s  public.sites;
  g  record;
  r  public.attendance;
begin
  if not me.site_employee then
    raise exception 'Site selfie attendance is not enabled for your account';
  end if;
  if p_site_id is null then
    raise exception 'Select the foreign site / location first';
  end if;
  select * into s from public.sites where id = p_site_id and active;
  if s.id is null then
    raise exception 'This site is not active. Select another site';
  end if;
  if public._is_office_site(p_site_id) then
    raise exception 'Choose a work site. The office location is not a foreign location';
  end if;
  if nullif(trim(p_reason), '') is null then
    raise exception 'Give the reason for the Foreign Location attendance';
  end if;
  if p_lat is null or p_lng is null then
    raise exception 'Location is required. Turn on location and try again';
  end if;
  if p_photo_path is null or split_part(p_photo_path, '/', 1) <> me.id::text then
    raise exception 'Take a live selfie first';
  end if;

  select * into g from public._geofence_check(p_site_id, p_lat, p_lng);   -- distance only (no limit)

  -- the existing check-in: duplicate check, selfie record, distance, audit
  r := public.check_in(p_lat, p_lng, g.site_name, p_note, p_photo_path, p_site_id, null);

  update public.attendance
     set place_type = 'Foreign Location', foreign_site_id = p_site_id, check_in_reason = trim(p_reason)
   where id = r.id returning * into r;
  -- away from the site the existing code stores the punch as "outside, no selfie": keep the selfie and the reason instead
  update public.selfie_records
     set place_type = 'Foreign Location', reason = trim(p_reason), photo_path = p_photo_path, outside = false
   where attendance_id = r.id and kind = 'IN';
  update public.foreign_events set reason = trim(p_reason), photo_path = p_photo_path
   where attendance_id = r.id and kind = 'CHECK_IN';
  perform public._audit('FOREIGN_PLACE_CHECK_IN', s.name || ' (' || coalesce(g.distance_m::text, '?') || ' m from the site point): ' || trim(p_reason));
  return r;
end $$;

-- ---------------------------------------------------------------------
-- Foreign Location check-out: the site is the one of today's Foreign Location check-in
-- ---------------------------------------------------------------------
create or replace function public.foreign_place_check_out(
  p_lat        double precision,
  p_lng        double precision,
  p_note       text default null,
  p_photo_path text default null,
  p_reason     text default null
) returns public.attendance
language plpgsql volatile security definer set search_path = public as $$
declare
  me public.profiles := public._require_active();
  a  public.attendance;
  s  public.sites;
  g  record;
  r  public.attendance;
begin
  select * into a from public.attendance where user_id = me.id and work_date = public.ist_now()::date;
  if a.id is null or a.check_in_at is null then
    raise exception 'You have not checked in today';
  end if;
  if a.check_out_at is not null then
    raise exception 'You have already checked out today';
  end if;
  if a.place_type is distinct from 'Foreign Location' or a.foreign_site_id is null then
    raise exception 'Today''s check-in was not a Foreign Location check-in';
  end if;
  if nullif(trim(p_reason), '') is null then
    raise exception 'Give the reason for the Foreign Location attendance';
  end if;
  if p_lat is null or p_lng is null then
    raise exception 'Location is required. Turn on location and try again';
  end if;
  if p_photo_path is null or split_part(p_photo_path, '/', 1) <> me.id::text then
    raise exception 'Take a live selfie first';
  end if;
  if exists (select 1 from public.selfie_records where attendance_id = a.id and photo_path = p_photo_path) then
    raise exception 'Check-out needs a new selfie, different from the check-in selfie';
  end if;

  select * into s from public.sites where id = a.foreign_site_id;
  select * into g from public._geofence_check(a.foreign_site_id, p_lat, p_lng);   -- distance only (no limit)

  -- the existing check-out: distance, selfie record, working-hours fields, audit
  r := public.check_out(p_lat, p_lng, g.site_name, p_note, p_photo_path, a.foreign_site_id, trim(p_reason));

  update public.attendance set check_out_reason = trim(p_reason) where id = r.id returning * into r;
  update public.selfie_records
     set place_type = 'Foreign Location', reason = trim(p_reason), photo_path = p_photo_path, outside = false
   where attendance_id = r.id and kind = 'OUT';
  update public.foreign_events set reason = trim(p_reason), photo_path = p_photo_path
   where attendance_id = r.id and kind = 'CHECK_OUT';
  perform public._audit('FOREIGN_PLACE_CHECK_OUT', coalesce(s.name, g.site_name) || ' (' || coalesce(g.distance_m::text, '?') || ' m from the site point): ' || trim(p_reason));
  return r;
end $$;

-- ---------------------------------------------------------------------
-- Travel Access employees (stop 1, stop 2 ...): Foreign Location stop check-in / check-out
--   They call the existing site_travel_check_in / site_travel_check_out (stops, trips, km are saved as before)
--   and mark the stop and its selfie records as Foreign Location.
-- ---------------------------------------------------------------------
create or replace function public.foreign_place_travel_check_in(
  p_lat        double precision,
  p_lng        double precision,
  p_site_id    bigint,
  p_note       text default null,
  p_photo_path text default null,
  p_reason     text default null
) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  me  public.profiles := public._require_active();
  s   public.sites;
  g   record;
  res jsonb;
  v_att bigint;
begin
  if not (me.travel_access and me.site_employee) then
    raise exception 'Site travel attendance is not enabled for your account';
  end if;
  if p_site_id is null then
    raise exception 'Select the foreign site / location first';
  end if;
  select * into s from public.sites where id = p_site_id and active;
  if s.id is null then
    raise exception 'This site is not active. Select another site';
  end if;
  if public._is_office_site(p_site_id) then
    raise exception 'Choose a work site. The office location is not a foreign location';
  end if;
  if nullif(trim(p_reason), '') is null then
    raise exception 'Give the reason for the Foreign Location attendance';
  end if;
  if p_lat is null or p_lng is null then
    raise exception 'Location is required. Turn on location and try again';
  end if;
  if p_photo_path is null or split_part(p_photo_path, '/', 1) <> me.id::text then
    raise exception 'Take a live selfie first';
  end if;
  select * into g from public._geofence_check(p_site_id, p_lat, p_lng);   -- distance only (no limit)

  res := public.site_travel_check_in(p_lat := p_lat, p_lng := p_lng, p_site_id := p_site_id, p_site_name := g.site_name,
                                     p_note := p_note, p_photo_path := p_photo_path);

  perform set_config('app.travel_rpc', 'on', true);
  select id into v_att from public.attendance where user_id = me.id and work_date = public.ist_now()::date;
  update public.attendance_legs set place_type = 'Foreign Location'
   where id = (select l.id from public.attendance_legs l where l.attendance_id = v_att order by l.leg desc limit 1);
  update public.selfie_records
     set place_type = 'Foreign Location', reason = trim(p_reason), photo_path = p_photo_path, outside = false
   where id = (select r.id from public.selfie_records r where r.attendance_id = v_att and r.kind = 'IN' and r.user_id = me.id order by r.id desc limit 1);
  update public.foreign_events set reason = trim(p_reason), photo_path = p_photo_path
   where id = (select e.id from public.foreign_events e where e.attendance_id = v_att and e.kind = 'CHECK_IN' order by e.id desc limit 1);
  perform public._audit('FOREIGN_PLACE_TRAVEL_CHECK_IN', s.name || ' (' || coalesce(g.distance_m::text, '?') || ' m from the site point): ' || trim(p_reason));
  return res;
end $$;

create or replace function public.foreign_place_travel_check_out(
  p_lat        double precision,
  p_lng        double precision,
  p_note       text default null,
  p_photo_path text default null,
  p_reason     text default null
) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  me  public.profiles := public._require_active();
  lg  public.attendance_legs;
  s   public.sites;
  g   record;
  res jsonb;
begin
  if not (me.travel_access and me.site_employee) then
    raise exception 'Site travel attendance is not enabled for your account';
  end if;
  select * into lg from public.attendance_legs
   where user_id = me.id and work_date = public.ist_now()::date and out_at is null
   order by leg desc limit 1;
  if lg.id is null then
    raise exception 'No check-in to close. Check in first';
  end if;
  if lg.place_type is distinct from 'Foreign Location' or lg.site_id is null then
    raise exception 'This stop was not a Foreign Location check-in';
  end if;
  if nullif(trim(p_reason), '') is null then
    raise exception 'Give the reason for the Foreign Location attendance';
  end if;
  if p_lat is null or p_lng is null then
    raise exception 'Location is required. Turn on location and try again';
  end if;
  if p_photo_path is null or split_part(p_photo_path, '/', 1) <> me.id::text then
    raise exception 'Take a live selfie first';
  end if;
  if exists (select 1 from public.selfie_records where attendance_id = lg.attendance_id and photo_path = p_photo_path) then
    raise exception 'Check-out needs a new selfie, different from the check-in selfie';
  end if;
  select * into s from public.sites where id = lg.site_id;
  select * into g from public._geofence_check(lg.site_id, p_lat, p_lng);   -- distance only (no limit)

  res := public.site_travel_check_out(p_lat := p_lat, p_lng := p_lng, p_note := p_note, p_photo_path := p_photo_path, p_reason := trim(p_reason));

  update public.selfie_records
     set place_type = 'Foreign Location', reason = trim(p_reason), photo_path = p_photo_path, outside = false
   where id = (select r.id from public.selfie_records r where r.attendance_id = lg.attendance_id and r.kind = 'OUT' and r.user_id = me.id order by r.id desc limit 1);
  update public.foreign_events set reason = trim(p_reason), photo_path = p_photo_path
   where id = (select e.id from public.foreign_events e where e.attendance_id = lg.attendance_id and e.kind = 'CHECK_OUT' order by e.id desc limit 1);
  perform public._audit('FOREIGN_PLACE_TRAVEL_CHECK_OUT', coalesce(s.name, g.site_name) || ' (' || coalesce(g.distance_m::text, '?') || ' m from the site point): ' || trim(p_reason));
  return res;
end $$;

revoke all on function public.foreign_place_check_in(double precision, double precision, bigint, text, text, text)        from public, anon;
revoke all on function public.foreign_place_check_out(double precision, double precision, text, text, text)              from public, anon;
revoke all on function public.foreign_place_travel_check_in(double precision, double precision, bigint, text, text, text) from public, anon;
revoke all on function public.foreign_place_travel_check_out(double precision, double precision, text, text, text)       from public, anon;
grant execute on function public.foreign_place_check_in(double precision, double precision, bigint, text, text, text)        to authenticated;
grant execute on function public.foreign_place_check_out(double precision, double precision, text, text, text)              to authenticated;
grant execute on function public.foreign_place_travel_check_in(double precision, double precision, bigint, text, text, text) to authenticated;
grant execute on function public.foreign_place_travel_check_out(double precision, double precision, text, text, text)       to authenticated;

notify pgrst, 'reload schema';

-- =====================================================================
-- CHECK (read only): the last Foreign Location records
-- select s.captured_at, s.kind, s.site_name, s.distance_m, s.reason, s.place_type from public.selfie_records s
--  where s.place_type = 'Foreign Location' order by s.id desc limit 20;
-- =====================================================================
