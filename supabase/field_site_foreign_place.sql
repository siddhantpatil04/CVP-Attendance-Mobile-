-- =====================================================================
-- FIELD SITE: "FOREIGN LOCATION" AS THE GOING SITE (the employee types the name of the place he is going to)
--
-- Run AFTER field_site_journeys.sql and journey_change_plan.sql.  ONE additive file.  Safe to run again.
-- No safety lock.  No table is dropped and no data is deleted.  BACK UP THE DATABASE FIRST.
-- Supabase -> SQL Editor -> paste the WHOLE file -> Run.
--
-- HOW IT WORKS
--  * In "Going site (To location)" the employee can choose "Foreign location" and write the NAME of the place (not a saved work site).
--  * The journey points at one hidden site row named "Foreign location" (inactive, so it never shows in site lists) and the typed
--    name is stored in field_site_journeys.to_place_name.  The next journey starts from that place (from_place_name).
--  * Reached Site on a foreign place has no radius check (there is no saved point): the GPS position where he taps Reached Site is saved.
--  * Reports show the typed name instead of "Foreign location" (view v_field_site_journeys: from_site_name / to_site_name).
--  * A plan change to a saved site clears the typed name (trigger below).
--  * Normal journeys between saved work sites work exactly as before.
-- =====================================================================

-- 1. The hidden placeholder site ---------------------------------------------------------------------------------------
insert into public.sites (name, lat, lng, radius_m, active)
values ('Foreign location', 0, 0, 20, false)
on conflict (name) do nothing;

-- 2. Where the typed names are kept -----------------------------------------------------------------------------------------
alter table public.field_site_journeys add column if not exists from_place_name text;
alter table public.field_site_journeys add column if not exists to_place_name   text;

-- the report view shows the typed place name (same columns as before)
drop view if exists public.v_field_site_journeys;
create view public.v_field_site_journeys with (security_invoker = true) as
select j.*, p.full_name, p.username as emp_code,
       coalesce(nullif(trim(j.from_place_name), ''), fs.name) as from_site_name,
       coalesce(nullif(trim(j.to_place_name), ''), ts.name)   as to_site_name
  from public.field_site_journeys j
  join public.profiles p  on p.id  = j.user_id
  join public.sites   fs  on fs.id = j.from_site_id
  join public.sites   ts  on ts.id = j.to_site_id;
grant select on public.v_field_site_journeys to authenticated;

-- when the destination is changed (Change plan): going back to the start place keeps ITS name, any saved site clears the typed name
create or replace function public._journey_foreign_reset() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.to_site_id is distinct from old.to_site_id then
    new.to_place_name := case when new.to_site_id = new.from_site_id then new.from_place_name else null end;
  end if;
  return new;
end $$;
revoke all on function public._journey_foreign_reset() from public, anon, authenticated;
drop trigger if exists field_site_journeys_foreign_reset on public.field_site_journeys;
create trigger field_site_journeys_foreign_reset before update on public.field_site_journeys
  for each row execute function public._journey_foreign_reset();

-- 3. Start Visit: a saved site OR a typed foreign place ------------------------------------------------------------------------
drop function if exists public.start_field_journey(bigint, bigint, double precision, double precision, integer, text);
create or replace function public.start_field_journey(
  p_from_site bigint,
  p_to_site   bigint,
  p_lat       double precision,
  p_lng       double precision,
  p_accuracy  integer default null,
  p_key       text default null,
  p_foreign_name text default null
) returns public.field_site_journeys
language plpgsql volatile security definer set search_path = public as $$
declare
  me     public.profiles := public._require_active();
  v_today date := public.ist_today();
  v_fid  bigint := (select s.id from public.sites s where s.name = 'Foreign location' limit 1);
  a      public.attendance;
  prev   public.field_site_journeys;
  r      public.field_site_journeys;
  v_from bigint := p_from_site;
  v_from_name text := null;
  v_to   bigint := p_to_site;
  v_to_name text := nullif(trim(coalesce(p_foreign_name, '')), '');
