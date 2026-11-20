-- =====================================================================
-- SITE SELFIE: ONLY THE EMPLOYEE'S ALLOCATED SITES, NEAREST FIRST (AUTO-SELECTED)
--
-- * Admin / HR allocate sites to each site employee (the existing employee_sites table is reused, no second table).
-- * The phone asks my_sites_near_me(lat, lng) and gets ONLY allocated sites that are INSIDE their allowed radius, nearest first.
--   Far sites, and sites that are not allocated, are never sent to the phone.
-- * Server rules (the app cannot bypass them, an old app version or a direct call is refused too):
--   They apply to CHECK-IN and CHECK-OUT of a site employee (a database trigger on attendance, so it covers every app version):
--     - a site that is not allocated              -> "This site is not allocated to you."
--     - no site allocated at all                  -> "No site is allocated to you. Please contact Admin."
--     - GPS not inside an allocated site's radius -> "You are not at an allocated site."   (distance is calculated again on the server)
--     - CHECK-OUT: the employee may be at ANY allocated site (normally the check-in site); the site he is at is saved as the
--       check-out site (attendance.check_out_site_name).  Admin "Allow once" (Daily Report prompt) also lets a check-out through
--       when he is not near a site; its reason is already in the audit log.
--     - Foreign Location check-ins / check-outs, Field Site Journey travel, Foreign-Location-access (wide site) employees: not affected.
-- * The server counts "check-in blocked today (too far)" for the Admin screen.
--
-- (Only for employees with SELFIE ACCESS and ALLOCATED SITES: a site employee with no allocated site works as before.)  A site is shown / accepted only within 500 m of its point (the site's own radius is used when it is smaller).
-- ONE small, additive file.  Safe to run again.  No safety lock.  No table is dropped and no data is deleted.
-- Do NOT edit or run cvp_attendance_schema.sql for this.   BACK UP THE DATABASE FIRST.
-- Supabase -> SQL Editor -> paste the WHOLE file -> Run.
--
-- Nobody is blocked by this file: an employee with no allocated site works exactly as before.  The rule starts for an employee
-- the moment Admin / HR allocate at least one site to him (Access Control -> Site Access).
-- Optional helper to fill the allocations from past check-ins:
--     step 1 (look only, saves nothing):   select * from public.admin_preview_allocation_from_history(60);
--     step 2 (saves, only if the list is right):   select public.admin_apply_allocation_from_history(60);
-- =====================================================================

-- 1. Allocation table (already exists from "Site access"); only two columns are added -----------------------------------
create table if not exists public.employee_sites (
  user_id  uuid   not null references public.profiles(id) on delete cascade,
  site_id  bigint not null references public.sites(id)    on delete cascade,
  primary key (user_id, site_id)
);
alter table public.employee_sites add column if not exists allocated_by uuid references public.profiles(id) on delete set null default auth.uid();
alter table public.employee_sites add column if not exists allocated_at timestamptz not null default now();
-- RLS stays as it is: an employee reads only his own rows, Admin / HR read all; only admin_set_employee_sites() writes.

-- 2. "Check-in blocked today (too far)" log (written by the server, read by Admin / HR) ----------------------------------
create table if not exists public.checkin_blocked_log (
  id                 bigint generated always as identity primary key,
  user_id            uuid not null references public.profiles(id) on delete cascade,
  log_date           date not null default public.ist_today(),
  logged_at          timestamptz not null default now(),
  lat                double precision,
  lng                double precision,
  nearest_distance_m integer                 -- how far the nearest ALLOCATED site was (only Admin sees it)
);
create index if not exists checkin_blocked_log_idx on public.checkin_blocked_log (log_date, user_id);
alter table public.checkin_blocked_log enable row level security;
drop policy if exists checkin_blocked_log_read on public.checkin_blocked_log;
create policy checkin_blocked_log_read on public.checkin_blocked_log for select to authenticated
  using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.active and p.role in ('Admin', 'HR')));
revoke all on public.checkin_blocked_log from anon;
revoke insert, update, delete on public.checkin_blocked_log from authenticated;
grant select on public.checkin_blocked_log to authenticated;

-- 3. The phone's list: ONLY allocated sites inside their radius, nearest first ----------------------------------------
create or replace function public.my_sites_near_me(p_lat double precision, p_lng double precision)
returns table (site_id bigint, name text, area text, distance_m integer, radius_m integer, lat double precision, lng double precision, is_office boolean)
language plpgsql volatile security definer set search_path = public as $$
#variable_conflict use_column
declare
  me      public.profiles := public._require_active();
  v_near  double precision;
