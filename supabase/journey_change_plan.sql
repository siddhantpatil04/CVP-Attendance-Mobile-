-- =====================================================================
-- FIELD SITE JOURNEY: "CHANGE PLAN"
--
-- After "Start Visit" (From site A -> To site B) the employee can, while "On the way":
--   * go back to the start site (A),  * go to another site (C) instead of B,  * or cancel the visit.
-- No approval, no limit on the number of changes. Admin / HR can see every change (view only).
-- No reason or remarks are asked in the app (an optional one is stored if sent, otherwise 'Not given').
--
-- ONE small, additive file.  Safe to run again.  No safety lock.  No table is dropped and no data is deleted.
-- Do NOT edit or run cvp_attendance_schema.sql for this.   BACK UP THE DATABASE FIRST.
-- Run AFTER field_site_journeys.sql (the existing journey feature).  Supabase -> SQL Editor -> paste the WHOLE file -> Run.
--
-- HOW IT IS STORED
--   * field_site_journeys.to_site_id always holds the CURRENT destination, so "Reached Site" (same GPS check as before),
--     the next journey ("start from the last reached site") and every report keep working with no other change.
--   * Every change is a new row in journey_plan_changes (old destination, new destination, reason, remarks, change point GPS,
--     time, distance so far). Rows can be added only through change_journey_plan(); nobody can edit or delete them.
--   * The change point is also saved as a GPS point of the journey, so the distance keeps counting
--     start -> change point -> new site; distance already travelled is never lost.
--   * Cancel = the journey ends with status 'cancelled', the distance up to that point is kept, and a new visit can start.
-- =====================================================================

-- 1. field_site_journeys: allow 'cancelled', and allow going back to the start site ------------------------------
do $$
declare c record;
begin
  for c in
    select conname from pg_constraint
     where conrelid = 'public.field_site_journeys'::regclass and contype = 'c'
       and (pg_get_constraintdef(oid) ilike '%from_site_id <> to_site_id%'                       -- going back to the start site is now allowed
            or (pg_get_constraintdef(oid) ilike '%status%' and pg_get_constraintdef(oid) ilike '%travelling%'))
  loop
    execute format('alter table public.field_site_journeys drop constraint %I', c.conname);
  end loop;
end $$;
alter table public.field_site_journeys
  add constraint field_site_journeys_status_check2 check (status in ('travelling', 'reached', 'cancelled'));

alter table public.field_site_journeys add column if not exists plan_change_count  integer not null default 0;
alter table public.field_site_journeys add column if not exists original_to_site_id bigint references public.sites(id);
alter table public.field_site_journeys add column if not exists cancelled_time     timestamptz;
alter table public.field_site_journeys add column if not exists cancelled_lat      double precision;
alter table public.field_site_journeys add column if not exists cancelled_lng      double precision;
alter table public.field_site_journeys add column if not exists cancelled_accuracy integer;

-- a cancelled visit can never be "reached" later (Reached Site itself is unchanged)
create or replace function public._block_cancelled_journey() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.status = 'cancelled' then raise exception 'This visit was cancelled'; end if;
  return new;
end $$;
revoke all on function public._block_cancelled_journey() from public, anon, authenticated;
drop trigger if exists field_site_journeys_block_cancelled on public.field_site_journeys;
create trigger field_site_journeys_block_cancelled before update on public.field_site_journeys
  for each row execute function public._block_cancelled_journey();

-- the report view must show the new columns (same names as before + the new ones)
drop view if exists public.v_field_site_journeys;
create view public.v_field_site_journeys with (security_invoker = true) as
select j.*, p.full_name, p.username as emp_code, fs.name as from_site_name, ts.name as to_site_name
  from public.field_site_journeys j
  join public.profiles p  on p.id  = j.user_id
  join public.sites   fs  on fs.id = j.from_site_id
  join public.sites   ts  on ts.id = j.to_site_id;
grant select on public.v_field_site_journeys to authenticated;

