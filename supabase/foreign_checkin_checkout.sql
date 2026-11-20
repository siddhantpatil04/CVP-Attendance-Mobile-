-- =====================================================================
-- FOREIGN LOCATION CHECK-IN AND CHECK-OUT
--   * An employee whose "Field Site & Foreign Location Access" switch is ON can check in AND check out from ANY place.
--   * When the place is a foreign location (away from the site / office) the employee must give a REASON and send a SELFIE.
--   * Nothing is approved: the check-in / check-out is saved at once and goes to the attendance reports.
--   * Every foreign check-in / check-out is also listed in the Foreign Register (needs multisite_field_visit.sql).
--   * Employees without the switch work exactly as before.
-- Run AFTER cvp_attendance_schema.sql and multisite_field_visit.sql, in Supabase SQL Editor.  Safe to run again.
-- Take a database backup first.
-- =====================================================================

alter table public.attendance add column if not exists check_in_reason text;
alter table public.attendance add column if not exists check_out_reason text;

-- selfies of a foreign check-in / check-out may be uploaded by anyone with the switch on
drop policy if exists selfies_upload_foreign on storage.objects;
create policy selfies_upload_foreign on storage.objects for insert to authenticated
  with check (
    bucket_id = 'selfies'
    and (storage.foldername(name))[1] = auth.uid()::text
    and exists (select 1 from public.profiles p where p.id = auth.uid() and p.active and p.wide_site_access)
  );

-- ---------------------------------------------------------------------
-- check_in: new optional p_reason. A reason + selfie = foreign location check-in.
-- ---------------------------------------------------------------------
drop function if exists public.check_in(double precision, double precision, text, text, text, bigint);
drop function if exists private.check_in(double precision, double precision, text, text, text, bigint);

create or replace function private.check_in(
  p_lat        double precision default null,
  p_lng        double precision default null,
  p_site_name  text default null,
  p_note       text default null,
  p_photo_path text default null,
  p_site_id    bigint default null,
  p_reason     text default null
) returns public.attendance
language plpgsql security definer set search_path = public as $$
declare
  me        public.profiles := public._require_active();
  v_site    boolean := me.site_employee and not public._is_office_site(p_site_id);
  v_now     timestamp := public.ist_now();
  v_outside boolean := false;
  v_foreign boolean := false;
  v_office  text;
  v_od      integer;
  g         record;
  ns        record;
  r         public.attendance;
begin
  if nullif(trim(p_reason), '') is not null then
    -- ---- foreign location check-in ----
    if not me.wide_site_access then
      raise exception 'Foreign location check-in is not enabled for your account. Ask your Admin';
    end if;
    if p_lat is null or p_lng is null then
      raise exception 'Location is required. Turn on location and try again';
    end if;
    if p_photo_path is null or split_part(p_photo_path, '/', 1) <> me.id::text then
      raise exception 'Take a selfie first';
    end if;
    v_foreign := true;
    select s.name as name, round(public._distance_m(p_lat, p_lng, s.lat, s.lng))::int as dist into ns
      from public.sites s where s.active order by public._distance_m(p_lat, p_lng, s.lat, s.lng) limit 1;
    v_od := ns.dist;
    p_site_name := coalesce(nullif(trim(p_site_name), ''), 'Foreign location');
  else
    if not me.site_employee and (p_photo_path is not null or nullif(trim(p_site_name),'') is not null) then
      raise exception 'Site selfie attendance is not enabled for your account';
    end if;

    if v_site then
      if p_lat is null or p_lng is null then
        raise exception 'Location is required. Turn on location and try again';
      end if;
      select * into g from public._geofence_check(p_site_id, p_lat, p_lng);
      v_outside := not g.inside;
      p_site_name := coalesce(g.site_name, p_site_name);
      if nullif(trim(p_site_name),'') is null then
        raise exception 'Enter the site / project name before submitting';
      end if;
      if v_outside then
        p_photo_path := null;
      elsif p_photo_path is null or split_part(p_photo_path, '/', 1) <> me.id::text then
        raise exception 'Take a selfie first';
      end if;
    else
      -- office employee: no selfie, but only at the office location
      select o.site_name, o.distance_m into v_office, v_od from public._office_check(me.id, p_lat, p_lng) o;
    end if;
  end if;

  insert into public.attendance (user_id, work_date, check_in_at, is_late, source,
                                 site_name, note, check_in_lat, check_in_lng, check_in_dist_m, check_in_reason)
  values (me.id, v_now::date, now(),
          date_trunc('minute', v_now)::time > me.shift_start,
          case when v_site or v_foreign then 'site' else 'office' end,
          nullif(trim(coalesce(p_site_name, v_office)),''), nullif(trim(p_note),''), p_lat, p_lng, v_od,
          case when v_foreign then trim(p_reason) end)
  on conflict (user_id, work_date) do nothing
  returning * into r;

  if r.id is null then
    raise exception 'You have already checked in today';
  end if;

  if v_foreign then
    insert into public.selfie_records (user_id, attendance_id, kind, site_name, note, photo_path, lat, lng, outside, distance_m, foreign_loc, reason)
    values (me.id, r.id, 'IN', trim(p_site_name), nullif(trim(p_note),''), p_photo_path, p_lat, p_lng, false, v_od, true, trim(p_reason));
    perform public._audit('CHECK_IN_FOREIGN', trim(p_site_name) || ' (' || coalesce(v_od::text, '?') || ' m from ' || coalesce(ns.name, 'any site') || '): ' || trim(p_reason));
  elsif v_site then
    insert into public.selfie_records (user_id, attendance_id, kind, site_name, note, photo_path, lat, lng, outside, distance_m)
    values (me.id, r.id, 'IN', trim(p_site_name), nullif(trim(p_note),''), p_photo_path, p_lat, p_lng, v_outside, g.distance_m);
    perform public._audit(case when v_outside then 'SITE_CHECK_IN_OUTSIDE' else 'SITE_SELFIE_CHECK_IN' end,
      trim(p_site_name) || case when v_outside then ' (' || coalesce(g.distance_m::text, '?') || ' m away)' else '' end);
  else
    perform public._audit('CHECK_IN', to_char(v_now, 'HH24:MI') || coalesce(' at ' || v_office || ' (' || v_od || ' m from the office point)', ''));
  end if;
  return r;
