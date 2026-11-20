-- =====================================================================
-- FIELD SITE JOURNEY (multi-site travel tracking)  -  replaces the old Field Site Journey workflow
--   * After today's attendance check-in the employee starts a journey From site -> To site ("Start Visit"),
--     travels (GPS points are recorded) and taps "Reached Site". Any number of journeys a day, the same site may repeat.
--   * Everything is set by the SERVER: user, times, duration and distance. No approval / rejection / pending status.
--   * One 'travelling' journey per employee at a time (partial unique index); a repeated tap (same key) or a second
--     device never creates a second journey and never completes a journey twice.
--   * Reached only inside the destination site's allowed radius ("You are <n> km from <site>" otherwise).
--   * Distance = the recorded GPS points (start -> points -> arrival); start-to-arrival straight line only if there are no points.
--   * A journey that is never reached stays 'travelling' (shown as "Not reached" in reports for past days); nothing is auto-completed.
--   * ADDITIVE ONLY: new tables, one view and three functions. The old journey tables (field_journeys ...) are kept as read-only history,
--     attendance, Site Selfie, working hours, leave and salary are not touched.
-- Run AFTER cvp_attendance_schema.sql, in Supabase SQL Editor.  Safe to run again.
-- Take a database backup first (and try it on a staging copy).
-- =====================================================================

create table if not exists public.field_site_journeys (
  id                bigint generated always as identity primary key,
  user_id           uuid   not null references public.profiles(id) on delete cascade,
  journey_date      date   not null,
  seq_no            integer not null,
  from_site_id      bigint not null references public.sites(id),
  to_site_id        bigint not null references public.sites(id),
  start_time        timestamptz not null default now(),
  start_lat         double precision not null,
  start_lng         double precision not null,
  start_accuracy    integer,
  reached_time      timestamptz,
  reached_lat       double precision,
  reached_lng       double precision,
  reached_accuracy  integer,
  distance_km       numeric(8,2),
  duration_minutes  integer,
  status            text not null default 'travelling' check (status in ('travelling', 'reached')),
  start_key         text,                         -- repeated tap / retry of the same Start returns the same journey
  created_at        timestamptz not null default now(),
  check (from_site_id <> to_site_id),
  unique (user_id, journey_date, seq_no)
);
create unique index if not exists field_site_journeys_one_running on public.field_site_journeys (user_id) where status = 'travelling';
create unique index if not exists field_site_journeys_start_key  on public.field_site_journeys (user_id, start_key) where start_key is not null;
create index if not exists field_site_journeys_date_idx on public.field_site_journeys (journey_date desc, user_id);

create table if not exists public.field_site_journey_points (
  id          bigint generated always as identity primary key,
  journey_id  bigint not null references public.field_site_journeys(id) on delete cascade,
  user_id     uuid   not null references public.profiles(id) on delete cascade,
  recorded_at timestamptz not null,
  lat         double precision not null,
  lng         double precision not null,
  accuracy    integer
);
create index if not exists field_site_journey_points_idx on public.field_site_journey_points (journey_id, recorded_at);

-- ---------------------------------------------------------------------
-- Row level security: read only. Employee = own journeys; Admin / HR = all. Writes only through the functions below.
-- ---------------------------------------------------------------------
alter table public.field_site_journeys       enable row level security;
alter table public.field_site_journey_points enable row level security;

drop policy if exists field_site_journeys_read on public.field_site_journeys;
create policy field_site_journeys_read on public.field_site_journeys for select to authenticated
  using (user_id = auth.uid() or public.is_staff_admin());
drop policy if exists field_site_journey_points_read on public.field_site_journey_points;
create policy field_site_journey_points_read on public.field_site_journey_points for select to authenticated
  using (user_id = auth.uid() or public.is_staff_admin());

revoke insert, update, delete on public.field_site_journeys, public.field_site_journey_points from anon, authenticated;
grant select on public.field_site_journeys, public.field_site_journey_points to authenticated;

-- report view (names of the employee and the sites); the table's RLS still applies (security_invoker)
drop view if exists public.v_field_site_journeys;
create view public.v_field_site_journeys with (security_invoker = true) as
select j.*, p.full_name, p.username as emp_code, fs.name as from_site_name, ts.name as to_site_name
  from public.field_site_journeys j
  join public.profiles p  on p.id  = j.user_id
  join public.sites   fs  on fs.id = j.from_site_id
  join public.sites   ts  on ts.id = j.to_site_id;
grant select on public.v_field_site_journeys to authenticated;