-- 2. Every plan change (append only) -------------------------------------------------------------------------
create table if not exists public.journey_plan_changes (
  id                       bigint generated always as identity primary key,
  journey_id               bigint not null references public.field_site_journeys(id) on delete cascade,
  employee_id              uuid   not null references public.profiles(id) on delete cascade,
  changed_at               timestamptz not null,
  old_destination_site_id  bigint references public.sites(id),
  new_destination_site_id  bigint references public.sites(id),          -- null when the visit was cancelled
  change_type              text not null check (change_type in ('back_to_start', 'other_site', 'cancel')),
  reason                   text not null,
  remarks                  text,
  lat                      double precision,                            -- the change point
  lng                      double precision,
  accuracy_m               integer,
  gps_available            boolean not null default true,               -- false = "GPS not available" (the change is still allowed)
  distance_at_change_km    numeric(8,2),                                -- km travelled until the change point
  client_key               text,                                        -- a retry (offline sync) of the same change is saved only once
  created_at               timestamptz not null default now()
);
create index if not exists journey_plan_changes_journey_idx on public.journey_plan_changes (journey_id, changed_at);
create unique index if not exists journey_plan_changes_key on public.journey_plan_changes (employee_id, client_key) where client_key is not null;

alter table public.journey_plan_changes enable row level security;
drop policy if exists journey_plan_changes_read on public.journey_plan_changes;
create policy journey_plan_changes_read on public.journey_plan_changes for select to authenticated
  using (employee_id = auth.uid()
         or exists (select 1 from public.profiles p where p.id = auth.uid() and p.active and p.role in ('Admin', 'HR')));
-- nobody writes to the table directly (no insert / update / delete): only change_journey_plan() below
revoke all on public.journey_plan_changes from anon;
revoke insert, update, delete on public.journey_plan_changes from authenticated;
grant select on public.journey_plan_changes to authenticated;

-- 3. The change (one function: the change record and the new destination are saved together) ---------------------
create or replace function public.change_journey_plan(
  p_journey     bigint,
  p_change_type text,                                  -- 'back_to_start' | 'other_site' | 'cancel'
  p_new_site    bigint default null,                   -- only for 'other_site'
  p_reason      text default null,
  p_remarks     text default null,
  p_lat         double precision default null,         -- the change point (null = GPS not available)
  p_lng         double precision default null,
  p_accuracy    integer default null,
  p_changed_at  timestamptz default null,              -- the phone sends the ORIGINAL time when it syncs later (offline)
  p_key         text default null
) returns public.field_site_journeys
language plpgsql volatile security definer set search_path = public as $$
declare
  me     public.profiles := public._require_active();
  j      public.field_site_journeys;
  v_new  bigint;
  v_at   timestamptz;
  v_gps  boolean := (p_lat is not null and p_lng is not null);
  v_rsn  text := nullif(trim(coalesce(p_reason, '')), '');
  v_rem  text := nullif(trim(coalesce(p_remarks, '')), '');
  km     numeric;