end $$;

revoke all on function private.check_in(double precision, double precision, text, text, text, bigint, text) from public, anon;
grant execute on function private.check_in(double precision, double precision, text, text, text, bigint, text) to authenticated;

create or replace function public.check_in(
  p_lat        double precision default null,
  p_lng        double precision default null,
  p_site_name  text default null,
  p_note       text default null,
  p_photo_path text default null,
  p_site_id    bigint default null,
  p_reason     text default null
) returns public.attendance
language sql volatile security invoker set search_path = public as $$
  select * from private.check_in(p_lat, p_lng, p_site_name, p_note, p_photo_path, p_site_id, p_reason)
$$;
revoke all on function public.check_in(double precision, double precision, text, text, text, bigint, text) from public, anon;
grant execute on function public.check_in(double precision, double precision, text, text, text, bigint, text) to authenticated;

-- ---------------------------------------------------------------------
-- check_out: an office employee with the switch can also check out from a foreign location (reason + selfie)
-- ---------------------------------------------------------------------
create or replace function private.check_out(
  p_lat        double precision default null,
  p_lng        double precision default null,
  p_site_name  text default null,
  p_note       text default null,
  p_photo_path text default null,
  p_site_id    bigint default null,
  p_reason     text default null
) returns public.attendance
language plpgsql security definer set search_path = public as $$
declare
  me        public.profiles := public._require_active();
  v_site    boolean := me.site_employee and not public._is_office_site(p_site_id);
  v_now     timestamp := public.ist_now();
  v_outside boolean := false;
  v_foreign boolean := false;
  v_off_for boolean := false;      -- foreign check-out made by a person who is not on the site flow
  v_office  text;
  v_od      integer;
  g         record;
  ns        record;
  r         public.attendance;