begin
  if p_lat is null or p_lng is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 then
    raise exception 'GPS is not available. Turn on location and try again';
  end if;

  -- the allocated-site rule is only for SITE employees (office employees check in at the Office Location as before)
  if not coalesce(me.site_employee, false) then return; end if;

  return query
  select s.id, s.name, ''::text, round(d.m)::integer, s.radius_m, s.lat, s.lng, coalesce(s.is_office, false)
    from public.sites s
    cross join lateral (select public._distance_m(p_lat, p_lng, s.lat, s.lng) as m) d
   where s.active and d.m <= least(s.radius_m, 500)
     and (exists (select 1 from public.employee_sites e where e.user_id = me.id and e.site_id = s.id)                       -- the sites allocated to him
          or (not exists (select 1 from public.employee_sites e2 where e2.user_id = me.id) and not coalesce(s.is_office, false)))   -- nothing allocated: as before
   order by d.m;

  -- nothing in range: remember it (at most once per 10 minutes) for the Admin KPI "Check-in blocked today (too far)"
  if not found
     and exists (select 1 from public.employee_sites e where e.user_id = me.id)
     and not exists (select 1 from public.attendance a where a.user_id = me.id and a.work_date = public.ist_today() and a.check_in_at is not null)
     and not exists (select 1 from public.checkin_blocked_log l where l.user_id = me.id and l.logged_at > now() - interval '10 minutes') then
    select min(public._distance_m(p_lat, p_lng, s.lat, s.lng)) into v_near
      from public.employee_sites e join public.sites s on s.id = e.site_id and s.active where e.user_id = me.id;
    insert into public.checkin_blocked_log (user_id, lat, lng, nearest_distance_m) values (me.id, p_lat, p_lng, round(v_near)::integer);
  end if;
end $$;

-- the site of today's OPEN check-in (check-out uses the same site, with no selection)
create or replace function public.my_open_checkin_site()
returns table (site_id bigint, name text, lat double precision, lng double precision, radius_m integer, is_office boolean)
language sql stable security definer set search_path = public as $$
  select s.id, s.name, s.lat, s.lng, s.radius_m, coalesce(s.is_office, false)
    from public.attendance a join public.sites s on s.name = a.site_name
   where a.user_id = auth.uid() and a.work_date = public.ist_today() and a.check_in_at is not null and a.check_out_at is null
   limit 1
$$;

-- 4. Server rule (check-in AND check-out) --------------------------------------------------------------------------
-- A DEFERRED constraint trigger: it runs at the end of the check-in / check-out call, when the Foreign Location flag
-- (place_type) is already set, so Foreign Location is never blocked.  _geofence_check and the check_in / check_out
-- functions are NOT changed.
alter table public.attendance add column if not exists check_out_site_name text;

create or replace function public._enforce_allocated_site() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  a   public.attendance;
  me  public.profiles;
  s   public.sites;
  v_in boolean; v_out boolean; d double precision;