begin
  if not me.site_employee then
    raise exception 'Field Site Journey is not enabled for your account';
  end if;
  perform pg_advisory_xact_lock(hashtext('fsj:' || me.id::text));

  -- a retry of the same tap returns the same journey
  if nullif(trim(p_key), '') is not null then
    select * into r from public.field_site_journeys where user_id = me.id and start_key = trim(p_key);
    if r.id is not null then return r; end if;
  end if;

  if p_lat is null or p_lng is null then
    raise exception 'GPS is not available. Turn on location and try again';
  end if;

  select * into a from public.attendance where user_id = me.id and work_date = v_today;
  if a.id is null or a.check_in_at is null then
    raise exception 'Check in to attendance first. Field Site Journey starts after today''s check-in';
  end if;

  if exists (select 1 from public.field_site_journeys where user_id = me.id and status = 'travelling') then
    raise exception 'A journey is already running. Tap Reached Site first';
  end if;

  -- going to a typed foreign place
  if v_to_name is not null then
    if v_fid is null then raise exception 'Foreign location is not set up. Run field_site_foreign_place.sql'; end if;
    v_to := v_fid;
  elsif p_to_site is null then
    raise exception 'Select the going site (To location)';
  end if;

  -- later journeys always start from the last reached place (a saved site or a typed foreign place)
  select * into prev from public.field_site_journeys
   where user_id = me.id and journey_date = v_today and status = 'reached' order by seq_no desc limit 1;
  if prev.id is not null then
    v_from := prev.to_site_id;
    v_from_name := prev.to_place_name;
  elsif v_from is null then
    select s.id into v_from from public.sites s where s.name = a.site_name and s.active limit 1;
  end if;
  if v_from is null then raise exception 'Select the current site (From location)'; end if;
  if v_to_name is null and v_from = v_to and v_from_name is null then raise exception 'The going site must be different from the current site'; end if;
  if (v_from <> v_fid and not exists (select 1 from public.sites where id = v_from and active))
     or (v_to <> v_fid and not exists (select 1 from public.sites where id = v_to and active)) then
    raise exception 'Select an active work site';
  end if;

  insert into public.field_site_journeys (user_id, journey_date, seq_no, from_site_id, to_site_id, from_place_name, to_place_name,
                                          start_time, start_lat, start_lng, start_accuracy, start_key)
  values (me.id, v_today,
          coalesce((select max(seq_no) from public.field_site_journeys where user_id = me.id and journey_date = v_today), 0) + 1,
          v_from, v_to, v_from_name, v_to_name, now(), p_lat, p_lng, p_accuracy, nullif(trim(p_key), ''))
  returning * into r;

  perform public._audit('FIELD_JOURNEY_START', 'journey ' || r.seq_no || ' ' ||
    coalesce(v_from_name, (select name from public.sites where id = v_from)) || ' > ' ||
    coalesce(v_to_name, (select name from public.sites where id = v_to)));
  return r;
end $$;

-- 4. Reached Site: a foreign place has no radius to check ---------------------------------------------------------------------------
create or replace function public.reach_field_journey(
  p_journey  bigint,
  p_lat      double precision,
  p_lng      double precision,
  p_accuracy integer default null
) returns public.field_site_journeys
language plpgsql volatile security definer set search_path = public as $$
declare
  me public.profiles := public._require_active();
  j  public.field_site_journeys;
  s  public.sites;
  d  double precision;
  km numeric;
begin
  perform pg_advisory_xact_lock(hashtext('fsj:' || me.id::text));
  select * into j from public.field_site_journeys where id = p_journey and user_id = me.id for update;
  if j.id is null then raise exception 'Journey not found'; end if;
  if j.status = 'reached' then return j; end if;     -- second tap / second device: nothing is written again
  if p_lat is null or p_lng is null then
    raise exception 'GPS is not available. Turn on location and try again';
  end if;

  select * into s from public.sites where id = j.to_site_id;
  if nullif(trim(coalesce(j.to_place_name, '')), '') is null then
    -- a saved work site: reached only inside its allowed radius (as before)
    d := public._distance_m(p_lat, p_lng, s.lat, s.lng);
    if d is null or d > s.radius_m then
      raise exception 'You are % km from %', round((d / 1000.0)::numeric, 1), s.name;
    end if;
  end if;

  -- distance along the recorded GPS points (start -> points -> arrival); the straight line only when there are no points
  select coalesce(sum(public._distance_m(y.plat, y.plng, y.lat, y.lng)), 0) / 1000.0 into km
    from (select x.lat, x.lng, lag(x.lat) over w as plat, lag(x.lng) over w as plng
            from (select 0 as ord, j.start_time as t, j.start_lat as lat, j.start_lng as lng
                  union all
                  select 1, pt.recorded_at, pt.lat, pt.lng from public.field_site_journey_points pt where pt.journey_id = j.id
                  union all
                  select 2, now(), p_lat, p_lng) x
          window w as (order by x.ord, x.t)) y
   where y.plat is not null;

  update public.field_site_journeys
     set status = 'reached', reached_time = now(), reached_lat = p_lat, reached_lng = p_lng, reached_accuracy = p_accuracy,
         distance_km = round(km, 2),
         duration_minutes = greatest(0, round(extract(epoch from (now() - j.start_time)) / 60.0)::int)
   where id = j.id
  returning * into j;

  perform public._audit('FIELD_JOURNEY_REACHED', 'journey ' || j.seq_no || ' reached ' || coalesce(nullif(trim(coalesce(j.to_place_name, '')), ''), s.name)
    || ' (' || j.distance_km || ' km, ' || j.duration_minutes || ' min)');
  return j;
end $$;

-- 5. Permissions ----------------------------------------------------------------------------------------------------------------------
revoke all on function public.start_field_journey(bigint, bigint, double precision, double precision, integer, text, text) from public, anon;
revoke all on function public.reach_field_journey(bigint, double precision, double precision, integer)                      from public, anon;
grant execute on function public.start_field_journey(bigint, bigint, double precision, double precision, integer, text, text) to authenticated;
grant execute on function public.reach_field_journey(bigint, double precision, double precision, integer)                      to authenticated;

notify pgrst, 'reload schema';

-- UNDO (nothing is deleted): journeys to a foreign place stay in history.  To stop offering it, the app option is removed in the app.