begin
  select * into r from public.attendance
   where user_id = me.id and work_date = v_now::date
   for update;

  if r.id is null or r.check_in_at is null then
    raise exception 'You have not checked in today';
  end if;
  if r.check_out_at is not null then
    raise exception 'You have already checked out today';
  end if;

  if v_site then
    if p_lat is null or p_lng is null then
      raise exception 'Location is required. Turn on location and try again';
    end if;
    select * into g from public._geofence_check(p_site_id, p_lat, p_lng);
    v_outside := not g.inside;
    if me.wide_site_access and v_outside then       -- foreign location: allowed, with a selfie and a reason
      v_foreign := true; v_outside := false;
      if nullif(trim(p_reason),'') is null then
        raise exception 'Give the reason for checking out from another (foreign) location';
      end if;
    end if;
    v_od := g.distance_m;
    p_site_name := coalesce(g.site_name, p_site_name);
    if nullif(trim(p_site_name),'') is null then
      raise exception 'Enter the site / project name before submitting';
    end if;
    if v_outside then
      p_photo_path := null;
    else
      if p_photo_path is null or split_part(p_photo_path, '/', 1) <> me.id::text then
        raise exception 'Take a selfie first';
      end if;
      if exists (select 1 from public.selfie_records
                  where attendance_id = r.id and photo_path = p_photo_path) then
        raise exception 'Check-out needs a new selfie, different from the check-in selfie';
      end if;
    end if;
  elsif nullif(trim(p_reason), '') is not null then
    -- ---- foreign location check-out of an office employee ----
    if not me.wide_site_access then
      raise exception 'Foreign location check-out is not enabled for your account. Ask your Admin';
    end if;
    if p_lat is null or p_lng is null then
      raise exception 'Location is required. Turn on location and try again';
    end if;
    if p_photo_path is null or split_part(p_photo_path, '/', 1) <> me.id::text then
      raise exception 'Take a selfie first';
    end if;
    if exists (select 1 from public.selfie_records where attendance_id = r.id and photo_path = p_photo_path) then
      raise exception 'Check-out needs a new selfie, different from the check-in selfie';
    end if;
    v_foreign := true; v_off_for := true;
    select s.name as name, round(public._distance_m(p_lat, p_lng, s.lat, s.lng))::int as dist into ns
      from public.sites s where s.active order by public._distance_m(p_lat, p_lng, s.lat, s.lng) limit 1;
    v_od := ns.dist;
    p_site_name := coalesce(nullif(trim(p_site_name), ''), 'Foreign location');
  else
    if not me.site_employee and (p_photo_path is not null or nullif(trim(p_site_name),'') is not null) then
      raise exception 'Site selfie attendance is not enabled for your account';
    end if;
    select o.site_name, o.distance_m into v_office, v_od from public._office_check(me.id, p_lat, p_lng) o;
  end if;

  update public.attendance
     set check_out_at  = now(),
         check_out_lat = p_lat,
         check_out_lng = p_lng,
         check_out_dist_m = v_od,
         check_out_reason = case when v_foreign then trim(p_reason) else null end,
         note          = coalesce(nullif(trim(p_note),''), note)
   where id = r.id
  returning * into r;

  if v_off_for then
    insert into public.selfie_records (user_id, attendance_id, kind, site_name, note, photo_path, lat, lng, outside, distance_m, foreign_loc, reason)
    values (me.id, r.id, 'OUT', trim(p_site_name), nullif(trim(p_note),''), p_photo_path, p_lat, p_lng, false, v_od, true, trim(p_reason));
    perform public._audit('CHECK_OUT_FOREIGN', trim(p_site_name) || ' (' || coalesce(v_od::text, '?') || ' m from ' || coalesce(ns.name, 'any site') || '): ' || trim(p_reason));
  elsif v_site then
    insert into public.selfie_records (user_id, attendance_id, kind, site_name, note, photo_path, lat, lng, outside, distance_m, foreign_loc, reason)
    values (me.id, r.id, 'OUT', trim(p_site_name), nullif(trim(p_note),''), p_photo_path, p_lat, p_lng, v_outside, g.distance_m,
            v_foreign, case when v_foreign then trim(p_reason) else null end);
    perform public._audit(case when v_outside then 'SITE_CHECK_OUT_OUTSIDE'
                               when v_foreign then 'SITE_CHECK_OUT_FOREIGN' else 'SITE_SELFIE_CHECK_OUT' end,
      trim(p_site_name) || case when v_outside then ' (' || coalesce(g.distance_m::text, '?') || ' m away)'
                                when v_foreign then ' (foreign location, ' || coalesce(g.distance_m::text, '?') || ' m from the site): ' || trim(p_reason) else '' end);
  else
    perform public._audit('CHECK_OUT', to_char(v_now, 'HH24:MI') || coalesce(' at ' || v_office || ' (' || v_od || ' m from the office point)', ''));
  end if;
  return r;
end $$;

revoke all on function private.check_out(double precision, double precision, text, text, text, bigint, text) from public, anon;
grant execute on function private.check_out(double precision, double precision, text, text, text, bigint, text) to authenticated;

create or replace function public.check_out(
  p_lat        double precision default null,
  p_lng        double precision default null,
  p_site_name  text default null,
  p_note       text default null,
  p_photo_path text default null,
  p_site_id    bigint default null,
  p_reason     text default null
) returns public.attendance
language sql volatile security invoker set search_path = public as $$
  select * from private.check_out(p_lat, p_lng, p_site_name, p_note, p_photo_path, p_site_id, p_reason)
$$;
revoke all on function public.check_out(double precision, double precision, text, text, text, bigint, text) from public, anon;
grant execute on function public.check_out(double precision, double precision, text, text, text, bigint, text) to authenticated;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------
-- What Admin / HR see: the place of every foreign check-in / check-out (GPS, reason, selfie) in the Foreign Register,
-- and the check-in / check-out position and reason in the Daily Attendance report.
-- ---------------------------------------------------------------------
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
          coalesce(nullif(trim(new.note), ''),
                   case when new.site_name = 'Foreign location' then 'Foreign location' else 'Outside ' || new.site_name end),
          new.captured_at, new.lat, new.lng, new.distance_m, new.site_name, new.reason, new.photo_path, new.attendance_id);
  if new.kind = 'OUT' and new.attendance_id is not null then
    update public.attendance set checkout_place = new.site_name where id = new.attendance_id;
  end if;
  return new;
end $$;
revoke execute on function public._fv_selfie_to_foreign() from public, anon, authenticated;

-- A view that already exists with other columns cannot be changed by CREATE OR REPLACE (error 42P16): drop it first (views hold no data)
drop view if exists public.v_daily_attendance;

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
         where x.s <> '') as sites_visited,
       a.check_in_lat, a.check_in_lng, a.check_out_lat, a.check_out_lng, a.check_in_reason, a.check_out_reason
  from public.attendance a
  join public.profiles p on p.id = a.user_id;
grant select on public.v_daily_attendance to authenticated;

notify pgrst, 'reload schema';