begin
  if auth.uid() is null or auth.uid() <> new.user_id then return new; end if;                 -- Admin edits, regularisation, jobs
  if coalesce(current_setting('app.travel_rpc', true), '') = 'on' then return new; end if;     -- Field Site travel legs: unchanged
  if tg_op = 'UPDATE' and new.check_out_site_name is distinct from old.check_out_site_name then return new; end if;   -- our own write below

  v_in  := new.check_in_at  is not null and (tg_op = 'INSERT' or old.check_in_at  is null);
  v_out := new.check_out_at is not null and tg_op = 'UPDATE' and old.check_out_at is null;
  if not (v_in or v_out) then return new; end if;

  select * into me from public.profiles where id = new.user_id;
  if not coalesce(me.site_employee, false) then return new; end if;                            -- office employees: unchanged

  select * into a from public.attendance where id = new.id;                                    -- the final row of this call
  if a.place_type = 'Foreign Location' then return new; end if;                                -- Foreign Location: unchanged
  if coalesce(me.wide_site_access, false) then return new; end if;                             -- Foreign Location access: free place

  -- a site employee with NO allocated site is not restricted (the rule is for employees who have Selfie Access AND allocated sites)
  if not exists (select 1 from public.employee_sites where user_id = a.user_id) then return new; end if;

  if v_in then
    select * into s from public.sites where name = a.site_name and active limit 1;
    if s.id is null or not exists (select 1 from public.employee_sites where user_id = a.user_id and site_id = s.id) then
      raise exception 'This site is not allocated to you.';
    end if;
    d := public._distance_m(a.check_in_lat, a.check_in_lng, s.lat, s.lng);                     -- calculated again on the server
    if d is null or d > least(s.radius_m, 500) then raise exception 'You are not at an allocated site.'; end if;
  else
    -- check-out: at any allocated site that contains the submitted GPS; nearest one is saved as the check-out site
    select x.* into s
      from public.employee_sites e join public.sites x on x.id = e.site_id and x.active
     where e.user_id = a.user_id and public._distance_m(a.check_out_lat, a.check_out_lng, x.lat, x.lng) <= least(x.radius_m, 500)
     order by public._distance_m(a.check_out_lat, a.check_out_lng, x.lat, x.lng) limit 1;
    if s.id is null then
      -- Admin "Allow once": the check-out is allowed away from a site (the check-in site is kept as the check-out site)
      if not exists (select 1 from public.checkout_report_overrides o where o.employee_id = a.user_id and o.work_date = a.work_date) then
        raise exception 'You are not at an allocated site.';
      end if;
      update public.attendance set check_out_site_name = a.site_name where id = a.id;
    else
      update public.attendance set check_out_site_name = s.name where id = a.id;
    end if;
  end if;
  return new;
end $$;
revoke all on function public._enforce_allocated_site() from public, anon, authenticated;

drop trigger if exists trg_enforce_allocated_site on public.attendance;
create constraint trigger trg_enforce_allocated_site
  after insert or update on public.attendance
  deferrable initially deferred
  for each row execute function public._enforce_allocated_site();

-- 5. One-time helper: fill the allocation from the last N days of check-ins (PREVIEW first, then apply) -----------------
create or replace function public.admin_preview_allocation_from_history(p_days integer default 60)
returns table (user_id uuid, username text, full_name text, site_id bigint, site_name text, checkins integer, already_allocated boolean)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  perform public._require_admin();
  return query
  select p.id, p.username, p.full_name, s.id, s.name, count(*)::integer,
         exists (select 1 from public.employee_sites e where e.user_id = p.id and e.site_id = s.id)
    from public.attendance a
    join public.profiles p on p.id = a.user_id and p.site_employee and p.active
    join public.sites s on s.name = a.site_name and s.active and not coalesce(s.is_office, false)
   where a.work_date >= public.ist_today() - greatest(coalesce(p_days, 60), 1) and a.check_in_at is not null
   group by p.id, p.username, p.full_name, s.id, s.name
   order by p.full_name, count(*) desc;
end $$;

create or replace function public.admin_apply_allocation_from_history(p_days integer default 60)
returns integer
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._require_admin(); n integer;
begin
  insert into public.employee_sites (user_id, site_id, allocated_by)
  select distinct p.id, s.id, me.id
    from public.attendance a
    join public.profiles p on p.id = a.user_id and p.site_employee and p.active
    join public.sites s on s.name = a.site_name and s.active and not coalesce(s.is_office, false)
   where a.work_date >= public.ist_today() - greatest(coalesce(p_days, 60), 1) and a.check_in_at is not null
  on conflict do nothing;
  get diagnostics n = row_count;
  perform public._audit('ALLOCATE_SITES_FROM_HISTORY', n || ' allocation(s) added from the last ' || coalesce(p_days, 60) || ' days of check-ins');
  return n;
end $$;

-- 6. Permissions ----------------------------------------------------------------------------------------------------
revoke all on function public.my_sites_near_me(double precision, double precision) from public, anon;
revoke all on function public.my_open_checkin_site() from public, anon;
revoke all on function public.admin_preview_allocation_from_history(integer) from public, anon;
revoke all on function public.admin_apply_allocation_from_history(integer) from public, anon;
grant execute on function public.my_sites_near_me(double precision, double precision) to authenticated;
grant execute on function public.my_open_checkin_site() to authenticated;
grant execute on function public.admin_preview_allocation_from_history(integer) to authenticated;
grant execute on function public.admin_apply_allocation_from_history(integer) to authenticated;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------
-- UNDO (only if needed; no data is deleted): to switch the rule off again:
--   drop trigger if exists trg_enforce_allocated_site on public.attendance;
-- ---------------------------------------------------------------------