-- ---------------------------------------------------------------------
-- Start Visit
-- ---------------------------------------------------------------------
create or replace function public.start_field_journey(
  p_from_site bigint,
  p_to_site   bigint,
  p_lat       double precision,
  p_lng       double precision,
  p_accuracy  integer default null,
  p_key       text default null
) returns public.field_site_journeys
language plpgsql volatile security definer set search_path = public as $$
declare
  me   public.profiles := public._require_active();
  v_today date := public.ist_today();
  a    public.attendance;
  prev public.field_site_journeys;
  r    public.field_site_journeys;
  v_from bigint := p_from_site;
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

  -- later journeys always start from the last reached site
  select * into prev from public.field_site_journeys
   where user_id = me.id and journey_date = v_today and status = 'reached' order by seq_no desc limit 1;
  if prev.id is not null then
    v_from := prev.to_site_id;
  elsif v_from is null then
    select s.id into v_from from public.sites s where s.name = a.site_name and s.active limit 1;
  end if;
  if v_from is null then raise exception 'Select the current site (From location)'; end if;
  if p_to_site is null then raise exception 'Select the going site (To location)'; end if;
  if v_from = p_to_site then raise exception 'The going site must be different from the current site'; end if;
  if not exists (select 1 from public.sites where id = v_from and active)
     or not exists (select 1 from public.sites where id = p_to_site and active) then
    raise exception 'Select an active work site';
  end if;

  insert into public.field_site_journeys (user_id, journey_date, seq_no, from_site_id, to_site_id,
                                          start_time, start_lat, start_lng, start_accuracy, start_key)
  values (me.id, v_today,
          coalesce((select max(seq_no) from public.field_site_journeys where user_id = me.id and journey_date = v_today), 0) + 1,
          v_from, p_to_site, now(), p_lat, p_lng, p_accuracy, nullif(trim(p_key), ''))
  returning * into r;

  perform public._audit('FIELD_JOURNEY_START', 'journey ' || r.seq_no || ' ' ||
    (select name from public.sites where id = v_from) || ' > ' || (select name from public.sites where id = p_to_site));
  return r;
end $$;

-- ---------------------------------------------------------------------
-- GPS points while travelling (also used to sync points recorded offline)
--   p_points = [{"lat":..,"lng":..,"acc":..,"t":"2026-10-31T10:20:00Z"}, ...]
-- ---------------------------------------------------------------------
create or replace function public.add_field_journey_points(p_journey bigint, p_points jsonb)
returns integer
language plpgsql volatile security definer set search_path = public as $$
declare
  me public.profiles := public._require_active();
  j  public.field_site_journeys;
  n  integer;
begin
  select * into j from public.field_site_journeys where id = p_journey and user_id = me.id;
  if j.id is null then raise exception 'Journey not found'; end if;
  if j.status <> 'travelling' then return 0; end if;
  insert into public.field_site_journey_points (journey_id, user_id, recorded_at, lat, lng, accuracy)
  select j.id, me.id,
         least(greatest(coalesce((x->>'t')::timestamptz, now()), j.start_time), now()),
         (x->>'lat')::double precision, (x->>'lng')::double precision, nullif(x->>'acc', '')::numeric::integer
    from jsonb_array_elements(coalesce(p_points, '[]'::jsonb)) x
   where x->>'lat' is not null and x->>'lng' is not null;
  get diagnostics n = row_count;
  return n;
end $$;

-- ---------------------------------------------------------------------
-- Reached Site
-- ---------------------------------------------------------------------
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
  d := public._distance_m(p_lat, p_lng, s.lat, s.lng);
  if d is null or d > s.radius_m then
    raise exception 'You are % km from %', round((d / 1000.0)::numeric, 1), s.name;
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

  perform public._audit('FIELD_JOURNEY_REACHED', 'journey ' || j.seq_no || ' reached ' || s.name || ' (' || j.distance_km || ' km, ' || j.duration_minutes || ' min)');
  return j;
end $$;

revoke all on function public.start_field_journey(bigint, bigint, double precision, double precision, integer, text) from public, anon;
revoke all on function public.add_field_journey_points(bigint, jsonb)                                          from public, anon;
revoke all on function public.reach_field_journey(bigint, double precision, double precision, integer)         from public, anon;
grant execute on function public.start_field_journey(bigint, bigint, double precision, double precision, integer, text) to authenticated;
grant execute on function public.add_field_journey_points(bigint, jsonb)                                          to authenticated;
grant execute on function public.reach_field_journey(bigint, double precision, double precision, integer)         to authenticated;

notify pgrst, 'reload schema';