begin
  if not me.site_employee then
    raise exception 'Field Site Journey is not enabled for your account';
  end if;
  perform pg_advisory_xact_lock(hashtext('fsj:' || me.id::text));

  -- the same change sent again (retry / offline sync): nothing is written twice
  if nullif(trim(p_key), '') is not null
     and exists (select 1 from public.journey_plan_changes c where c.employee_id = me.id and c.client_key = trim(p_key)) then
    select * into j from public.field_site_journeys where id = p_journey and user_id = me.id;
    return j;
  end if;

  -- the journey must be MINE and still running
  select * into j from public.field_site_journeys where id = p_journey and user_id = me.id for update;
  if j.id is null then raise exception 'Journey not found'; end if;
  if j.status <> 'travelling' then raise exception 'This journey is not on the way any more (it was reached or cancelled)'; end if;

  if p_change_type is null or p_change_type not in ('back_to_start', 'other_site', 'cancel') then
    raise exception 'Choose what to do: go back, go to another site, or cancel the visit';
  end if;
  v_rsn := coalesce(v_rsn, 'Not given');   -- the app does not ask for a reason; one may still be sent

  if p_change_type = 'back_to_start' then
    v_new := j.from_site_id;
  elsif p_change_type = 'other_site' then
    v_new := p_new_site;
    if v_new is null then raise exception 'Select the new site'; end if;
    if not exists (select 1 from public.sites where id = v_new and active) then raise exception 'Select an active work site'; end if;
  end if;
  if v_new is not null and v_new = j.to_site_id then
    raise exception 'The new destination must be different from the current destination';
  end if;

  -- never before the start, never in the future
  v_at := least(greatest(coalesce(p_changed_at, now()), j.start_time), now());

  -- km travelled until the change point: start -> recorded points -> change point (same method as Reached Site)
  select coalesce(sum(public._distance_m(y.plat, y.plng, y.lat, y.lng)), 0) / 1000.0 into km
    from (select x.lat, x.lng, lag(x.lat) over w as plat, lag(x.lng) over w as plng
            from (select 0 as ord, j.start_time as t, j.start_lat as lat, j.start_lng as lng
                  union all
                  select 1, pt.recorded_at, pt.lat, pt.lng
                    from public.field_site_journey_points pt where pt.journey_id = j.id and pt.recorded_at <= v_at
                  union all
                  select 2, v_at, p_lat, p_lng where v_gps) x
          window w as (order by x.ord, x.t)) y
   where y.plat is not null;

  -- the change point becomes a GPS point of the journey, so the distance keeps counting through it
  if v_gps then
    insert into public.field_site_journey_points (journey_id, user_id, recorded_at, lat, lng, accuracy)
    values (j.id, me.id, v_at, p_lat, p_lng, p_accuracy);
  end if;

  insert into public.journey_plan_changes
    (journey_id, employee_id, changed_at, old_destination_site_id, new_destination_site_id, change_type,
     reason, remarks, lat, lng, accuracy_m, gps_available, distance_at_change_km, client_key)
  values
    (j.id, me.id, v_at, j.to_site_id, v_new, p_change_type, v_rsn, v_rem,
     p_lat, p_lng, p_accuracy, v_gps, round(km, 2), nullif(trim(p_key), ''));

  if p_change_type = 'cancel' then
    update public.field_site_journeys
       set status = 'cancelled', cancelled_time = v_at, cancelled_lat = p_lat, cancelled_lng = p_lng, cancelled_accuracy = p_accuracy,
           distance_km = round(km, 2),
           duration_minutes = greatest(0, round(extract(epoch from (v_at - j.start_time)) / 60.0)::int),
           plan_change_count = plan_change_count + 1,
           original_to_site_id = coalesce(original_to_site_id, j.to_site_id)
     where id = j.id
    returning * into j;
  else
    update public.field_site_journeys
       set to_site_id = v_new,
           plan_change_count = plan_change_count + 1,
           original_to_site_id = coalesce(original_to_site_id, j.to_site_id)
     where id = j.id
    returning * into j;
  end if;

  perform public._audit('FIELD_JOURNEY_PLAN_CHANGE', 'journey ' || j.seq_no || ' ' || p_change_type || ': ' || v_rsn
    || case when v_new is not null then ' -> ' || (select name from public.sites where id = v_new) else '' end);
  return j;
end $$;

revoke all on function public.change_journey_plan(bigint, text, bigint, text, text, double precision, double precision, integer, timestamptz, text) from public, anon;
grant execute on function public.change_journey_plan(bigint, text, bigint, text, text, double precision, double precision, integer, timestamptz, text) to authenticated;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------
-- UNDO (only if needed; no data is deleted):
--   revoke execute on function public.change_journey_plan(bigint, text, bigint, text, text, double precision, double precision, integer, timestamptz, text) from authenticated;
-- ---------------------------------------------------------------------
