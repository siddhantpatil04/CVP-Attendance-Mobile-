-- #####################################################################
-- SAFETY LOCK (added): this file is for a NEW, EMPTY database, or to be run PART BY PART.
-- Running the whole file again on a database that is already in use resets function permissions and rewrites many functions.
-- If the database already has data, the lines below STOP the script. To run everything on purpose, put this line FIRST:
--     set app.allow_full_run = 'yes';
-- To run only one part, copy only that part (from its "PART" line to the next "PART" line) - the lock is not in the way then.
-- #####################################################################
do $$
begin
  if to_regclass('public.profiles') is not null
     and coalesce(current_setting('app.allow_full_run', true), '') <> 'yes' then
    raise exception 'SAFETY LOCK: this database is already set up. Do not run the whole file again. Copy and run only the PART you need, or put   set app.allow_full_run = ''yes'';   as the first line to run everything on purpose.';
  end if;
end $$;
-- =====================================================================
--  CVP ATTENDANCE  |  C. V. PATIL & ASSOCIATES
--  Complete Supabase (PostgreSQL) database for the mobile app
--
--  HOW TO RUN
--    Supabase Dashboard -> SQL Editor -> New query -> paste this whole
--    file -> Run.  It is safe to run again (idempotent where possible).
--
--  WHAT IT CREATES
--    1. Tables      profiles, attendance, selfie_records, leave_types,
--                   leaves, regularizations, holidays, audit_log
--    2. Functions   check_in / check_out, leave + regularization workflow,
--                   monthly attendance, leave balance, admin live board,
--                   dashboard stats, company monthly report, access control
--    3. Security    Row Level Security on every table (employees see only
--                   their own data; HR/Admin see everyone)
--    4. Realtime    live updates for the admin dashboard
--    5. Storage     private "selfies" bucket for site-selfie photos
--    6. Seed data   default leave types (same quotas as the Streamlit app)
--
--  All business times are India Standard Time (Asia/Kolkata).
--  Timestamps are stored as timestamptz (UTC) and converted for display.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 0. EXTENSIONS
-- ---------------------------------------------------------------------
create extension if not exists pgcrypto;


-- ---------------------------------------------------------------------
-- 1. TABLES
-- ---------------------------------------------------------------------

-- 1.1 Employee / HR / Admin profile (one row per login account)
create table if not exists public.profiles (
  id             uuid primary key references auth.users(id) on delete cascade,
  username       text not null unique
                   check (username ~ '^[A-Za-z0-9._-]{2,40}$'),
  full_name      text not null check (length(trim(full_name)) > 0),
  role           text not null default 'Employee'
                   check (role in ('Employee','HR','Admin')),
  department     text,
  shift_start    time not null default '09:00',
  shift_end      time not null default '18:00',
  active         boolean not null default true,
  site_employee  boolean not null default false,   -- enables Site Selfie attendance
  phone          text,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  check (shift_end > shift_start)
);
-- Which Saturdays of the month are a holiday for this person (1 = first Saturday ... 5 = fifth). Default: all.
alter table public.profiles add column if not exists saturday_off integer[] not null default '{1,2,3,4,5}';

-- 1.2 Attendance: exactly one row per employee per working date
create table if not exists public.attendance (
  id              bigint generated always as identity primary key,
  user_id         uuid not null references public.profiles(id) on delete cascade,
  work_date       date not null,                       -- IST calendar date
  check_in_at     timestamptz,
  check_out_at    timestamptz,
  is_late         boolean not null default false,      -- check-in after shift start
  source          text not null default 'office'
                    check (source in ('office','site','regularized')),
  site_name       text,
  note            text,
  check_in_lat    double precision,
  check_in_lng    double precision,
  check_out_lat   double precision,
  check_out_lng   double precision,
  status          text generated always as (
                    case when check_out_at is not null then 'Present'
                         when check_in_at  is not null then 'Checked In'
                    end) stored,
  work_minutes    integer generated always as (
                    case when check_in_at is not null and check_out_at is not null
                              and check_out_at > check_in_at
                         then (extract(epoch from (check_out_at - check_in_at)) / 60)::integer
                    end) stored,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (user_id, work_date),
  check (check_out_at is null or check_in_at is not null),
  check (check_out_at is null or check_out_at > check_in_at)
);
create index if not exists attendance_date_idx on public.attendance (work_date);

-- 1.3 Site selfie records (photo stored in Storage bucket "selfies")
create table if not exists public.selfie_records (
  id             bigint generated always as identity primary key,
  user_id        uuid not null references public.profiles(id) on delete cascade,
  attendance_id  bigint references public.attendance(id) on delete set null,
  captured_at    timestamptz not null default now(),
  kind           text not null check (kind in ('IN','OUT')),
  site_name      text not null,
  note           text,
  photo_path     text,                       -- path inside the "selfies" bucket (null when outside the site area)
  lat            double precision,
  lng            double precision,
  outside        boolean not null default false,  -- punched from outside the site's allowed area (no selfie accepted)
  distance_m     integer                     -- metres from the chosen site at the time of the punch
);
-- Upgrade an existing database (safe to run again)
alter table public.selfie_records alter column photo_path drop not null;
alter table public.selfie_records add column if not exists outside boolean not null default false;
alter table public.selfie_records add column if not exists distance_m integer;
create index if not exists selfie_user_time_idx on public.selfie_records (user_id, captured_at desc);
create index if not exists selfie_time_idx on public.selfie_records (captured_at desc);

-- 1.4 Leave types and yearly quota
create table if not exists public.leave_types (
  name           text primary key,
  annual_quota   integer not null default 0 check (annual_quota >= 0),
  counts_balance boolean not null default true,     -- false for "Loss of Pay"
  sort_order     integer not null default 100,
  active         boolean not null default true
);

-- 1.5 Leave requests
create table if not exists public.leaves (
  id           bigint generated always as identity primary key,
  user_id      uuid not null references public.profiles(id) on delete cascade,
  leave_type   text not null references public.leave_types(name) on update cascade,
  from_day     date not null,
  to_day       date not null,
  days         integer not null check (days > 0),
  reason       text not null,
  status       text not null default 'Pending'
                 check (status in ('Pending','Approved','Rejected','Cancelled')),
  reviewed_by  uuid references public.profiles(id),
  reviewed_at  timestamptz,
  review_note  text,
  created_at   timestamptz not null default now(),
  check (to_day >= from_day)
);
create index if not exists leaves_user_idx on public.leaves (user_id, from_day);
create index if not exists leaves_status_idx on public.leaves (status);

-- 1.6 Attendance regularization (correction) requests
create table if not exists public.regularizations (
  id             bigint generated always as identity primary key,
  user_id        uuid not null references public.profiles(id) on delete cascade,
  day            date not null,
  requested_in   time not null,
  requested_out  time not null,
  reason         text not null,
  status         text not null default 'Pending'
                   check (status in ('Pending','Approved','Rejected','Cancelled')),
  reviewed_by    uuid references public.profiles(id),
  reviewed_at    timestamptz,
  review_note    text,
  created_at     timestamptz not null default now(),
  check (requested_out > requested_in)
);
create index if not exists reg_user_idx on public.regularizations (user_id, day);
create index if not exists reg_status_idx on public.regularizations (status);

-- 1.7 Company holidays
create table if not exists public.holidays (
  day         date primary key,
  name        text not null,
  kind        text not null default 'General' check (kind in ('General','Restricted')),
  created_by  uuid references public.profiles(id),
  created_at  timestamptz not null default now()
);

-- 1.7b Work sites with a geofence: site employees can only check in / out
--      when their phone is within radius_m metres of the site's coordinates
create table if not exists public.sites (
  id          bigint generated always as identity primary key,
  name        text not null unique check (length(trim(name)) > 0),
  lat         double precision not null check (lat between -90 and 90),
  lng         double precision not null check (lng between -180 and 180),
  radius_m    integer not null default 200 check (radius_m between 20 and 100000),
  active      boolean not null default true,
  created_by  uuid references public.profiles(id),
  created_at  timestamptz not null default now()
);
-- Upgrade an existing database: large projects (up to 100 km radius) are now allowed
alter table public.sites drop constraint if exists sites_radius_m_check;
alter table public.sites add constraint sites_radius_m_check check (radius_m between 20 and 100000);

-- 1.8 Audit trail
create table if not exists public.audit_log (
  id         bigint generated always as identity primary key,
  actor_id   uuid references public.profiles(id) on delete set null,
  action     text not null,
  detail     text,
  logged_at  timestamptz not null default now()
);
create index if not exists audit_actor_idx on public.audit_log (actor_id, id desc);

-- 1.9 Yearly leave entitlement set by the Admin per employee (overrides the default quota in leave_types)
create table if not exists public.employee_leave_quota (
  user_id     uuid not null references public.profiles(id) on delete cascade,
  year        integer not null check (year between 2000 and 2100),
  leave_type  text not null references public.leave_types(name) on update cascade on delete cascade,
  quota       integer not null check (quota between 0 and 366),
  primary key (user_id, year, leave_type)
);


-- ---------------------------------------------------------------------
-- 2. HELPER FUNCTIONS
-- ---------------------------------------------------------------------

-- Current India time / date (server clock, never the phone clock)
create or replace function public.ist_now() returns timestamp
language sql stable as $$ select (now() at time zone 'Asia/Kolkata') $$;

create or replace function public.ist_today() returns date
language sql stable as $$ select (now() at time zone 'Asia/Kolkata')::date $$;

-- Converts an IST date + time to a real timestamp
create or replace function public.ist_ts(p_day date, p_time time) returns timestamptz
language sql immutable as $$ select ((p_day + p_time) at time zone 'Asia/Kolkata') $$;

-- Monday-Friday count between two dates (same rule as the Streamlit app)
create or replace function public.working_days(p_from date, p_to date) returns integer
language sql immutable as $$
  select count(*)::integer
  from generate_series(p_from::timestamp, p_to::timestamp, interval '1 day') g
  where extract(isodow from g) < 6
$$;

-- Is the logged-in user an active HR/Admin?
create or replace function public.is_staff_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles
                 where id = auth.uid() and active and role in ('HR','Admin'))
$$;

-- Weekly off for one person: every Sunday, plus the Saturdays the admin chose (1st..5th) in profiles.saturday_off
create or replace function public._is_weekly_off(p_user uuid, p_day date) returns boolean
language sql stable security definer set search_path = public as $$
  select case extract(isodow from p_day)::int
           when 7 then true
           when 6 then coalesce((select ceil(extract(day from p_day) / 7.0)::int = any(saturday_off)
                                   from public.profiles where id = p_user), true)
           else false end
$$;

create or replace function public.is_active_user() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and active)
$$;

-- Raise an error unless the caller is an active user; returns the profile
create or replace function public._require_active() returns public.profiles
language plpgsql stable security definer set search_path = public as $$
declare p public.profiles;
begin
  select * into p from public.profiles where id = auth.uid();
  if p.id is null then raise exception 'Not signed in' using errcode = '28000'; end if;
  if not p.active then raise exception 'Your account is deactivated. Contact HR.' using errcode = '28000'; end if;
  return p;
end $$;

create or replace function public._require_admin() returns public.profiles
language plpgsql stable security definer set search_path = public as $$
declare p public.profiles;
begin
  p := public._require_active();
  if p.role not in ('HR','Admin') then
    raise exception 'Only HR / Admin can do this' using errcode = '42501';
  end if;
  return p;
end $$;

-- ROLES
--   Admin : full control (work sites, audit trail, roles, HR / Admin accounts, any username)
--   HR    : day-to-day employee work (employees, approvals, reports, selfies, holidays).
--           Cannot change roles, manage HR / Admin accounts, edit work sites or see the audit trail.
create or replace function public.is_full_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and active and role = 'Admin')
$$;

create or replace function public._require_full_admin() returns public.profiles
language plpgsql stable security definer set search_path = public as $$
declare p public.profiles;
begin
  p := public._require_active();
  if p.role <> 'Admin' then
    raise exception 'Only an Admin can do this' using errcode = '42501';
  end if;
  return p;
end $$;

-- Distance in metres between two GPS points (haversine)
create or replace function public._distance_m(
  lat1 double precision, lng1 double precision, lat2 double precision, lng2 double precision
) returns double precision
language sql immutable as $$
  select 2 * 6371000 * asin(least(1, sqrt(
    power(sin(radians(lat2 - lat1) / 2), 2) +
    cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lng2 - lng1) / 2), 2))))
$$;

-- Geofence check. Does NOT block: it reports whether the phone is inside the
-- chosen site's radius, and how far away it is. check_in()/check_out() then
-- accept a selfie only when inside; outside, the punch is saved without a
-- photo and flagged so the admin can see it was made from another location.
-- If the admin has not defined any site yet, nothing is enforced (inside = true).
drop function if exists public._enforce_geofence(bigint, double precision, double precision);
create or replace function public._geofence_check(
  p_site_id bigint, p_lat double precision, p_lng double precision
) returns table (site_name text, distance_m integer, inside boolean)
language plpgsql stable security definer set search_path = public as $$
declare s public.sites; d double precision;
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
  d := public._distance_m(p_lat, p_lng, s.lat, s.lng);
  return query select s.name, round(d)::integer, (d is not null and d <= s.radius_m);
end $$;

-- Audit writer (internal)
create or replace function public._audit(p_action text, p_detail text default null) returns void
language sql security definer set search_path = public as $$
  insert into public.audit_log (actor_id, action, detail) values (auth.uid(), p_action, p_detail)
$$;

-- updated_at maintenance
create or replace function public._touch_updated_at() returns trigger
language plpgsql as $$ begin new.updated_at := now(); return new; end $$;

drop trigger if exists profiles_touch on public.profiles;
create trigger profiles_touch before update on public.profiles
  for each row execute function public._touch_updated_at();
drop trigger if exists attendance_touch on public.attendance;
create trigger attendance_touch before update on public.attendance
  for each row execute function public._touch_updated_at();


-- ---------------------------------------------------------------------
-- 3. NEW LOGIN ACCOUNT -> PROFILE (automatic)
--    Accounts are created by the admin from the app (Edge Function
--    "admin-users") or from Supabase Dashboard -> Authentication.
--    The VERY FIRST account ever created becomes Admin automatically.
-- ---------------------------------------------------------------------
create or replace function public._handle_new_auth_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  meta jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
  v_username text := lower(coalesce(nullif(meta->>'username',''), split_part(new.email, '@', 1)));
  v_first boolean := not exists (select 1 from public.profiles);
begin
  v_username := left(regexp_replace(v_username, '[^a-z0-9._-]', '', 'g'), 34);
  if length(v_username) < 2 then v_username := 'user' || substr(new.id::text, 1, 8); end if;
  -- keep usernames unique
  if exists (select 1 from public.profiles where username = v_username) then
    v_username := v_username || '-' || substr(new.id::text, 1, 4);
  end if;

  insert into public.profiles (id, username, full_name, department, role)
  values (new.id,
          v_username,
          coalesce(nullif(meta->>'full_name',''), v_username),
          nullif(meta->>'department',''),
          case when v_first then 'Admin' else 'Employee' end)  -- role is NEVER taken from metadata
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public._handle_new_auth_user();

-- Login helper: lets the app sign in with "Employee ID / Username".
-- Returns the e-mail used by Supabase Auth for that username (or null).
create or replace function public.login_email(p_username text) returns text
language sql stable security definer set search_path = public as $$
  select u.email
  from public.profiles p join auth.users u on u.id = p.id
  where p.username = lower(trim(p_username)) and p.active
$$;


-- ---------------------------------------------------------------------
-- 4. ATTENDANCE: CHECK-IN / CHECK-OUT
--    Office punch : check_in()  /  check_out()
--    Site selfie  : check_in(p_site_name => 'STP Site', p_photo_path => '<uid>/...jpg')
-- ---------------------------------------------------------------------
-- The old 5-argument versions are replaced by versions that also take the site id
drop function if exists public.check_in(double precision, double precision, text, text, text);
drop function if exists public.check_out(double precision, double precision, text, text, text);

create or replace function public.check_in(
  p_lat        double precision default null,
  p_lng        double precision default null,
  p_site_name  text default null,
  p_note       text default null,
  p_photo_path text default null,
  p_site_id    bigint default null
) returns public.attendance
language plpgsql security definer set search_path = public as $$
declare
  me        public.profiles := public._require_active();
  v_site    boolean := me.site_employee;      -- site employees always use the site flow
  v_now     timestamp := public.ist_now();
  v_outside boolean := false;
  g         record;
  r         public.attendance;
begin
  if not me.site_employee and (p_photo_path is not null or nullif(trim(p_site_name),'') is not null) then
    raise exception 'Site selfie attendance is not enabled for your account';
  end if;

  if v_site then
    if p_lat is null or p_lng is null then
      raise exception 'Location is required. Turn on location and try again';
    end if;
    -- Where is the phone relative to the chosen site? (fixes the official site name)
    select * into g from public._geofence_check(p_site_id, p_lat, p_lng);
    v_outside := not g.inside;
    p_site_name := coalesce(g.site_name, p_site_name);
    if nullif(trim(p_site_name),'') is null then
      raise exception 'Enter the site / project name before submitting';
    end if;
    if v_outside then
      p_photo_path := null;      -- no selfie is accepted from outside the site area
    elsif p_photo_path is null or split_part(p_photo_path, '/', 1) <> me.id::text then
      raise exception 'Take a selfie first';
    end if;
  end if;

  insert into public.attendance (user_id, work_date, check_in_at, is_late, source,
                                 site_name, note, check_in_lat, check_in_lng)
  values (me.id, v_now::date, now(),
          date_trunc('minute', v_now)::time > me.shift_start,
          case when v_site then 'site' else 'office' end,
          nullif(trim(p_site_name),''), nullif(trim(p_note),''), p_lat, p_lng)
  on conflict (user_id, work_date) do nothing
  returning * into r;

  if r.id is null then
    raise exception 'You have already checked in today';
  end if;

  if v_site then
    insert into public.selfie_records (user_id, attendance_id, kind, site_name, note, photo_path, lat, lng, outside, distance_m)
    values (me.id, r.id, 'IN', trim(p_site_name), nullif(trim(p_note),''), p_photo_path, p_lat, p_lng, v_outside, g.distance_m);
    perform public._audit(case when v_outside then 'SITE_CHECK_IN_OUTSIDE' else 'SITE_SELFIE_CHECK_IN' end,
      trim(p_site_name) || case when v_outside then ' (' || coalesce(g.distance_m::text, '?') || ' m away)' else '' end);
  else
    perform public._audit('CHECK_IN', to_char(v_now, 'HH24:MI'));
  end if;
  return r;
end $$;

create or replace function public.check_out(
  p_lat        double precision default null,
  p_lng        double precision default null,
  p_site_name  text default null,
  p_note       text default null,
  p_photo_path text default null,
  p_site_id    bigint default null
) returns public.attendance
language plpgsql security definer set search_path = public as $$
declare
  me        public.profiles := public._require_active();
  v_site    boolean := me.site_employee;      -- site employees always use the site flow
  v_now     timestamp := public.ist_now();
  v_outside boolean := false;
  g         record;
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
      p_photo_path := null;      -- no selfie is accepted from outside the site area
    else
      if p_photo_path is null or split_part(p_photo_path, '/', 1) <> me.id::text then
        raise exception 'Take a selfie first';
      end if;
      if exists (select 1 from public.selfie_records
                  where attendance_id = r.id and photo_path = p_photo_path) then
        raise exception 'Check-out needs a new selfie, different from the check-in selfie';
      end if;
    end if;
  end if;

  update public.attendance
     set check_out_at  = now(),
         check_out_lat = p_lat,
         check_out_lng = p_lng,
         note          = coalesce(nullif(trim(p_note),''), note)
   where id = r.id
  returning * into r;

  if v_site then
    insert into public.selfie_records (user_id, attendance_id, kind, site_name, note, photo_path, lat, lng, outside, distance_m)
    values (me.id, r.id, 'OUT', trim(p_site_name), nullif(trim(p_note),''), p_photo_path, p_lat, p_lng, v_outside, g.distance_m);
    perform public._audit(case when v_outside then 'SITE_CHECK_OUT_OUTSIDE' else 'SITE_SELFIE_CHECK_OUT' end,
      trim(p_site_name) || case when v_outside then ' (' || coalesce(g.distance_m::text, '?') || ' m away)' else '' end);
  else
    perform public._audit('CHECK_OUT', to_char(v_now, 'HH24:MI'));
  end if;
  return r;
end $$;


-- ---------------------------------------------------------------------
-- 5. MONTHLY ATTENDANCE (same day-status rules as the Streamlit app)
--    Upcoming > Holiday > Leave > Present / Checked In > Rest Day > Absent
-- ---------------------------------------------------------------------
create or replace function public._month_attendance(p_user uuid, p_year int, p_month int)
returns table (
  day date, dow text, status text, in_time text, out_time text,
  hours numeric, is_late boolean, notes text, source text, site_name text
)
language sql stable security definer set search_path = public as $$
  with d as (
    select g::date as day
    from generate_series(make_date(p_year, p_month, 1)::timestamp,
                         (make_date(p_year, p_month, 1) + interval '1 month - 1 day'),
                         interval '1 day') g
  )
  select d.day,
         to_char(d.day, 'Dy'),
         case when d.day > public.ist_today()       then 'Upcoming'
              when h.day is not null                then 'Holiday'
              when lv.leave_type is not null        then 'Leave'
              when a.check_out_at is not null       then 'Present'
              when a.check_in_at  is not null       then 'Checked In'
              when public._is_weekly_off(p_user, d.day) then 'Rest Day'
              else 'Absent' end,
         to_char(a.check_in_at  at time zone 'Asia/Kolkata', 'HH24:MI'),
         to_char(a.check_out_at at time zone 'Asia/Kolkata', 'HH24:MI'),
         round(a.work_minutes / 60.0, 2),
         coalesce(a.is_late, false),
         coalesce(h.name, lv.leave_type, ''),
         a.source,
         a.site_name
  from d
  left join public.attendance a on a.user_id = p_user and a.work_date = d.day
  left join public.holidays   h on h.day = d.day
  left join lateral (
    select l.leave_type from public.leaves l
     where l.user_id = p_user and l.status = 'Approved'
       and d.day between l.from_day and l.to_day
     order by l.id desc limit 1) lv on true
  order by d.day
$$;

-- Public version: employees may only read their own month, HR/Admin anyone
create or replace function public.get_month_attendance(p_year int, p_month int, p_user uuid default null)
returns table (
  day date, dow text, status text, in_time text, out_time text,
  hours numeric, is_late boolean, notes text, source text, site_name text
)
language plpgsql stable security definer set search_path = public as $$
declare me public.profiles := public._require_active();
begin
  if p_user is not null and p_user <> me.id and me.role not in ('HR','Admin') then
    raise exception 'You can only view your own attendance' using errcode = '42501';
  end if;
  return query select * from public._month_attendance(coalesce(p_user, me.id), p_year, p_month);
end $$;


-- ---------------------------------------------------------------------
-- 6. LEAVE
-- ---------------------------------------------------------------------
-- Is this a working day for this person? (not their weekly off, not a company holiday)
create or replace function public._is_workday(p_user uuid, p_day date) returns boolean
language sql stable security definer set search_path = public as $$
  select not public._is_weekly_off(p_user, p_day)
     and not exists (select 1 from public.holidays h where h.day = p_day)
$$;

-- LEAVE DAYS WITH THE SANDWICH RULE
--   * Only working days count as leave days (weekly offs and company holidays do not).
--   * SANDWICH: when leave is taken on the working day before AND the working day after a block
--     of weekly-off days (Sunday, or Sunday + an off Saturday), those off days count as leave too.
--       e.g. Saturday (a working Saturday) + Monday leave  ->  Sunday is added automatically.
--   * A company / national holiday inside that block cancels the sandwich: the off days are
--     NOT added, and the holiday itself is never counted.
-- Returns days per leave type for p_user between p_from and p_to.
--   p_statuses : which leave requests to count (default: Approved)
--   p_new_from / p_new_to / p_exclude : used to price a NEW request ('NEW' rows) before it is saved
create or replace function public._leave_usage(
  p_user uuid, p_from date, p_to date,
  p_statuses text[] default array['Approved'],
  p_new_from date default null, p_new_to date default null, p_exclude bigint default null
) returns table (leave_type text, days integer)
language sql stable security definer set search_path = public as $$
  with d as (
    select g::date as day from generate_series(p_from::timestamp, p_to::timestamp, interval '1 day') g
  ),
  info as (
    select d.day,
           public._is_workday(p_user, d.day) as work,
           exists (select 1 from public.holidays h where h.day = d.day) as hol,
           case when p_new_from is not null and d.day between p_new_from and p_new_to then 'NEW'
                else (select l.leave_type from public.leaves l
                       where l.user_id = p_user and l.status = any(p_statuses)
                         and (p_exclude is null or l.id <> p_exclude)
                         and d.day between l.from_day and l.to_day
                       order by l.id desc limit 1) end as lt
    from d
  ),
  lw as (select day, lt from info where work and lt is not null),
  nw as (select day, hol, day - (row_number() over (order by day))::int as grp from info where not work),
  blocks as (select min(day) as s, max(day) as e, bool_or(hol) as has_hol, count(*) as n from nw group by grp),
  sand as (
    select b.n,
           coalesce(case when nx.lt = 'NEW' then 'NEW' end, case when pv.lt = 'NEW' then 'NEW' end, pv.lt) as lt
    from blocks b
    join lw pv on pv.day = b.s - 1
    join lw nx on nx.day = b.e + 1
    where not b.has_hol
  )
  select x.lt, sum(x.c)::integer
  from (select lt, count(*) as c from lw group by lt
        union all
        select lt, sum(n) from sand group by lt) x
  group by x.lt
$$;

create or replace function public._leave_balance(p_user uuid, p_year int)
returns table (leave_type text, granted int, used int, balance int, counts_balance boolean)
language sql stable security definer set search_path = public as $$
  select t.name,
         g.q,
         coalesce(u.days, 0)::int,
         (g.q - coalesce(u.days, 0))::int,
         t.counts_balance
  from public.leave_types t
  cross join lateral (
    select coalesce((select q.quota from public.employee_leave_quota q
                      where q.user_id = p_user and q.year = p_year and q.leave_type = t.name),
                    t.annual_quota)::int as q) g
  left join public._leave_usage(p_user, make_date(p_year,1,1), make_date(p_year,12,31)) u on u.leave_type = t.name
  where t.active
  order by t.sort_order, t.name
$$;
create or replace function public.get_leave_balance(p_year int default null, p_user uuid default null)
returns table (leave_type text, granted int, used int, balance int, counts_balance boolean)
language plpgsql stable security definer set search_path = public as $$
declare me public.profiles := public._require_active();
begin
  if p_user is not null and p_user <> me.id and me.role not in ('HR','Admin') then
    raise exception 'You can only view your own leave balance' using errcode = '42501';
  end if;
  return query select * from public._leave_balance(coalesce(p_user, me.id),
                                                   coalesce(p_year, extract(year from public.ist_today())::int));
end $$;

create or replace function public.apply_leave(p_leave_type text, p_from date, p_to date, p_reason text)
returns public.leaves
language plpgsql security definer set search_path = public as $$
declare
  me     public.profiles := public._require_active();
  t      public.leave_types;
  v_days int;
  v_bal  int;
  r      public.leaves;
begin
  select * into t from public.leave_types where name = p_leave_type and active;
  if t.name is null then raise exception 'Unknown leave type'; end if;
  if p_to < p_from then raise exception 'End date cannot be before start date'; end if;
  if nullif(trim(p_reason),'') is null then raise exception 'Enter a reason'; end if;
  if extract(year from p_from) <> extract(year from p_to) then
    raise exception 'Submit one calendar year per request';
  end if;
  -- working days in the range + sandwiched weekly offs (also joined with the person's other pending / approved leave)
  select coalesce(sum(u.days), 0)::int into v_days
    from public._leave_usage(me.id, p_from - 10, p_to + 10, array['Approved','Pending'], p_from, p_to, null) u
   where u.leave_type = 'NEW';
  if v_days = 0 then raise exception 'No working days in the selected period (weekly off / holiday only)'; end if;

  if exists (select 1 from public.leaves
              where user_id = me.id and status in ('Pending','Approved')
                and from_day <= p_to and to_day >= p_from) then
    raise exception 'These dates overlap with another leave request';
  end if;

  if t.counts_balance then
    select b.balance into v_bal from public._leave_balance(me.id, extract(year from p_from)::int) b
     where b.leave_type = t.name;
    if v_days > coalesce(v_bal, 0) then
      raise exception 'Insufficient leave balance (% day(s) available)', coalesce(v_bal,0);
    end if;
  end if;

  insert into public.leaves (user_id, leave_type, from_day, to_day, days, reason)
  values (me.id, t.name, p_from, p_to, v_days, trim(p_reason))
  returning * into r;
  perform public._audit('LEAVE_REQUEST', t.name || ' ' || p_from || ' to ' || p_to);
  return r;
end $$;

create or replace function public.cancel_leave(p_id bigint) returns public.leaves
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._require_active(); r public.leaves;
begin
  update public.leaves set status = 'Cancelled'
   where id = p_id and user_id = me.id and status = 'Pending'
  returning * into r;
  if r.id is null then raise exception 'Only your own pending requests can be cancelled'; end if;
  perform public._audit('CANCEL_LEAVE', p_id::text);
  return r;
end $$;

create or replace function public.review_leave(p_id bigint, p_approve boolean, p_note text default null)
returns public.leaves
language plpgsql security definer set search_path = public as $$
declare
  me    public.profiles := public._require_admin();
  r     public.leaves;
  t     public.leave_types;
  v_bal int;
begin
  select * into r from public.leaves where id = p_id for update;
  if r.id is null then raise exception 'Leave request not found'; end if;
  if r.status <> 'Pending' then raise exception 'This request is already %', lower(r.status); end if;

  if p_approve then
    -- re-price with the sandwich rule against the leave that is already approved
    select coalesce(sum(u.days), 0)::int into r.days
      from public._leave_usage(r.user_id, r.from_day - 10, r.to_day + 10, array['Approved'], r.from_day, r.to_day, r.id) u
     where u.leave_type = 'NEW';
    if r.days = 0 then raise exception 'This request has no working days (weekly off / holiday only)'; end if;
    update public.leaves set days = r.days where id = r.id;
    select * into t from public.leave_types where name = r.leave_type;
    if t.counts_balance then
      select b.balance into v_bal from public._leave_balance(r.user_id, extract(year from r.from_day)::int) b
       where b.leave_type = r.leave_type;
      if r.days > coalesce(v_bal, 0) then
        raise exception 'Insufficient balance: cannot approve (% day(s) available)', coalesce(v_bal,0);
      end if;
    end if;
  end if;

  update public.leaves
     set status = case when p_approve then 'Approved' else 'Rejected' end,
         reviewed_by = me.id, reviewed_at = now(), review_note = nullif(trim(p_note),'')
   where id = p_id
  returning * into r;
  perform public._audit(case when p_approve then 'APPROVE_LEAVE' else 'REJECT_LEAVE' end, p_id::text);
  return r;
end $$;


-- ---------------------------------------------------------------------
-- 7. REGULARIZATION (missed / wrong punch correction)
-- ---------------------------------------------------------------------
create or replace function public.request_regularization(p_day date, p_in time, p_out time, p_reason text)
returns public.regularizations
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._require_active(); r public.regularizations;
begin
  if p_day > public.ist_today() then raise exception 'Date cannot be in the future'; end if;
  if p_out <= p_in then raise exception 'Check-out must be after check-in for same-day shifts'; end if;
  if nullif(trim(p_reason),'') is null then raise exception 'Enter a reason'; end if;
  if exists (select 1 from public.regularizations
              where user_id = me.id and day = p_day and status = 'Pending') then
    raise exception 'A pending correction already exists for this date';
  end if;
  insert into public.regularizations (user_id, day, requested_in, requested_out, reason)
  values (me.id, p_day, p_in, p_out, trim(p_reason))
  returning * into r;
  perform public._audit('REGULARIZATION_REQUEST', p_day::text);
  return r;
end $$;

create or replace function public.cancel_regularization(p_id bigint) returns public.regularizations
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._require_active(); r public.regularizations;
begin
  update public.regularizations set status = 'Cancelled'
   where id = p_id and user_id = me.id and status = 'Pending'
  returning * into r;
  if r.id is null then raise exception 'Only your own pending requests can be cancelled'; end if;
  perform public._audit('CANCEL_REGULARIZATION', p_id::text);
  return r;
end $$;

create or replace function public.review_regularization(p_id bigint, p_approve boolean, p_note text default null)
returns public.regularizations
language plpgsql security definer set search_path = public as $$
declare
  me public.profiles := public._require_admin();
  r  public.regularizations;
  emp public.profiles;
begin
  select * into r from public.regularizations where id = p_id for update;
  if r.id is null then raise exception 'Request not found'; end if;
  if r.status <> 'Pending' then raise exception 'This request is already %', lower(r.status); end if;

  if p_approve then
    select * into emp from public.profiles where id = r.user_id;
    insert into public.attendance (user_id, work_date, check_in_at, check_out_at, is_late, source, note)
    values (r.user_id, r.day,
            public.ist_ts(r.day, r.requested_in), public.ist_ts(r.day, r.requested_out),
            r.requested_in > emp.shift_start, 'regularized', 'Regularized: ' || r.reason)
    on conflict (user_id, work_date) do update
       set check_in_at  = excluded.check_in_at,
           check_out_at = excluded.check_out_at,
           is_late      = excluded.is_late,
           source       = 'regularized',
           note         = excluded.note;
  end if;

  update public.regularizations
     set status = case when p_approve then 'Approved' else 'Rejected' end,
         reviewed_by = me.id, reviewed_at = now(), review_note = nullif(trim(p_note),'')
   where id = p_id
  returning * into r;
  perform public._audit(case when p_approve then 'APPROVE_CORRECTION' else 'REJECT_CORRECTION' end, p_id::text);
  return r;
end $$;


-- ---------------------------------------------------------------------
-- 8. DASHBOARDS
-- ---------------------------------------------------------------------

-- 8.1 Employee home screen summary (one call)
create or replace function public.my_dashboard() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  me     public.profiles := public._require_active();
  v_today date := public.ist_today();
  t      public.attendance;
  m      record;
  v_leave int;
begin
  select * into t from public.attendance where user_id = me.id and work_date = v_today;

  select count(*) filter (where status in ('Present','Checked In'))           as present,
         count(*) filter (where day <= v_today)                              as elapsed,
         count(*) filter (where day <= v_today and status not in ('Rest Day','Holiday')) as working_days,
         count(*) filter (where is_late and status in ('Present','Checked In')) as late,
         count(*) filter (where status = 'Absent')                           as absent,
         count(*) filter (where status = 'Leave')                            as on_leave,
         coalesce(sum(hours), 0)                                             as hours
    into m
    from public._month_attendance(me.id, extract(year from v_today)::int, extract(month from v_today)::int);

  select coalesce(sum(greatest(balance,0)),0) into v_leave
    from public._leave_balance(me.id, extract(year from v_today)::int) where counts_balance;

  return jsonb_build_object(
    'profile', to_jsonb(me),
    'today', v_today,
    'server_time', now(),
    'attendance', case when t.id is null then null else to_jsonb(t) end,
    'month', jsonb_build_object('present', m.present, 'elapsed', m.elapsed,
                                'working_days', m.working_days, 'late', m.late,
                                'absent', m.absent, 'leave', m.on_leave, 'hours', m.hours),
    'leave_balance_total', v_leave,
    'is_holiday', (select name from public.holidays where day = v_today)
  );
end $$;

-- 8.2 Admin LIVE board: every active employee + today's status
create or replace function public.admin_today_board(p_date date default null)
returns table (
  user_id uuid, username text, full_name text, department text, role text,
  site_employee boolean, shift_start time,
  check_in_at timestamptz, check_out_at timestamptz,
  in_time text, out_time text, status text, is_late boolean,
  work_minutes int, source text, site_name text, leave_type text
)
language plpgsql stable security definer set search_path = public as $$
declare
  v_day date := coalesce(p_date, public.ist_today());
  v_holiday text;
begin
  perform public._require_admin();
  select name into v_holiday from public.holidays where day = v_day;
  return query
  select p.id, p.username, p.full_name, p.department, p.role,
         p.site_employee, p.shift_start,
         a.check_in_at, a.check_out_at,
         to_char(a.check_in_at  at time zone 'Asia/Kolkata', 'HH24:MI'),
         to_char(a.check_out_at at time zone 'Asia/Kolkata', 'HH24:MI'),
         case when a.check_out_at is not null then 'Present'
              when a.check_in_at  is not null then 'Checked In'
              when lv.leave_type  is not null then 'Leave'
              when v_holiday      is not null then 'Holiday'
              when public._is_weekly_off(p.id, v_day) then 'Rest Day'
              when v_day = public.ist_today() then 'Not Checked In'
              else 'Absent' end,
         coalesce(a.is_late, false),
         case when a.check_out_at is null and a.check_in_at is not null and v_day = public.ist_today()
              then (extract(epoch from (now() - a.check_in_at)) / 60)::int   -- live "working for"
              else a.work_minutes end,
         a.source, a.site_name, lv.leave_type
  from public.profiles p
  left join public.attendance a on a.user_id = p.id and a.work_date = v_day
  left join lateral (
    select l.leave_type from public.leaves l
     where l.user_id = p.id and l.status = 'Approved' and v_day between l.from_day and l.to_day
     limit 1) lv on true
  where p.active
  order by (a.check_in_at is null), a.check_in_at desc nulls last, p.full_name;
end $$;

-- 8.3 Admin KPI cards (HR Control Center)
create or replace function public.admin_dashboard_stats(p_date date default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_day date := coalesce(p_date, public.ist_today()); res jsonb;
begin
  perform public._require_admin();
  select jsonb_build_object(
    'date',               v_day,
    'total_employees',    (select count(*) from public.profiles),
    'active_employees',   count(*),
    'present_today',      count(*) filter (where b.status in ('Present','Checked In')),
    'checked_out',        count(*) filter (where b.status = 'Present'),
    'still_working',      count(*) filter (where b.status = 'Checked In'),
    'late_today',         count(*) filter (where b.is_late),
    'on_leave',           count(*) filter (where b.status = 'Leave'),
    'not_checked_in',     count(*) filter (where b.status in ('Not Checked In','Absent')),
    'site_checkins',      count(*) filter (where b.source = 'site'),
    'pending_leaves',     (select count(*) from public.leaves where status = 'Pending'),
    'pending_regularizations', (select count(*) from public.regularizations where status = 'Pending'),
    'is_holiday',         (select name from public.holidays where day = v_day)
  ) into res
  from public.admin_today_board(v_day) b;
  return res;
end $$;

-- 8.4 Company monthly report: one row per active employee
-- (dropped first: a later section adds a column, and CREATE OR REPLACE cannot change the columns of a function that already exists)
drop function if exists public.admin_month_summary(int, int);
create or replace function public.admin_month_summary(p_year int, p_month int)
returns table (
  user_id uuid, username text, full_name text, department text,
  present int, absent int, on_leave int, late int, holidays int, hours numeric
)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public._require_admin();
  return query
  select p.id, p.username, p.full_name, p.department,
         count(*) filter (where m.status in ('Present','Checked In'))::int,
         count(*) filter (where m.status = 'Absent')::int,
         count(*) filter (where m.status = 'Leave')::int,
         count(*) filter (where m.is_late and m.status in ('Present','Checked In'))::int,
         count(*) filter (where m.status = 'Holiday')::int,
         coalesce(sum(m.hours), 0)
  from public.profiles p
  cross join lateral public._month_attendance(p.id, p_year, p_month) m
  where p.active
  group by p.id, p.username, p.full_name, p.department
  order by p.full_name;
end $$;


-- ---------------------------------------------------------------------
-- 9. ACCESS CONTROL (role / department / shift / site permission)
--    Activate / deactivate + password reset go through the Edge Function
--    "admin-users" because they also change the login account.
-- ---------------------------------------------------------------------
create or replace function public.admin_update_profile(
  p_user          uuid,
  p_full_name     text default null,
  p_role          text default null,
  p_department    text default null,
  p_site_employee boolean default null,
  p_shift_start   time default null,
  p_shift_end     time default null,
  p_phone         text default null
) returns public.profiles
language plpgsql security definer set search_path = public as $$
declare
  me     public.profiles := public._require_admin();
  target public.profiles;
begin
  select * into target from public.profiles where id = p_user for update;
  if target.id is null then raise exception 'User not found'; end if;

  if p_role is not null and p_role not in ('Employee','HR','Admin') then
    raise exception 'Invalid role';
  end if;
  -- HR can edit employees (and their own profile). Only an Admin can change roles
  -- or touch other HR / Admin accounts.
  if me.role <> 'Admin' then
    if target.id <> me.id and target.role <> 'Employee' then
      raise exception 'Only an Admin can change HR / Admin accounts';
    end if;
    if p_role is not null and p_role <> target.role then
      raise exception 'Only an Admin can change roles';
    end if;
  end if;
  -- Avoid locking yourself out
  if p_user = me.id and p_role is not null and p_role <> me.role then
    raise exception 'You cannot change your own role';
  end if;

  update public.profiles set
    full_name     = coalesce(nullif(trim(p_full_name),''), full_name),
    role          = coalesce(p_role, role),
    department    = case when p_department is null then department else nullif(trim(p_department),'') end,
    site_employee = coalesce(p_site_employee, site_employee),
    shift_start   = coalesce(p_shift_start, shift_start),
    shift_end     = coalesce(p_shift_end, shift_end),
    phone         = case when p_phone is null then phone else nullif(trim(p_phone),'') end
  where id = p_user
  returning * into target;

  perform public._audit('UPDATE_ACCESS',
    target.username || ' role=' || target.role || ' site=' || target.site_employee
    || ' shift=' || to_char(target.shift_start,'HH24:MI') || '-' || to_char(target.shift_end,'HH24:MI'));
  return target;
end $$;

-- Create / edit / deactivate a work site (geofence). p_id null = new site.
create or replace function public.admin_save_site(
  p_id      bigint,
  p_name    text,
  p_lat     double precision,
  p_lng     double precision,
  p_radius  integer default 200,
  p_active  boolean default true
) returns public.sites
language plpgsql security definer set search_path = public as $$
declare
  me public.profiles := public._require_full_admin();   -- work sites: Admin only
  r  public.sites;
begin
  if nullif(trim(p_name),'') is null then raise exception 'Enter the site name'; end if;
  if p_lat is null or p_lng is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 then
    raise exception 'Enter a valid latitude and longitude';
  end if;
  if p_radius is null or p_radius < 20 or p_radius > 100000 then
    raise exception 'Radius must be between 20 metres and 100 km';
  end if;

  if p_id is null then
    insert into public.sites (name, lat, lng, radius_m, active, created_by)
    values (trim(p_name), p_lat, p_lng, p_radius, coalesce(p_active, true), me.id)
    returning * into r;
  else
    update public.sites
       set name = trim(p_name), lat = p_lat, lng = p_lng,
           radius_m = p_radius, active = coalesce(p_active, active)
     where id = p_id
    returning * into r;
    if r.id is null then raise exception 'Site not found'; end if;
  end if;

  perform public._audit('SAVE_SITE', r.name || ' radius=' || r.radius_m || 'm active=' || r.active);
  return r;
end $$;

-- Change a login username. The login e-mail stays the same; the app looks the
-- e-mail up from the username, so only this one value changes.
--   Admin : any account.   HR : employees and their own account.
create or replace function public.admin_change_username(p_user uuid, p_username text)
returns public.profiles
language plpgsql security definer set search_path = public as $$
declare
  me     public.profiles := public._require_admin();
  target public.profiles;
  v_name text := lower(trim(coalesce(p_username, '')));
  v_old  text;
begin
  if v_name !~ '^[a-z0-9._-]{2,40}$' then
    raise exception 'Username may contain letters, numbers, dot, dash and underscore (2-40 characters)';
  end if;
  select * into target from public.profiles where id = p_user for update;
  if target.id is null then raise exception 'User not found'; end if;
  if me.role <> 'Admin' and target.id <> me.id and target.role <> 'Employee' then
    raise exception 'Only an Admin can change HR / Admin usernames';
  end if;
  v_old := target.username;
  if v_name = v_old then return target; end if;
  if exists (select 1 from public.profiles where username = v_name and id <> target.id) then
    raise exception 'This username is already taken';
  end if;
  update public.profiles set username = v_name where id = target.id returning * into target;
  perform public._audit('CHANGE_USERNAME', v_old || ' -> ' || v_name);
  return target;
end $$;

-- Small helper the app calls after a password change (audit only)
create or replace function public.log_password_change() returns void
language plpgsql security definer set search_path = public as $$
begin perform public._require_active(); perform public._audit('PASSWORD_CHANGE', null); end $$;


-- ---------------------------------------------------------------------
-- 10. HOLIDAY AUDIT TRIGGER (holidays are edited directly by HR/Admin)
-- ---------------------------------------------------------------------
create or replace function public._audit_holiday() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'DELETE' then
    perform public._audit('DELETE_HOLIDAY', old.day::text || ' ' || old.name);
    return old;
  end if;
  perform public._audit(case when tg_op = 'INSERT' then 'CREATE_HOLIDAY' else 'UPDATE_HOLIDAY' end,
                        new.day::text || ' ' || new.name);
  return new;
end $$;

drop trigger if exists holidays_audit on public.holidays;
create trigger holidays_audit after insert or update or delete on public.holidays
  for each row execute function public._audit_holiday();


-- ---------------------------------------------------------------------
-- 11. ROW LEVEL SECURITY
--     No table can be written directly by employees: every change goes
--     through the functions above, which validate and audit it.
-- ---------------------------------------------------------------------
alter table public.profiles        enable row level security;
alter table public.attendance      enable row level security;
alter table public.selfie_records  enable row level security;
alter table public.leave_types     enable row level security;
alter table public.leaves          enable row level security;
alter table public.regularizations enable row level security;
alter table public.holidays        enable row level security;
alter table public.audit_log       enable row level security;
alter table public.sites           enable row level security;

-- sites: any active signed-in user can read; changes go through admin_save_site()
drop policy if exists sites_read on public.sites;
create policy sites_read on public.sites for select to authenticated
  using (public.is_active_user());

-- profiles: any active signed-in user can read the team directory
drop policy if exists profiles_read on public.profiles;
create policy profiles_read on public.profiles for select to authenticated
  using (id = auth.uid() or public.is_active_user());

-- attendance
drop policy if exists attendance_read on public.attendance;
create policy attendance_read on public.attendance for select to authenticated
  using (user_id = auth.uid() or public.is_staff_admin());

-- selfies
drop policy if exists selfie_read on public.selfie_records;
create policy selfie_read on public.selfie_records for select to authenticated
  using (user_id = auth.uid() or public.is_staff_admin());

-- leave types: everyone reads, HR/Admin manage
drop policy if exists leave_types_read on public.leave_types;
create policy leave_types_read on public.leave_types for select to authenticated using (true);
drop policy if exists leave_types_admin on public.leave_types;
create policy leave_types_admin on public.leave_types for all to authenticated
  using (public.is_staff_admin()) with check (public.is_staff_admin());

-- leaves
drop policy if exists leaves_read on public.leaves;
create policy leaves_read on public.leaves for select to authenticated
  using (user_id = auth.uid() or public.is_staff_admin());

-- regularizations
drop policy if exists reg_read on public.regularizations;
create policy reg_read on public.regularizations for select to authenticated
  using (user_id = auth.uid() or public.is_staff_admin());

-- holidays: everyone reads, HR/Admin manage
drop policy if exists holidays_read on public.holidays;
create policy holidays_read on public.holidays for select to authenticated using (true);
drop policy if exists holidays_admin on public.holidays;
create policy holidays_admin on public.holidays for all to authenticated
  using (public.is_staff_admin()) with check (public.is_staff_admin());

-- audit log: everyone sees their own activity; only an Admin sees everything
drop policy if exists audit_read on public.audit_log;
create policy audit_read on public.audit_log for select to authenticated
  using (actor_id = auth.uid() or public.is_full_admin());


-- ---------------------------------------------------------------------
-- 12. PRIVILEGES
-- ---------------------------------------------------------------------
revoke all on all tables    in schema public from anon;
revoke all on all sequences in schema public from anon;
revoke execute on all functions in schema public from public, anon;

grant usage on schema public to authenticated;
grant select on all tables in schema public to authenticated;
grant insert, update, delete on public.holidays, public.leave_types to authenticated;

-- Internal helpers: not callable from the app
revoke execute on function public._audit(text, text)                 from authenticated;
revoke execute on function public._month_attendance(uuid, int, int)  from authenticated;
revoke execute on function public._leave_balance(uuid, int)          from authenticated;
revoke execute on function public._leave_usage(uuid, date, date, text[], date, date, bigint) from authenticated;
revoke execute on function public._is_workday(uuid, date)           from authenticated;
revoke execute on function public._handle_new_auth_user()            from authenticated;

-- App-callable functions
grant execute on function public.ist_now()                                     to authenticated;
grant execute on function public.ist_today()                                   to authenticated;
grant execute on function public.ist_ts(date, time)                            to authenticated;
grant execute on function public.working_days(date, date)                      to authenticated;
grant execute on function public.is_staff_admin()                              to authenticated;
grant execute on function public.is_active_user()                              to authenticated;
grant execute on function public._require_active()                             to authenticated;
grant execute on function public._require_admin()                              to authenticated;
grant execute on function public.is_full_admin()                               to authenticated;
grant execute on function public._require_full_admin()                         to authenticated;
grant execute on function public.admin_change_username(uuid, text)             to authenticated;
grant execute on function public.check_in(double precision, double precision, text, text, text, bigint)  to authenticated;
grant execute on function public.check_out(double precision, double precision, text, text, text, bigint) to authenticated;
grant execute on function public.admin_save_site(bigint, text, double precision, double precision, integer, boolean) to authenticated;
grant execute on function public.get_month_attendance(int, int, uuid)          to authenticated;
grant execute on function public.get_leave_balance(int, uuid)                  to authenticated;
grant execute on function public.apply_leave(text, date, date, text)           to authenticated;
grant execute on function public.cancel_leave(bigint)                          to authenticated;
grant execute on function public.review_leave(bigint, boolean, text)           to authenticated;
grant execute on function public.request_regularization(date, time, time, text) to authenticated;
grant execute on function public.cancel_regularization(bigint)                 to authenticated;
grant execute on function public.review_regularization(bigint, boolean, text)  to authenticated;
grant execute on function public.my_dashboard()                                to authenticated;
grant execute on function public.admin_today_board(date)                       to authenticated;
grant execute on function public.admin_dashboard_stats(date)                   to authenticated;
grant execute on function public.admin_month_summary(int, int)                 to authenticated;
grant execute on function public.admin_update_profile(uuid, text, text, text, boolean, time, time, text) to authenticated;
grant execute on function public.log_password_change()                         to authenticated;

-- The login screen runs before sign-in, so it needs anon access to this one
grant execute on function public.login_email(text) to anon, authenticated;


-- ---------------------------------------------------------------------
-- 13. REALTIME (live admin dashboard)
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['attendance','selfie_records','leaves','regularizations','profiles','holidays','sites']
  loop
    if not exists (select 1 from pg_publication_tables
                    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;


-- ---------------------------------------------------------------------
-- 14. STORAGE: private bucket for site selfies
--     Path format: <user-uuid>/<yyyy-mm-dd>_<IN|OUT>_<timestamp>.jpg
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('selfies', 'selfies', false, 5242880, array['image/jpeg','image/png','image/webp'])
on conflict (id) do update
  set public = false, file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists selfies_upload_own on storage.objects;
create policy selfies_upload_own on storage.objects for insert to authenticated
  with check (
    bucket_id = 'selfies'
    and (storage.foldername(name))[1] = auth.uid()::text
    and exists (select 1 from public.profiles p
                 where p.id = auth.uid() and p.active and p.site_employee)
  );

drop policy if exists selfies_read on storage.objects;
create policy selfies_read on storage.objects for select to authenticated
  using (
    bucket_id = 'selfies'
    and ((storage.foldername(name))[1] = auth.uid()::text or public.is_staff_admin())
  );


-- ---------------------------------------------------------------------
-- 15. SEED DATA (same leave quotas as the Streamlit app)
-- ---------------------------------------------------------------------
insert into public.leave_types (name, annual_quota, counts_balance, sort_order) values
  ('Casual Leave',     12, true,  10),
  ('Sick Leave',       12, true,  20),
  ('Annual Leave',     24, true,  30),
  ('Compensatory Off',  0, true,  40),
  ('Loss of Pay',       0, false, 50)
on conflict (name) do nothing;

-- =====================================================================
--  DONE.  Next: create your first login (Authentication -> Users ->
--  Add user). The first account automatically becomes Admin.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 16. FIELD VISITS MODULE
-- ---------------------------------------------------------------------
-- =====================================================================
-- CVP Attendance: FIELD VISITS module
-- Run ONCE in Supabase SQL Editor AFTER cvp_attendance_schema.sql (safe to re-run).
--
-- Flow: employee checks in at the office, works the first half, then taps
-- "Start Visit" (place, purpose, GPS), and "End Visit" (notes/outcome, GPS).
-- Only employees whose Visit Access is switched ON by an Admin/HR can use it.
-- Admin/HR can review (approve / reject) every visit.
-- =====================================================================

-- 1. Access flag (Admin turns this on per employee)
alter table public.profiles add column if not exists visit_access boolean not null default false;

-- 2. Visits table
create table if not exists public.visits (
  id            bigint generated always as identity primary key,
  user_id       uuid not null references public.profiles(id) on delete cascade,
  visit_date    date not null,                         -- IST calendar date
  place         text not null check (length(trim(place)) > 0),
  purpose       text not null check (length(trim(purpose)) > 0),
  start_at      timestamptz not null default now(),
  start_lat     double precision,
  start_lng     double precision,
  end_at        timestamptz,
  end_lat       double precision,
  end_lng       double precision,
  outcome       text,
  status        text not null default 'Ongoing'
                  check (status in ('Ongoing','Pending','Approved','Rejected')),
  review_note   text,
  reviewed_by   uuid references public.profiles(id),
  reviewed_at   timestamptz,
  created_at    timestamptz not null default now(),
  check (end_at is null or end_at >= start_at)
);
create index if not exists visits_user_date_idx on public.visits (user_id, visit_date desc);
create index if not exists visits_status_idx    on public.visits (status);
-- at most one open visit per employee
create unique index if not exists visits_one_open_idx on public.visits (user_id) where end_at is null;

-- 3. Helpers
create or replace function public._require_visit_access() returns public.profiles
language plpgsql stable security definer set search_path = public as $$
declare p public.profiles;
begin
  p := public._require_active();
  if not p.visit_access then
    raise exception 'Field visit access is not enabled for your account. Contact your Admin.' using errcode = '42501';
  end if;
  return p;
end $$;

-- 4. Admin / HR: grant or remove visit access
create or replace function public.admin_set_visit_access(p_user uuid, p_enabled boolean)
returns public.profiles
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._require_admin(); target public.profiles;
begin
  select * into target from public.profiles where id = p_user for update;
  if target.id is null then raise exception 'User not found'; end if;
  if me.role <> 'Admin' and target.id <> me.id and target.role <> 'Employee' then
    raise exception 'Only an Admin can change HR / Admin accounts';
  end if;
  update public.profiles set visit_access = p_enabled where id = p_user returning * into target;
  perform public._audit('VISIT_ACCESS', target.username || ' visit_access=' || p_enabled);
  return target;
end $$;

-- 5. Employee: start a visit
create or replace function public.start_visit(
  p_place text, p_purpose text,
  p_lat double precision default null, p_lng double precision default null
) returns public.visits
language plpgsql security definer set search_path = public as $$
declare
  me  public.profiles := public._require_visit_access();
  d   date := public.ist_today();
  att public.attendance;
  v   public.visits;
begin
  if nullif(trim(p_place),'') is null   then raise exception 'Enter the place / client you are visiting'; end if;
  if nullif(trim(p_purpose),'') is null then raise exception 'Enter the purpose of the visit'; end if;
  if p_lat is null or p_lng is null     then raise exception 'Location is required to start a visit'; end if;

  select * into att from public.attendance where user_id = me.id and work_date = d;
  if att.id is null or att.check_in_at is null then
    raise exception 'Check in at the office first, then start your visit';
  end if;
  if att.check_out_at is not null then
    raise exception 'You have already checked out today';
  end if;
  if exists (select 1 from public.visits where user_id = me.id and end_at is null) then
    raise exception 'You already have a visit in progress. End it first';
  end if;

  insert into public.visits (user_id, visit_date, place, purpose, start_lat, start_lng)
  values (me.id, d, trim(p_place), trim(p_purpose), p_lat, p_lng)
  returning * into v;
  perform public._audit('VISIT_START', me.username || ' at ' || v.place);
  return v;
end $$;

-- 6. Employee: end the open visit (goes to admin for approval)
create or replace function public.end_visit(
  p_outcome text default null,
  p_lat double precision default null, p_lng double precision default null
) returns public.visits
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._require_visit_access(); v public.visits;
begin
  if p_lat is null or p_lng is null then raise exception 'Location is required to end a visit'; end if;
  update public.visits set
      end_at = now(), end_lat = p_lat, end_lng = p_lng,
      outcome = nullif(trim(p_outcome),''), status = 'Pending'
    where user_id = me.id and end_at is null
    returning * into v;
  if v.id is null then raise exception 'You have no visit in progress'; end if;
  perform public._audit('VISIT_END', me.username || ' at ' || v.place);
  return v;
end $$;

-- 7. Admin / HR: approve or reject a finished visit
create or replace function public.review_visit(p_id bigint, p_approve boolean, p_note text default null)
returns public.visits
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._require_admin(); v public.visits;
begin
  update public.visits set
      status = case when p_approve then 'Approved' else 'Rejected' end,
      review_note = nullif(trim(p_note),''), reviewed_by = me.id, reviewed_at = now()
    where id = p_id and status = 'Pending'
    returning * into v;
  if v.id is null then raise exception 'Visit not found or already reviewed'; end if;
  perform public._audit(case when p_approve then 'VISIT_APPROVE' else 'VISIT_REJECT' end, 'visit #' || p_id);
  return v;
end $$;

-- 8. Security: employees read only their own; HR/Admin read all. No direct writes.
alter table public.visits enable row level security;
drop policy if exists visits_read on public.visits;
create policy visits_read on public.visits for select to authenticated
  using (user_id = auth.uid() or public.is_staff_admin());

grant select on public.visits to authenticated;
revoke all on public.visits from anon;
revoke execute on function public._require_visit_access()                       from public, anon, authenticated;
revoke execute on function public.admin_set_visit_access(uuid, boolean)         from public, anon;
revoke execute on function public.start_visit(text, text, double precision, double precision) from public, anon;
revoke execute on function public.end_visit(text, double precision, double precision)         from public, anon;
revoke execute on function public.review_visit(bigint, boolean, text)           from public, anon;
grant execute on function public.admin_set_visit_access(uuid, boolean)          to authenticated;
grant execute on function public.start_visit(text, text, double precision, double precision)  to authenticated;
grant execute on function public.end_visit(text, double precision, double precision)          to authenticated;
grant execute on function public.review_visit(bigint, boolean, text)            to authenticated;

-- 9. Live updates
do $$
begin
  if not exists (select 1 from pg_publication_tables
                  where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'visits') then
    alter publication supabase_realtime add table public.visits;
  end if;
end $$;


-- ---------------------------------------------------------------------
-- 17. EMPLOYEE JOINING DATE
-- ---------------------------------------------------------------------
alter table public.profiles add column if not exists joining_date date;

create or replace function public.admin_set_joining_date(p_user uuid, p_date date)
returns public.profiles
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._require_admin(); target public.profiles;
begin
  if p_date is not null and p_date > public.ist_today() then
    raise exception 'Joining date cannot be in the future';
  end if;
  select * into target from public.profiles where id = p_user for update;
  if target.id is null then raise exception 'User not found'; end if;
  if me.role <> 'Admin' and target.id <> me.id and target.role <> 'Employee' then
    raise exception 'Only an Admin can change HR / Admin accounts';
  end if;
  update public.profiles set joining_date = p_date where id = p_user returning * into target;
  perform public._audit('JOINING_DATE', target.username || ' ' || coalesce(p_date::text, 'cleared'));
  return target;
end $$;

revoke execute on function public.admin_set_joining_date(uuid, date) from public, anon;
grant  execute on function public.admin_set_joining_date(uuid, date) to authenticated;

-- ---------------------------------------------------------------------
-- 18. SATURDAY HOLIDAYS PER EMPLOYEE
--     Admin chooses, for each employee, which Saturdays (1st-5th) are a holiday.
--     A Saturday that is NOT a holiday counts as a working day (Absent if no attendance).
-- ---------------------------------------------------------------------
create or replace function public.admin_set_saturdays(p_user uuid, p_saturdays integer[])
returns public.profiles
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._require_admin(); target public.profiles; v integer[];
begin
  select coalesce(array_agg(distinct x order by x), '{}') into v from unnest(coalesce(p_saturdays, '{}')) x;
  if exists (select 1 from unnest(v) x where x not between 1 and 5) then
    raise exception 'Saturday numbers must be between 1 and 5';
  end if;
  select * into target from public.profiles where id = p_user for update;
  if target.id is null then raise exception 'User not found'; end if;
  if me.role <> 'Admin' and target.id <> me.id and target.role <> 'Employee' then
    raise exception 'Only an Admin can change HR / Admin accounts';
  end if;
  update public.profiles set saturday_off = v where id = p_user returning * into target;
  perform public._audit('SATURDAY_OFF', target.username || ' ' || coalesce(array_to_string(v, ','), 'none'));
  return target;
end $$;

-- Same setting for many employees at once (p_users null = every active employee)
create or replace function public.admin_set_saturdays_bulk(p_users uuid[], p_saturdays integer[])
returns integer
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._require_admin(); v integer[]; c integer;
begin
  select coalesce(array_agg(distinct x order by x), '{}') into v from unnest(coalesce(p_saturdays, '{}')) x;
  if exists (select 1 from unnest(v) x where x not between 1 and 5) then
    raise exception 'Saturday numbers must be between 1 and 5';
  end if;
  update public.profiles set saturday_off = v
   where active and (p_users is null or id = any(p_users))
     and (me.role = 'Admin' or role = 'Employee');
  get diagnostics c = row_count;
  perform public._audit('SATURDAY_OFF_BULK', c || ' employees -> ' || coalesce(array_to_string(v, ','), 'none'));
  return c;
end $$;

revoke execute on function public._is_weekly_off(uuid, date) from public, anon, authenticated;
revoke execute on function public.admin_set_saturdays(uuid, integer[]) from public, anon;
revoke execute on function public.admin_set_saturdays_bulk(uuid[], integer[]) from public, anon;
grant  execute on function public.admin_set_saturdays(uuid, integer[]) to authenticated;
grant  execute on function public.admin_set_saturdays_bulk(uuid[], integer[]) to authenticated;


-- ---------------------------------------------------------------------
-- 19. PAYROLL: monthly salary, overtime and the monthly paid-leave limit
--     * Salary is stored in its own table, readable by the Admin only (never by employees or HR).
--     * Paid leave: only `paid_leaves_per_month` (default 2) approved leave days per month are paid.
--       Leave beyond that, every Loss-of-Pay day and every Absent day are unpaid.
--     * Overtime: time worked beyond the shift length (min `overtime_min_minutes`) on a working day,
--       and all time worked on a weekly off / holiday.
--     * Pay per day = monthly salary / days in the month. Overtime hour = salary / (working days x shift hours) x multiplier.
-- ---------------------------------------------------------------------
create table if not exists public.employee_salary (
  user_id         uuid primary key references public.profiles(id) on delete cascade,
  monthly_salary  numeric(12,2) not null default 0 check (monthly_salary >= 0),
  updated_at      timestamptz not null default now()
);

create table if not exists public.payroll_settings (
  id                    integer primary key default 1 check (id = 1),
  paid_leaves_per_month integer not null default 2 check (paid_leaves_per_month >= 0),
  overtime_multiplier   numeric(4,2) not null default 1.00 check (overtime_multiplier >= 0),
  overtime_min_minutes  integer not null default 30 check (overtime_min_minutes >= 0)
);
insert into public.payroll_settings (id) values (1) on conflict (id) do nothing;

alter table public.employee_salary  enable row level security;
alter table public.payroll_settings enable row level security;
drop policy if exists salary_read on public.employee_salary;
create policy salary_read on public.employee_salary for select to authenticated using (public.is_full_admin());
drop policy if exists payroll_settings_read on public.payroll_settings;
create policy payroll_settings_read on public.payroll_settings for select to authenticated using (public.is_staff_admin());
revoke all on public.employee_salary, public.payroll_settings from anon;
grant select on public.employee_salary, public.payroll_settings to authenticated;

-- Admin only: set one employee's monthly salary
create or replace function public.admin_set_salary(p_user uuid, p_amount numeric)
returns numeric
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._require_full_admin(); target public.profiles;
begin
  if p_amount is null or p_amount < 0 then raise exception 'Enter a valid salary'; end if;
  select * into target from public.profiles where id = p_user;
  if target.id is null then raise exception 'User not found'; end if;
  insert into public.employee_salary (user_id, monthly_salary) values (p_user, round(p_amount, 2))
  on conflict (user_id) do update set monthly_salary = excluded.monthly_salary, updated_at = now();
  perform public._audit('SET_SALARY', target.username || ' = ' || round(p_amount, 2));
  return round(p_amount, 2);
end $$;

-- Overtime per day for one person and month (internal)
create or replace function public._month_overtime(p_user uuid, p_year int, p_month int)
returns table (day date, work_minutes int, shift_minutes int, ot_minutes int)
language sql stable security definer set search_path = public as $$
  select a.work_date, a.work_minutes,
         (extract(epoch from (p.shift_end - p.shift_start)) / 60)::int,
         case
           when not public._is_workday(p.id, a.work_date) then a.work_minutes
           when a.work_minutes - (extract(epoch from (p.shift_end - p.shift_start)) / 60)::int >= s.overtime_min_minutes
             then a.work_minutes - (extract(epoch from (p.shift_end - p.shift_start)) / 60)::int
           else 0 end
  from public.attendance a
  join public.profiles p on p.id = a.user_id
  cross join public.payroll_settings s
  where a.user_id = p_user and a.work_minutes is not null
    and a.work_date between make_date(p_year, p_month, 1)
                        and (make_date(p_year, p_month, 1) + interval '1 month - 1 day')::date
$$;

-- Admin / HR: every day with overtime in the month
create or replace function public.admin_overtime_days(p_year int, p_month int)
returns table (
  user_id uuid, username text, full_name text, department text, day date,
  in_time text, out_time text, work_minutes int, shift_minutes int, ot_minutes int
)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  perform public._require_admin();
  return query
  select p.id, p.username, p.full_name, p.department, o.day,
         to_char(a.check_in_at  at time zone 'Asia/Kolkata', 'HH24:MI'),
         to_char(a.check_out_at at time zone 'Asia/Kolkata', 'HH24:MI'),
         o.work_minutes, o.shift_minutes, o.ot_minutes
  from public.profiles p
  cross join lateral public._month_overtime(p.id, p_year, p_month) o
  join public.attendance a on a.user_id = p.id and a.work_date = o.day
  where p.active and o.ot_minutes > 0
  order by p.full_name, o.day;
end $$;

-- Admin only: salary sheet for a month
drop function if exists public.admin_payroll(int, int);
create or replace function public.admin_payroll(p_year int, p_month int)
returns table (
  user_id uuid, username text, full_name text, department text,
  monthly_salary numeric, days_in_month int, present int, absent int,
  leave_days int, paid_leave int, unpaid_leave int, not_joined int, unpaid_days int, payable_days int,
  overtime_hours numeric, overtime_pay numeric, deduction numeric, net_salary numeric
)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare
  st      public.payroll_settings;
  m0      date := make_date(p_year, p_month, 1);
  m1      date := (make_date(p_year, p_month, 1) + interval '1 month - 1 day')::date;
  v_dim   int  := extract(day from (make_date(p_year, p_month, 1) + interval '1 month - 1 day'))::int;
  rec     record;
  v_sal   numeric; v_pres int; v_abs int; v_l int; v_lop int; v_paid int; v_unpaid int; v_nj int;
  v_unpd  int; v_work int; v_ot int; v_hr numeric; v_otpay numeric; v_ded numeric; v_shift_h numeric;
begin
  perform public._require_full_admin();
  select * into st from public.payroll_settings where id = 1;
  for rec in select * from public.profiles where active order by full_name loop
    v_sal := coalesce((select es.monthly_salary from public.employee_salary es where es.user_id = rec.id), 0);

    select count(*) filter (where m.status in ('Present','Checked In')),
           count(*) filter (where m.status = 'Absent' and m.day < public.ist_today()
                                      and m.day >= coalesce(rec.joining_date, date '1900-01-01'))
      into v_pres, v_abs
      from public._month_attendance(rec.id, p_year, p_month) m;

    select coalesce(sum(u.days) filter (where lt.counts_balance), 0),
           coalesce(sum(u.days) filter (where not lt.counts_balance), 0)
      into v_l, v_lop
      from public._leave_usage(rec.id, m0, m1, array['Approved']) u
      join public.leave_types lt on lt.name = u.leave_type;

    v_paid   := least(v_l, st.paid_leaves_per_month);
    v_unpaid := v_l - v_paid + v_lop;
    v_nj     := case when rec.joining_date is null or rec.joining_date <= m0 then 0
                     else (least(rec.joining_date, m1 + 1) - m0) end;
    v_unpd   := least(v_dim, v_abs + v_unpaid + v_nj);

    select count(*) into v_work
      from generate_series(m0::timestamp, m1::timestamp, interval '1 day') g
     where public._is_workday(rec.id, g::date);
    v_shift_h := extract(epoch from (rec.shift_end - rec.shift_start)) / 3600;
    select coalesce(sum(o.ot_minutes), 0) into v_ot from public._month_overtime(rec.id, p_year, p_month) o;

    v_hr    := case when v_work > 0 and v_shift_h > 0 then v_sal / (v_work * v_shift_h) else 0 end;
    v_otpay := round(v_ot / 60.0 * v_hr * st.overtime_multiplier, 2);
    v_ded   := round(v_sal / v_dim * v_unpd, 2);

    return query select rec.id, rec.username, rec.full_name, rec.department, v_sal, v_dim, v_pres, v_abs,
                        v_l + v_lop, v_paid, v_unpaid, v_nj, v_unpd, v_dim - v_unpd,
                        round(v_ot / 60.0, 2), v_otpay, v_ded, round(v_sal - v_ded + v_otpay, 2);
  end loop;
end $$;

revoke execute on function public._month_overtime(uuid, int, int)  from public, anon, authenticated;
revoke execute on function public.admin_set_salary(uuid, numeric)  from public, anon;
revoke execute on function public.admin_overtime_days(int, int)    from public, anon;
revoke execute on function public.admin_payroll(int, int)          from public, anon;
grant  execute on function public.admin_set_salary(uuid, numeric)  to authenticated;
grant  execute on function public.admin_overtime_days(int, int)    to authenticated;
grant  execute on function public.admin_payroll(int, int)          to authenticated;


-- ---------------------------------------------------------------------
-- 20. YEARLY LEAVES PER EMPLOYEE
--     The Admin / HR sets how many days of each leave type an employee gets in a year.
--     The employee sees these numbers in the app (Leave -> balance). Without an entry the default
--     quota from leave_types is used.
-- ---------------------------------------------------------------------
alter table public.employee_leave_quota enable row level security;
drop policy if exists leave_quota_read on public.employee_leave_quota;
create policy leave_quota_read on public.employee_leave_quota for select to authenticated
  using (user_id = auth.uid() or public.is_staff_admin());
revoke all on public.employee_leave_quota from anon;
grant select on public.employee_leave_quota to authenticated;

-- p_quotas example: {"Casual Leave": 12, "Sick Leave": 10, "Annual Leave": 20}
create or replace function public.admin_set_leave_quota(p_user uuid, p_year integer, p_quotas jsonb)
returns integer
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._require_admin(); target public.profiles; k text; v integer; n integer := 0;
begin
  select * into target from public.profiles where id = p_user;
  if target.id is null then raise exception 'User not found'; end if;
  if me.role <> 'Admin' and target.id <> me.id and target.role <> 'Employee' then
    raise exception 'Only an Admin can change HR / Admin accounts';
  end if;
  if p_year is null or p_year not between 2000 and 2100 then raise exception 'Enter a valid year'; end if;
  if p_quotas is null or jsonb_typeof(p_quotas) <> 'object' then raise exception 'No leave quotas given'; end if;
  for k in select jsonb_object_keys(p_quotas) loop
    if not exists (select 1 from public.leave_types where name = k) then raise exception 'Unknown leave type: %', k; end if;
    v := (p_quotas ->> k)::integer;
    if v is null or v < 0 or v > 366 then raise exception 'Days for % must be between 0 and 366', k; end if;
    insert into public.employee_leave_quota (user_id, year, leave_type, quota) values (p_user, p_year, k, v)
    on conflict (user_id, year, leave_type) do update set quota = excluded.quota;
    n := n + 1;
  end loop;
  perform public._audit('SET_LEAVE_QUOTA', target.username || ' ' || p_year || ' ' || p_quotas::text);
  return n;
end $$;

revoke execute on function public.admin_set_leave_quota(uuid, integer, jsonb) from public, anon;
grant  execute on function public.admin_set_leave_quota(uuid, integer, jsonb) to authenticated;

do $$
begin
  if not exists (select 1 from pg_publication_tables
                  where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'employee_leave_quota') then
    alter publication supabase_realtime add table public.employee_leave_quota;
  end if;
end $$;


-- ---------------------------------------------------------------------
-- 21. DELETE SELFIE PHOTOS (Admin / HR)
--     The photo file is removed from the private "selfies" bucket and the record keeps its
--     time, place and distance, but no longer points to a photo.
-- ---------------------------------------------------------------------
drop policy if exists selfies_delete_staff on storage.objects;
create policy selfies_delete_staff on storage.objects for delete to authenticated
  using (bucket_id = 'selfies' and public.is_staff_admin());

-- Returns the photo path that was cleared (the app then deletes the file from storage)
create or replace function public.admin_clear_selfie_photo(p_id bigint)
returns text
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._require_admin(); r public.selfie_records; v_path text;
begin
  select * into r from public.selfie_records where id = p_id for update;
  if r.id is null then raise exception 'Selfie record not found'; end if;
  v_path := r.photo_path;
  update public.selfie_records set photo_path = null where id = p_id;
  perform public._audit('DELETE_SELFIE_PHOTO', 'record #' || p_id || ' ' || coalesce(v_path, '(no photo)'));
  return v_path;
end $$;

revoke execute on function public.admin_clear_selfie_photo(bigint) from public, anon;
grant  execute on function public.admin_clear_selfie_photo(bigint) to authenticated;


-- ---------------------------------------------------------------------
-- 22. APP UPDATES (Admin publishes a release; every phone and desktop signs out and loads the new version)
-- ---------------------------------------------------------------------
create table if not exists public.app_release (
  id            integer primary key default 1 check (id = 1),
  release       integer not null default 1,
  note          text,
  published_at  timestamptz not null default now(),
  published_by  uuid references public.profiles(id) on delete set null
);
insert into public.app_release (id) values (1) on conflict (id) do nothing;

alter table public.app_release enable row level security;
drop policy if exists app_release_read on public.app_release;
create policy app_release_read on public.app_release for select to anon, authenticated using (true);
grant select on public.app_release to anon, authenticated;

create or replace function public.admin_publish_update(p_note text default null)
returns public.app_release
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._require_admin(); r public.app_release;   -- Admin and HR can publish an update
begin
  update public.app_release
     set release = release + 1, note = nullif(trim(p_note), ''), published_at = now(), published_by = me.id
   where id = 1
  returning * into r;
  perform public._audit('PUBLISH_UPDATE', 'release ' || r.release || coalesce(' - ' || r.note, ''));
  return r;
end $$;

revoke execute on function public.admin_publish_update(text) from public, anon;
grant  execute on function public.admin_publish_update(text) to authenticated;

do $$
begin
  if not exists (select 1 from pg_publication_tables
                  where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'app_release') then
    alter publication supabase_realtime add table public.app_release;
  end if;
end $$;


-- ---------------------------------------------------------------------
-- 23. TRAVEL EMPLOYEES (two check-ins / check-outs per day, distance between the two sites)
--     * The Admin / HR switches "Travel Access" on for an employee.
--     * Such an employee checks in and out TWICE a day: Stop 1 (first site) and Stop 2 (other site).
--     * Location is required every time. A check-out must be made from the SAME place as that stop's
--       check-in (within 1 km), so nobody can check out far away to raise the kilometres.
--     * After the 2nd check-out the day is closed: no more check-in / check-out is accepted.
--     * Total km = straight-line distance from where Stop 1 was checked out to where Stop 2 was checked in.
--     * The attendance row keeps the day's FIRST check-in and the LAST check-out, so payroll / reports are unchanged.
-- ---------------------------------------------------------------------
alter table public.profiles   add column if not exists travel_access boolean not null default false;
alter table public.attendance add column if not exists travel_km numeric(8,1);

create table if not exists public.attendance_legs (
  id             bigint generated always as identity primary key,
  attendance_id  bigint not null references public.attendance(id) on delete cascade,
  user_id        uuid not null references public.profiles(id) on delete cascade,
  work_date      date not null,
  leg            smallint not null check (leg in (1, 2)),
  in_at          timestamptz not null default clock_timestamp(),
  in_lat         double precision not null,
  in_lng         double precision not null,
  out_at         timestamptz,
  out_lat        double precision,
  out_lng        double precision,
  unique (user_id, work_date, leg),
  check (out_at is null or out_at > in_at)
);
alter table public.attendance_legs alter column in_at set default clock_timestamp();
create index if not exists attendance_legs_att_idx on public.attendance_legs (attendance_id);

alter table public.attendance_legs enable row level security;
drop policy if exists legs_read on public.attendance_legs;
create policy legs_read on public.attendance_legs for select to authenticated
  using (user_id = auth.uid() or public.is_staff_admin());
revoke all on public.attendance_legs from anon;
grant select on public.attendance_legs to authenticated;

-- Admin / HR: grant or remove travel access
create or replace function public.admin_set_travel_access(p_user uuid, p_enabled boolean)
returns public.profiles
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._require_admin(); target public.profiles;
begin
  select * into target from public.profiles where id = p_user for update;
  if target.id is null then raise exception 'User not found'; end if;
  if me.role <> 'Admin' and target.id <> me.id and target.role <> 'Employee' then
    raise exception 'Only an Admin can change HR / Admin accounts';
  end if;
  update public.profiles set travel_access = p_enabled where id = p_user returning * into target;
  perform public._audit('TRAVEL_ACCESS', target.username || ' travel_access=' || p_enabled);
  return target;
end $$;

-- Today's travel status for one person (internal)
create or replace function public._travel_today(p_user uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'date',  public.ist_today(),
    'legs',  coalesce((select jsonb_agg(jsonb_build_object(
                'leg', l.leg, 'in_at', l.in_at, 'out_at', l.out_at,
                'in_lat', l.in_lat, 'in_lng', l.in_lng, 'out_lat', l.out_lat, 'out_lng', l.out_lng) order by l.leg)
              from public.attendance_legs l where l.user_id = p_user and l.work_date = public.ist_today()), '[]'::jsonb),
    'km',    (select a.travel_km from public.attendance a where a.user_id = p_user and a.work_date = public.ist_today()),
    'open',  exists (select 1 from public.attendance_legs l where l.user_id = p_user and l.work_date = public.ist_today() and l.out_at is null),
    'max_legs', 2
  )
$$;

create or replace function public.travel_today() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me public.profiles := public._require_active();
begin
  return public._travel_today(me.id);
end $$;

-- Stop 1 / Stop 2 check-in
create or replace function public.travel_check_in(
  p_lat double precision default null, p_lng double precision default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me    public.profiles := public._require_active();
  v_now timestamp := public.ist_now();
  a     public.attendance;
  n     int;
begin
  if not me.travel_access or me.site_employee then
    raise exception 'Travel attendance is not enabled for your account';
  end if;
  if p_lat is null or p_lng is null then
    raise exception 'Location is required. Turn on location and try again';
  end if;
  perform set_config('app.travel_rpc', 'on', true);

  insert into public.attendance (user_id, work_date, check_in_at, is_late, source, check_in_lat, check_in_lng)
  values (me.id, v_now::date, now(), date_trunc('minute', v_now)::time > me.shift_start, 'office', p_lat, p_lng)
  on conflict (user_id, work_date) do nothing;
  select * into a from public.attendance where user_id = me.id and work_date = v_now::date for update;

  select count(*) into n from public.attendance_legs where attendance_id = a.id;
  if exists (select 1 from public.attendance_legs where attendance_id = a.id and out_at is null) then
    raise exception 'You are already checked in. Check out first';
  end if;
  if n >= 2 then
    raise exception 'You have already completed both check-ins for today';
  end if;
  if n = 0 and a.check_out_at is not null then
    raise exception 'You have already checked out today';
  end if;

  insert into public.attendance_legs (attendance_id, user_id, work_date, leg, in_lat, in_lng)
  values (a.id, me.id, a.work_date, n + 1, p_lat, p_lng);
  if n = 1 then   -- back at work: the day is open again until the 2nd check-out
    update public.attendance set check_out_at = null, check_out_lat = null, check_out_lng = null where id = a.id;
  end if;
  perform public._audit('TRAVEL_CHECK_IN', 'stop ' || (n + 1) || ' ' || to_char(v_now, 'HH24:MI'));
  return public._travel_today(me.id);
end $$;

-- Stop 1 / Stop 2 check-out (must be made from the place of that stop's check-in)
create or replace function public.travel_check_out(
  p_lat double precision default null, p_lng double precision default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me    public.profiles := public._require_active();
  v_now timestamp := public.ist_now();
  lg    public.attendance_legs;
  l1    public.attendance_legs;
  d     double precision;
begin
  if not me.travel_access or me.site_employee then
    raise exception 'Travel attendance is not enabled for your account';
  end if;
  if p_lat is null or p_lng is null then
    raise exception 'Location is required. Turn on location and try again';
  end if;
  perform set_config('app.travel_rpc', 'on', true);

  select * into lg from public.attendance_legs
   where user_id = me.id and work_date = v_now::date and out_at is null
   order by leg desc limit 1 for update;
  if lg.id is null then
    raise exception 'No check-in to close. Check in first (or both check-outs are already done today)';
  end if;

  d := public._distance_m(lg.in_lat, lg.in_lng, p_lat, p_lng);
  if d > 1000 then
    raise exception 'Check out from the same place where you checked in (you are % m away)', round(d);
  end if;

  update public.attendance_legs set out_at = clock_timestamp(), out_lat = p_lat, out_lng = p_lng where id = lg.id;
  update public.attendance set check_out_at = clock_timestamp(), check_out_lat = p_lat, check_out_lng = p_lng
   where id = lg.attendance_id;

  if lg.leg = 2 then
    select * into l1 from public.attendance_legs where attendance_id = lg.attendance_id and leg = 1;
    update public.attendance
       set travel_km = round((public._distance_m(l1.out_lat, l1.out_lng, lg.in_lat, lg.in_lng) / 1000)::numeric, 1)
     where id = lg.attendance_id;
  end if;
  perform public._audit('TRAVEL_CHECK_OUT', 'stop ' || lg.leg || ' ' || to_char(v_now, 'HH24:MI'));
  return public._travel_today(me.id);
end $$;

-- Travel employees must use the travel functions: the plain check-in / check-out is refused for them
create or replace function public._travel_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare p public.profiles;
begin
  if auth.uid() is null or auth.uid() <> new.user_id then return new; end if;
  if coalesce(current_setting('app.travel_rpc', true), '') = 'on' then return new; end if;
  select * into p from public.profiles where id = new.user_id;
  if p.travel_access and not p.site_employee then
    if tg_op = 'INSERT' then
      raise exception 'Travel employees must use the travel check-in';
    elsif new.check_out_at is distinct from old.check_out_at then
      raise exception 'Travel employees must use the travel check-out';
    end if;
  end if;
  return new;
end $$;

drop trigger if exists attendance_travel_guard on public.attendance;
create trigger attendance_travel_guard before insert or update on public.attendance
  for each row execute function public._travel_guard();

-- Admin / HR: travel report (one row per travelling day)
-- (dropped first: later sections change its columns, and CREATE OR REPLACE cannot change them on a database that already has the newer one)
drop function if exists public.admin_travel_report(date, date);
create or replace function public.admin_travel_report(p_from date, p_to date)
returns table (
  user_id uuid, username text, full_name text, department text, work_date date,
  s1_in text, s1_out text, s2_in text, s2_out text, km numeric
)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  perform public._require_admin();
  return query
  select p.id, p.username, p.full_name, p.department, a.work_date,
         to_char(l1.in_at  at time zone 'Asia/Kolkata', 'HH24:MI'),
         to_char(l1.out_at at time zone 'Asia/Kolkata', 'HH24:MI'),
         to_char(l2.in_at  at time zone 'Asia/Kolkata', 'HH24:MI'),
         to_char(l2.out_at at time zone 'Asia/Kolkata', 'HH24:MI'),
         a.travel_km
  from public.attendance a
  join public.profiles p on p.id = a.user_id
  join public.attendance_legs l1 on l1.attendance_id = a.id and l1.leg = 1
  left join public.attendance_legs l2 on l2.attendance_id = a.id and l2.leg = 2
  where a.work_date between p_from and p_to
  order by a.work_date desc, p.full_name;
end $$;

revoke execute on function public._travel_today(uuid) from public, anon, authenticated;
revoke execute on function public._travel_guard() from public, anon, authenticated;
revoke execute on function public.admin_set_travel_access(uuid, boolean) from public, anon;
revoke execute on function public.travel_today() from public, anon;
revoke execute on function public.travel_check_in(double precision, double precision) from public, anon;
revoke execute on function public.travel_check_out(double precision, double precision) from public, anon;
revoke execute on function public.admin_travel_report(date, date) from public, anon;
grant  execute on function public.admin_set_travel_access(uuid, boolean) to authenticated;
grant  execute on function public.travel_today() to authenticated;
grant  execute on function public.travel_check_in(double precision, double precision) to authenticated;
grant  execute on function public.travel_check_out(double precision, double precision) to authenticated;
grant  execute on function public.admin_travel_report(date, date) to authenticated;


-- ---------------------------------------------------------------------
-- 24. DELETE A WORK SITE (Admin only)
--     Past attendance and selfie records keep the site NAME as text, so history is not affected.
-- ---------------------------------------------------------------------
create or replace function public.admin_delete_site(p_id bigint) returns text
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._require_full_admin(); r public.sites;
begin
  delete from public.sites where id = p_id returning * into r;
  if r.id is null then raise exception 'Site not found'; end if;
  perform public._audit('DELETE_SITE', r.name);
  return r.name;
end $$;

revoke execute on function public.admin_delete_site(bigint) from public, anon;
grant  execute on function public.admin_delete_site(bigint) to authenticated;

-- ---------------------------------------------------------------------
-- 25. SITE ACCESS PER EMPLOYEE (Admin / HR decide which work sites each employee may use)
--     * An employee with NO assigned site can use every active site (as before).
--     * Once one or more sites are assigned, the employee can check in / out only at those sites.
--     * Enforced in the database: choosing another site is refused.
-- ---------------------------------------------------------------------
create table if not exists public.employee_sites (
  user_id  uuid   not null references public.profiles(id) on delete cascade,
  site_id  bigint not null references public.sites(id) on delete cascade,
  primary key (user_id, site_id)
);
alter table public.employee_sites enable row level security;
drop policy if exists employee_sites_read on public.employee_sites;
create policy employee_sites_read on public.employee_sites for select to authenticated
  using (user_id = auth.uid() or public.is_staff_admin());
revoke all on public.employee_sites from anon;
grant select on public.employee_sites to authenticated;

-- Replaces the employee's assigned sites with exactly p_site_ids (empty = all sites allowed)
create or replace function public.admin_set_employee_sites(p_user uuid, p_site_ids bigint[])
returns integer
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._require_admin(); target public.profiles; v bigint[]; n integer;
begin
  select * into target from public.profiles where id = p_user;
  if target.id is null then raise exception 'User not found'; end if;
  if me.role <> 'Admin' and target.id <> me.id and target.role <> 'Employee' then
    raise exception 'Only an Admin can change HR / Admin accounts';
  end if;
  select coalesce(array_agg(distinct s.id), '{}') into v
    from public.sites s where s.id = any(coalesce(p_site_ids, '{}'));
  delete from public.employee_sites where user_id = p_user and not (site_id = any(v));
  insert into public.employee_sites (user_id, site_id)
    select p_user, x from unnest(v) x on conflict do nothing;
  n := coalesce(array_length(v, 1), 0);
  perform public._audit('SET_EMPLOYEE_SITES', target.username || ' -> ' || n || ' site(s)');
  return n;
end $$;

-- Geofence check now also enforces the employee's assigned sites
create or replace function public._geofence_check(
  p_site_id bigint, p_lat double precision, p_lng double precision
) returns table (site_name text, distance_m integer, inside boolean)
language plpgsql stable security definer set search_path = public as $$
declare s public.sites; d double precision;
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
  return query select s.name, round(d)::integer, (d is not null and d <= s.radius_m);
end $$;

revoke execute on function public.admin_set_employee_sites(uuid, bigint[]) from public, anon;
grant  execute on function public.admin_set_employee_sites(uuid, bigint[]) to authenticated;

-- ---------------------------------------------------------------------
-- 26. TRAVEL BETWEEN TWO WORK SITES (site-selfie employees with Travel Access)
--     * Stop 1: check in (selfie + site) and check out at the first site.
--     * Stop 2: check in (selfie + a DIFFERENT site) and check out at the second site.
--     * After the 2nd check-out the day is closed and the distance between the two sites is saved
--       (straight line from where Stop 1 was checked out to where Stop 2 was checked in).
--     * Each check-out must be made from the place of that stop's check-in (within 1 km).
--     * Admin / HR see the km and both site names in the Travel Report.
-- ---------------------------------------------------------------------
alter table public.attendance_legs add column if not exists site_id   bigint references public.sites(id) on delete set null;
alter table public.attendance_legs add column if not exists site_name text;

create or replace function public._travel_today(p_user uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'date',  public.ist_today(),
    'legs',  coalesce((select jsonb_agg(jsonb_build_object(
                'leg', l.leg, 'in_at', l.in_at, 'out_at', l.out_at, 'site_id', l.site_id, 'site_name', l.site_name,
                'in_lat', l.in_lat, 'in_lng', l.in_lng, 'out_lat', l.out_lat, 'out_lng', l.out_lng) order by l.leg)
              from public.attendance_legs l where l.user_id = p_user and l.work_date = public.ist_today()), '[]'::jsonb),
    'km',    (select a.travel_km from public.attendance a where a.user_id = p_user and a.work_date = public.ist_today()),
    'open',  exists (select 1 from public.attendance_legs l where l.user_id = p_user and l.work_date = public.ist_today() and l.out_at is null),
    'max_legs', 2
  )
$$;

create or replace function public.site_travel_check_in(
  p_lat double precision default null, p_lng double precision default null,
  p_site_id bigint default null, p_site_name text default null,
  p_note text default null, p_photo_path text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me        public.profiles := public._require_active();
  v_now     timestamp := public.ist_now();
  a         public.attendance;
  prev      public.attendance_legs;
  g         record;
  v_outside boolean;
  n         int;
begin
  if not (me.travel_access and me.site_employee) then
    raise exception 'Site travel attendance is not enabled for your account';
  end if;
  if p_lat is null or p_lng is null then
    raise exception 'Location is required. Turn on location and try again';
  end if;
  perform set_config('app.travel_rpc', 'on', true);

  select * into g from public._geofence_check(p_site_id, p_lat, p_lng);
  v_outside := not g.inside;
  p_site_name := coalesce(g.site_name, p_site_name);
  if nullif(trim(p_site_name),'') is null then raise exception 'Select the work site before submitting'; end if;
  if v_outside then p_photo_path := null;
  elsif p_photo_path is null or split_part(p_photo_path, '/', 1) <> me.id::text then
    raise exception 'Take a selfie first';
  end if;

  insert into public.attendance (user_id, work_date, check_in_at, is_late, source, site_name, note, check_in_lat, check_in_lng)
  values (me.id, v_now::date, now(), date_trunc('minute', v_now)::time > me.shift_start, 'site',
          trim(p_site_name), nullif(trim(p_note),''), p_lat, p_lng)
  on conflict (user_id, work_date) do nothing;
  select * into a from public.attendance where user_id = me.id and work_date = v_now::date for update;

  select count(*) into n from public.attendance_legs where attendance_id = a.id;
  if exists (select 1 from public.attendance_legs where attendance_id = a.id and out_at is null) then
    raise exception 'You are already checked in. Check out first';
  end if;
  if n >= 2 then raise exception 'You have already completed both stops for today'; end if;
  if n = 0 and a.check_out_at is not null then raise exception 'You have already checked out today'; end if;
  if n = 1 then
    select * into prev from public.attendance_legs where attendance_id = a.id and leg = 1;
    if prev.site_id is not distinct from p_site_id then
      raise exception 'Stop 2 must be at a different work site than Stop 1 (%)', prev.site_name;
    end if;
    update public.attendance set check_out_at = null, check_out_lat = null, check_out_lng = null where id = a.id;
  end if;

  insert into public.attendance_legs (attendance_id, user_id, work_date, leg, in_lat, in_lng, site_id, site_name)
  values (a.id, me.id, a.work_date, n + 1, p_lat, p_lng, p_site_id, trim(p_site_name));
  insert into public.selfie_records (user_id, attendance_id, kind, site_name, note, photo_path, lat, lng, outside, distance_m)
  values (me.id, a.id, 'IN', trim(p_site_name), nullif(trim(p_note),''), p_photo_path, p_lat, p_lng, v_outside, g.distance_m);
  perform public._audit('SITE_TRAVEL_CHECK_IN', 'stop ' || (n + 1) || ' ' || trim(p_site_name));
  return public._travel_today(me.id);
end $$;

create or replace function public.site_travel_check_out(
  p_lat double precision default null, p_lng double precision default null,
  p_note text default null, p_photo_path text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me        public.profiles := public._require_active();
  v_now     timestamp := public.ist_now();
  lg        public.attendance_legs;
  l1        public.attendance_legs;
  g         record;
  v_outside boolean;
  d         double precision;
begin
  if not (me.travel_access and me.site_employee) then
    raise exception 'Site travel attendance is not enabled for your account';
  end if;
  if p_lat is null or p_lng is null then
    raise exception 'Location is required. Turn on location and try again';
  end if;
  perform set_config('app.travel_rpc', 'on', true);

  select * into lg from public.attendance_legs
   where user_id = me.id and work_date = v_now::date and out_at is null
   order by leg desc limit 1 for update;
  if lg.id is null then raise exception 'No check-in to close. Check in first'; end if;

  d := public._distance_m(lg.in_lat, lg.in_lng, p_lat, p_lng);
  if d > 1000 then
    raise exception 'Check out from the same place where you checked in (you are % m away)', round(d);
  end if;

  select * into g from public._geofence_check(lg.site_id, p_lat, p_lng);
  v_outside := not g.inside;
  if v_outside then p_photo_path := null;
  else
    if p_photo_path is null or split_part(p_photo_path, '/', 1) <> me.id::text then raise exception 'Take a selfie first'; end if;
    if exists (select 1 from public.selfie_records where attendance_id = lg.attendance_id and photo_path = p_photo_path) then
      raise exception 'Check-out needs a new selfie, different from the check-in selfie';
    end if;
  end if;

  update public.attendance_legs set out_at = clock_timestamp(), out_lat = p_lat, out_lng = p_lng where id = lg.id;
  update public.attendance set check_out_at = clock_timestamp(), check_out_lat = p_lat, check_out_lng = p_lng,
         note = coalesce(nullif(trim(p_note),''), note)
   where id = lg.attendance_id;
  if lg.leg = 2 then
    select * into l1 from public.attendance_legs where attendance_id = lg.attendance_id and leg = 1;
    update public.attendance
       set travel_km = round((public._distance_m(l1.out_lat, l1.out_lng, lg.in_lat, lg.in_lng) / 1000)::numeric, 1)
     where id = lg.attendance_id;
  end if;
  insert into public.selfie_records (user_id, attendance_id, kind, site_name, note, photo_path, lat, lng, outside, distance_m)
  values (me.id, lg.attendance_id, 'OUT', coalesce(lg.site_name, '-'), nullif(trim(p_note),''), p_photo_path, p_lat, p_lng, v_outside, g.distance_m);
  perform public._audit('SITE_TRAVEL_CHECK_OUT', 'stop ' || lg.leg || ' ' || coalesce(lg.site_name, ''));
  return public._travel_today(me.id);
end $$;

-- Every travel employee (site or office) must use the travel functions
create or replace function public._travel_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare p public.profiles;
begin
  if auth.uid() is null or auth.uid() <> new.user_id then return new; end if;
  if coalesce(current_setting('app.travel_rpc', true), '') = 'on' then return new; end if;
  select * into p from public.profiles where id = new.user_id;
  if p.travel_access then
    if tg_op = 'INSERT' then
      raise exception 'Travel employees must use the travel check-in';
    elsif new.check_out_at is distinct from old.check_out_at then
      raise exception 'Travel employees must use the travel check-out';
    end if;
  end if;
  return new;
end $$;

-- Travel report now also lists the two site names
drop function if exists public.admin_travel_report(date, date);
create or replace function public.admin_travel_report(p_from date, p_to date)
returns table (
  user_id uuid, username text, full_name text, department text, work_date date,
  s1_site text, s1_in text, s1_out text, s2_site text, s2_in text, s2_out text, km numeric
)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  perform public._require_admin();
  return query
  select p.id, p.username, p.full_name, p.department, a.work_date,
         l1.site_name,
         to_char(l1.in_at  at time zone 'Asia/Kolkata', 'HH24:MI'),
         to_char(l1.out_at at time zone 'Asia/Kolkata', 'HH24:MI'),
         l2.site_name,
         to_char(l2.in_at  at time zone 'Asia/Kolkata', 'HH24:MI'),
         to_char(l2.out_at at time zone 'Asia/Kolkata', 'HH24:MI'),
         a.travel_km
  from public.attendance a
  join public.profiles p on p.id = a.user_id
  join public.attendance_legs l1 on l1.attendance_id = a.id and l1.leg = 1
  left join public.attendance_legs l2 on l2.attendance_id = a.id and l2.leg = 2
  where a.work_date between p_from and p_to
  order by a.work_date desc, p.full_name;
end $$;

revoke execute on function public.site_travel_check_in(double precision, double precision, bigint, text, text, text) from public, anon;
revoke execute on function public.site_travel_check_out(double precision, double precision, text, text) from public, anon;
revoke execute on function public.admin_travel_report(date, date) from public, anon;
revoke execute on function public._travel_today(uuid) from public, anon, authenticated;
revoke execute on function public._travel_guard() from public, anon, authenticated;
grant  execute on function public.site_travel_check_in(double precision, double precision, bigint, text, text, text) to authenticated;
grant  execute on function public.site_travel_check_out(double precision, double precision, text, text) to authenticated;
grant  execute on function public.admin_travel_report(date, date) to authenticated;

-- ---------------------------------------------------------------------
-- 27. LIVE LOCATION WHILE ON A VISIT OR TRAVELLING BETWEEN SITES
--     * The app of an employee who is ON A FIELD VISIT (started, not ended) or BETWEEN TWO TRAVEL STOPS
--       (checked in at a stop, not yet checked out) sends its position every ~45 seconds.
--     * The database accepts a position ONLY while such an activity is open. At any other time
--       the employee's last position is deleted and nothing is stored.
--     * Admin / HR see these live positions on the Live Map.
-- ---------------------------------------------------------------------
create table if not exists public.live_locations (
  user_id     uuid primary key references public.profiles(id) on delete cascade,
  lat         double precision not null,
  lng         double precision not null,
  accuracy_m  integer,
  kind        text not null check (kind in ('visit','travel')),
  updated_at  timestamptz not null default now()
);
alter table public.live_locations enable row level security;
drop policy if exists live_locations_read on public.live_locations;
create policy live_locations_read on public.live_locations for select to authenticated
  using (user_id = auth.uid() or public.is_staff_admin());
revoke all on public.live_locations from anon;
grant select on public.live_locations to authenticated;

-- 'visit' | 'travel' | null for the signed-in user (null = nothing to track)
create or replace function public._tracking_kind(p_user uuid) returns text
language sql stable security definer set search_path = public as $$
  select case
    when exists (select 1 from public.visits v where v.user_id = p_user and v.end_at is null) then 'visit'
    when exists (select 1 from public.attendance_legs l where l.user_id = p_user and l.out_at is null
                   and l.work_date = public.ist_today()) then 'travel'
    else null end
$$;

create or replace function public.live_tracking_active() returns text
language plpgsql stable security definer set search_path = public as $$
declare me public.profiles := public._require_active();
begin
  return public._tracking_kind(me.id);
end $$;

create or replace function public.report_location(
  p_lat double precision, p_lng double precision, p_accuracy integer default null
) returns text
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._require_active(); k text;
begin
  k := public._tracking_kind(me.id);
  if k is null then
    delete from public.live_locations where user_id = me.id;   -- nothing to track: nothing is kept
    return null;
  end if;
  if p_lat is null or p_lng is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 then
    raise exception 'Invalid location';
  end if;
  insert into public.live_locations (user_id, lat, lng, accuracy_m, kind, updated_at)
  values (me.id, p_lat, p_lng, p_accuracy, k, now())
  on conflict (user_id) do update
     set lat = excluded.lat, lng = excluded.lng, accuracy_m = excluded.accuracy_m, kind = excluded.kind, updated_at = now();
  return k;
end $$;

-- The live position disappears as soon as the visit ends / the travel stop is checked out
create or replace function public._clear_live_location() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public._tracking_kind(new.user_id) is null then
    delete from public.live_locations where user_id = new.user_id;
  end if;
  return new;
end $$;
drop trigger if exists visits_clear_live on public.visits;
create trigger visits_clear_live after update on public.visits
  for each row execute function public._clear_live_location();
drop trigger if exists legs_clear_live on public.attendance_legs;
create trigger legs_clear_live after update on public.attendance_legs
  for each row execute function public._clear_live_location();

revoke execute on function public._tracking_kind(uuid) from public, anon, authenticated;
revoke execute on function public._clear_live_location() from public, anon, authenticated;
revoke execute on function public.live_tracking_active() from public, anon;
revoke execute on function public.report_location(double precision, double precision, integer) from public, anon;
grant  execute on function public.live_tracking_active() to authenticated;
grant  execute on function public.report_location(double precision, double precision, integer) to authenticated;

do $$
begin
  if not exists (select 1 from pg_publication_tables
                  where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'live_locations') then
    alter publication supabase_realtime add table public.live_locations;
  end if;
end $$;

-- Make the API see the new table straight away (clears the 'schema cache' error)

-- ---------------------------------------------------------------------
-- 28. LEAVE MUST BE APPLIED AT LEAST 2 DAYS IN ADVANCE
--     A leave whose first day is today, tomorrow or in the past is refused.
--     (Today 19 Oct: the earliest first day is 21 Oct.)
-- ---------------------------------------------------------------------
create or replace function public.apply_leave(p_leave_type text, p_from date, p_to date, p_reason text)
returns public.leaves
language plpgsql security definer set search_path = public as $$
declare
  me     public.profiles := public._require_active();
  t      public.leave_types;
  v_days int;
  v_bal  int;
  r      public.leaves;
begin
  select * into t from public.leave_types where name = p_leave_type and active;
  if t.name is null then raise exception 'Unknown leave type'; end if;
  if p_to < p_from then raise exception 'End date cannot be before start date'; end if;
  if p_from < public.ist_today() + 2 then
    raise exception 'Leave must be applied at least 2 days in advance. The earliest start date is %', to_char(public.ist_today() + 2, 'DD-MM-YYYY');
  end if;
  if nullif(trim(p_reason),'') is null then raise exception 'Enter a reason'; end if;
  if extract(year from p_from) <> extract(year from p_to) then
    raise exception 'Submit one calendar year per request';
  end if;
  -- working days in the range + sandwiched weekly offs (also joined with the person's other pending / approved leave)
  select coalesce(sum(u.days), 0)::int into v_days
    from public._leave_usage(me.id, p_from - 10, p_to + 10, array['Approved','Pending'], p_from, p_to, null) u
   where u.leave_type = 'NEW';
  if v_days = 0 then raise exception 'No working days in the selected period (weekly off / holiday only)'; end if;

  if exists (select 1 from public.leaves
              where user_id = me.id and status in ('Pending','Approved')
                and from_day <= p_to and to_day >= p_from) then
    raise exception 'These dates overlap with another leave request';
  end if;

  if t.counts_balance then
    select b.balance into v_bal from public._leave_balance(me.id, extract(year from p_from)::int) b
     where b.leave_type = t.name;
    if v_days > coalesce(v_bal, 0) then
      raise exception 'Insufficient leave balance (% day(s) available)', coalesce(v_bal,0);
    end if;
  end if;

  insert into public.leaves (user_id, leave_type, from_day, to_day, days, reason)
  values (me.id, t.name, p_from, p_to, v_days, trim(p_reason))
  returning * into r;
  perform public._audit('LEAVE_REQUEST', t.name || ' ' || p_from || ' to ' || p_to);
  return r;
end $$;

revoke execute on function public.apply_leave(text, date, date, text) from public, anon;
grant  execute on function public.apply_leave(text, date, date, text) to authenticated;

-- ---------------------------------------------------------------------
-- 29. MANY STOPS A DAY + REAL ROUTE DISTANCE (travel employees)
--     * A travel employee can check in and out at any number of work sites in one day
--       (A, then B, then A again ...). The next stop must be a different site than the previous one.
--     * Each move from one stop to the next is one TRIP. Its distance is the real route walked / driven,
--       added up from the live GPS points sent between "check-out at the old stop" and "check-in at the new stop".
--       If no GPS points arrived (phone off / app closed) the straight-line distance is used and marked 'straight'.
--       The route distance is never shorter than the straight line.
--     * Live GPS is sent from the first check-in until the employee presses "Finish travel day".
--     * Report: stops, trips and km per day; visits per site come from the stop list.
-- ---------------------------------------------------------------------
alter table public.attendance      add column if not exists travel_done boolean not null default false;
alter table public.attendance_legs add column if not exists trip_km     numeric(8,1);
alter table public.attendance_legs add column if not exists trip_source text;       -- 'gps' | 'straight'
alter table public.attendance_legs drop constraint if exists attendance_legs_leg_check;
alter table public.attendance_legs add constraint attendance_legs_leg_check check (leg between 1 and 30);

-- The GPS trail (kept only while a travel day is running)
create table if not exists public.travel_track (
  id           bigint generated always as identity primary key,
  user_id      uuid not null references public.profiles(id) on delete cascade,
  recorded_at  timestamptz not null default clock_timestamp(),
  lat          double precision not null,
  lng          double precision not null,
  accuracy_m   integer
);
create index if not exists travel_track_user_time_idx on public.travel_track (user_id, recorded_at);
alter table public.travel_track enable row level security;
drop policy if exists travel_track_read on public.travel_track;
create policy travel_track_read on public.travel_track for select to authenticated
  using (user_id = auth.uid() or public.is_staff_admin());
revoke all on public.travel_track from anon;
grant select on public.travel_track to authenticated;

-- Real route length between two stops from the GPS points in between (jitter under 25 m is ignored)
create or replace function public._route_km(
  p_user uuid, p_from timestamptz, p_to timestamptz,
  lat1 double precision, lng1 double precision, lat2 double precision, lng2 double precision
) returns table (km numeric, source text)
language plpgsql stable security definer set search_path = public as $$
declare r record; la double precision := lat1; lo double precision := lng1;
        total double precision := 0; n int := 0; d double precision; straight double precision;
begin
  straight := public._distance_m(lat1, lng1, lat2, lng2);
  for r in select t.lat, t.lng from public.travel_track t
            where t.user_id = p_user and t.recorded_at > p_from and t.recorded_at < p_to
              and coalesce(t.accuracy_m, 0) <= 100
            order by t.recorded_at loop
    d := public._distance_m(la, lo, r.lat, r.lng);
    if d >= 25 then total := total + d; la := r.lat; lo := r.lng; n := n + 1; end if;
  end loop;
  total := total + public._distance_m(la, lo, lat2, lng2);
  if n = 0 then
    return query select round((straight / 1000)::numeric, 1), 'straight'::text;
  else
    return query select round((greatest(total, straight) / 1000)::numeric, 1), 'gps'::text;
  end if;
end $$;

-- After a check-in at stop n (n >= 2): store the trip km and refresh the day total
create or replace function public._record_trip(p_leg_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare cur public.attendance_legs; prev public.attendance_legs; r record;
begin
  select * into cur from public.attendance_legs where id = p_leg_id;
  select * into prev from public.attendance_legs where attendance_id = cur.attendance_id and leg = cur.leg - 1;
  if prev.id is null or prev.out_at is null or prev.out_lat is null then return; end if;
  select * into r from public._route_km(cur.user_id, prev.out_at, cur.in_at, prev.out_lat, prev.out_lng, cur.in_lat, cur.in_lng);
  update public.attendance_legs set trip_km = r.km, trip_source = r.source where id = cur.id;
  update public.attendance
     set travel_km = (select coalesce(sum(l.trip_km), 0) from public.attendance_legs l where l.attendance_id = cur.attendance_id)
   where id = cur.attendance_id;
end $$;

create or replace function public._travel_today(p_user uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'date',  public.ist_today(),
    'legs',  coalesce((select jsonb_agg(jsonb_build_object(
                'leg', l.leg, 'in_at', l.in_at, 'out_at', l.out_at, 'site_id', l.site_id, 'site_name', l.site_name,
                'in_lat', l.in_lat, 'in_lng', l.in_lng, 'out_lat', l.out_lat, 'out_lng', l.out_lng,
                'trip_km', l.trip_km, 'trip_source', l.trip_source) order by l.leg)
              from public.attendance_legs l where l.user_id = p_user and l.work_date = public.ist_today()), '[]'::jsonb),
    'km',    (select a.travel_km from public.attendance a where a.user_id = p_user and a.work_date = public.ist_today()),
    'open',  exists (select 1 from public.attendance_legs l where l.user_id = p_user and l.work_date = public.ist_today() and l.out_at is null),
    'done',  coalesce((select a.travel_done from public.attendance a where a.user_id = p_user and a.work_date = public.ist_today()), false),
    'max_legs', 30
  )
$$;

-- Live GPS runs from the first stop until "Finish travel day" (so the road between stops is tracked)
create or replace function public._tracking_kind(p_user uuid) returns text
language sql stable security definer set search_path = public as $$
  select case
    when exists (select 1 from public.visits v where v.user_id = p_user and v.end_at is null) then 'visit'
    when exists (select 1 from public.attendance_legs l where l.user_id = p_user and l.out_at is null
                   and l.work_date = public.ist_today()) then 'travel'
    when exists (select 1 from public.attendance a
                  where a.user_id = p_user and a.work_date = public.ist_today() and not a.travel_done
                    and exists (select 1 from public.attendance_legs l where l.attendance_id = a.id)) then 'travel'
    else null end
$$;

create or replace function public.report_location(
  p_lat double precision, p_lng double precision, p_accuracy integer default null
) returns text
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._require_active(); k text;
begin
  k := public._tracking_kind(me.id);
  if k is null then
    delete from public.live_locations where user_id = me.id;
    return null;
  end if;
  if p_lat is null or p_lng is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 then
    raise exception 'Invalid location';
  end if;
  insert into public.live_locations (user_id, lat, lng, accuracy_m, kind, updated_at)
  values (me.id, p_lat, p_lng, p_accuracy, k, now())
  on conflict (user_id) do update
     set lat = excluded.lat, lng = excluded.lng, accuracy_m = excluded.accuracy_m, kind = excluded.kind, updated_at = now();
  if k = 'travel' then
    insert into public.travel_track (user_id, recorded_at, lat, lng, accuracy_m) values (me.id, clock_timestamp(), p_lat, p_lng, p_accuracy);
  end if;
  return k;
end $$;

-- Office travel (location only, no site names): any number of stops
create or replace function public.travel_check_in(
  p_lat double precision default null, p_lng double precision default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me    public.profiles := public._require_active();
  v_now timestamp := public.ist_now();
  a     public.attendance;
  n     int;
  lid   bigint;
begin
  if not me.travel_access or me.site_employee then
    raise exception 'Travel attendance is not enabled for your account';
  end if;
  if p_lat is null or p_lng is null then
    raise exception 'Location is required. Turn on location and try again';
  end if;
  perform set_config('app.travel_rpc', 'on', true);

  insert into public.attendance (user_id, work_date, check_in_at, is_late, source, check_in_lat, check_in_lng)
  values (me.id, v_now::date, now(), date_trunc('minute', v_now)::time > me.shift_start, 'office', p_lat, p_lng)
  on conflict (user_id, work_date) do nothing;
  select * into a from public.attendance where user_id = me.id and work_date = v_now::date for update;

  if a.travel_done then raise exception 'You have already finished your travel day'; end if;
  select count(*) into n from public.attendance_legs where attendance_id = a.id;
  if exists (select 1 from public.attendance_legs where attendance_id = a.id and out_at is null) then
    raise exception 'You are already checked in. Check out first';
  end if;
  if n >= 30 then raise exception 'Maximum 30 stops a day reached'; end if;
  if n = 0 and a.check_out_at is not null then raise exception 'You have already checked out today'; end if;

  insert into public.attendance_legs (attendance_id, user_id, work_date, leg, in_lat, in_lng)
  values (a.id, me.id, a.work_date, n + 1, p_lat, p_lng) returning id into lid;
  if n >= 1 then
    update public.attendance set check_out_at = null, check_out_lat = null, check_out_lng = null where id = a.id;
    perform public._record_trip(lid);
  end if;
  perform public._audit('TRAVEL_CHECK_IN', 'stop ' || (n + 1) || ' ' || to_char(v_now, 'HH24:MI'));
  return public._travel_today(me.id);
end $$;

create or replace function public.travel_check_out(
  p_lat double precision default null, p_lng double precision default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me    public.profiles := public._require_active();
  v_now timestamp := public.ist_now();
  lg    public.attendance_legs;
  d     double precision;
begin
  if not me.travel_access or me.site_employee then
    raise exception 'Travel attendance is not enabled for your account';
  end if;
  if p_lat is null or p_lng is null then
    raise exception 'Location is required. Turn on location and try again';
  end if;
  perform set_config('app.travel_rpc', 'on', true);

  select * into lg from public.attendance_legs
   where user_id = me.id and work_date = v_now::date and out_at is null
   order by leg desc limit 1 for update;
  if lg.id is null then raise exception 'No check-in to close. Check in first'; end if;

  d := public._distance_m(lg.in_lat, lg.in_lng, p_lat, p_lng);
  if d > 1000 then
    raise exception 'Check out from the same place where you checked in (you are % m away)', round(d);
  end if;

  update public.attendance_legs set out_at = clock_timestamp(), out_lat = p_lat, out_lng = p_lng where id = lg.id;
  update public.attendance set check_out_at = clock_timestamp(), check_out_lat = p_lat, check_out_lng = p_lng
   where id = lg.attendance_id;
  perform public._audit('TRAVEL_CHECK_OUT', 'stop ' || lg.leg || ' ' || to_char(v_now, 'HH24:MI'));
  return public._travel_today(me.id);
end $$;

-- Site travel (selfie + named sites): any number of stops, next stop must be a different site
create or replace function public.site_travel_check_in(
  p_lat double precision default null, p_lng double precision default null,
  p_site_id bigint default null, p_site_name text default null,
  p_note text default null, p_photo_path text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me        public.profiles := public._require_active();
  v_now     timestamp := public.ist_now();
  a         public.attendance;
  prev      public.attendance_legs;
  g         record;
  v_outside boolean;
  n         int;
  lid       bigint;
begin
  if not (me.travel_access and me.site_employee) then
    raise exception 'Site travel attendance is not enabled for your account';
  end if;
  if p_lat is null or p_lng is null then
    raise exception 'Location is required. Turn on location and try again';
  end if;
  perform set_config('app.travel_rpc', 'on', true);

  select * into g from public._geofence_check(p_site_id, p_lat, p_lng);
  v_outside := not g.inside;
  p_site_name := coalesce(g.site_name, p_site_name);
  if nullif(trim(p_site_name),'') is null then raise exception 'Select the work site before submitting'; end if;
  if v_outside then p_photo_path := null;
  elsif p_photo_path is null or split_part(p_photo_path, '/', 1) <> me.id::text then
    raise exception 'Take a selfie first';
  end if;

  insert into public.attendance (user_id, work_date, check_in_at, is_late, source, site_name, note, check_in_lat, check_in_lng)
  values (me.id, v_now::date, now(), date_trunc('minute', v_now)::time > me.shift_start, 'site',
          trim(p_site_name), nullif(trim(p_note),''), p_lat, p_lng)
  on conflict (user_id, work_date) do nothing;
  select * into a from public.attendance where user_id = me.id and work_date = v_now::date for update;

  if a.travel_done then raise exception 'You have already finished your travel day'; end if;
  select count(*) into n from public.attendance_legs where attendance_id = a.id;
  if exists (select 1 from public.attendance_legs where attendance_id = a.id and out_at is null) then
    raise exception 'You are already checked in. Check out first';
  end if;
  if n >= 30 then raise exception 'Maximum 30 stops a day reached'; end if;
  if n = 0 and a.check_out_at is not null then raise exception 'You have already checked out today'; end if;
  if n >= 1 then
    select * into prev from public.attendance_legs where attendance_id = a.id and leg = n;
    if prev.site_id is not distinct from p_site_id then
      raise exception 'The next stop must be a different work site than the previous one (%)', prev.site_name;
    end if;
    update public.attendance set check_out_at = null, check_out_lat = null, check_out_lng = null where id = a.id;
  end if;

  insert into public.attendance_legs (attendance_id, user_id, work_date, leg, in_lat, in_lng, site_id, site_name)
  values (a.id, me.id, a.work_date, n + 1, p_lat, p_lng, p_site_id, trim(p_site_name)) returning id into lid;
  if n >= 1 then perform public._record_trip(lid); end if;
  insert into public.selfie_records (user_id, attendance_id, kind, site_name, note, photo_path, lat, lng, outside, distance_m)
  values (me.id, a.id, 'IN', trim(p_site_name), nullif(trim(p_note),''), p_photo_path, p_lat, p_lng, v_outside, g.distance_m);
  perform public._audit('SITE_TRAVEL_CHECK_IN', 'stop ' || (n + 1) || ' ' || trim(p_site_name));
  return public._travel_today(me.id);
end $$;

create or replace function public.site_travel_check_out(
  p_lat double precision default null, p_lng double precision default null,
  p_note text default null, p_photo_path text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me        public.profiles := public._require_active();
  v_now     timestamp := public.ist_now();
  lg        public.attendance_legs;
  g         record;
  v_outside boolean;
  d         double precision;
begin
  if not (me.travel_access and me.site_employee) then
    raise exception 'Site travel attendance is not enabled for your account';
  end if;
  if p_lat is null or p_lng is null then
    raise exception 'Location is required. Turn on location and try again';
  end if;
  perform set_config('app.travel_rpc', 'on', true);

  select * into lg from public.attendance_legs
   where user_id = me.id and work_date = v_now::date and out_at is null
   order by leg desc limit 1 for update;
  if lg.id is null then raise exception 'No check-in to close. Check in first'; end if;

  d := public._distance_m(lg.in_lat, lg.in_lng, p_lat, p_lng);
  if d > 1000 then
    raise exception 'Check out from the same place where you checked in (you are % m away)', round(d);
  end if;

  select * into g from public._geofence_check(lg.site_id, p_lat, p_lng);
  v_outside := not g.inside;
  if v_outside then p_photo_path := null;
  else
    if p_photo_path is null or split_part(p_photo_path, '/', 1) <> me.id::text then raise exception 'Take a selfie first'; end if;
    if exists (select 1 from public.selfie_records where attendance_id = lg.attendance_id and photo_path = p_photo_path) then
      raise exception 'Check-out needs a new selfie, different from the check-in selfie';
    end if;
  end if;

  update public.attendance_legs set out_at = clock_timestamp(), out_lat = p_lat, out_lng = p_lng where id = lg.id;
  update public.attendance set check_out_at = clock_timestamp(), check_out_lat = p_lat, check_out_lng = p_lng,
         note = coalesce(nullif(trim(p_note),''), note)
   where id = lg.attendance_id;
  insert into public.selfie_records (user_id, attendance_id, kind, site_name, note, photo_path, lat, lng, outside, distance_m)
  values (me.id, lg.attendance_id, 'OUT', coalesce(lg.site_name, '-'), nullif(trim(p_note),''), p_photo_path, p_lat, p_lng, v_outside, g.distance_m);
  perform public._audit('SITE_TRAVEL_CHECK_OUT', 'stop ' || lg.leg || ' ' || coalesce(lg.site_name, ''));
  return public._travel_today(me.id);
end $$;

-- "Finish travel day": stops the live GPS and closes the day's totals
create or replace function public.travel_finish_day() returns jsonb
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._require_active(); a public.attendance;
begin
  if not me.travel_access then raise exception 'Travel attendance is not enabled for your account'; end if;
  select * into a from public.attendance where user_id = me.id and work_date = public.ist_today() for update;
  if a.id is null or not exists (select 1 from public.attendance_legs where attendance_id = a.id) then
    raise exception 'You have not checked in at any stop today';
  end if;
  if exists (select 1 from public.attendance_legs where attendance_id = a.id and out_at is null) then
    raise exception 'Check out of your current stop first';
  end if;
  update public.attendance set travel_done = true where id = a.id;
  delete from public.live_locations where user_id = me.id;
  perform public._audit('TRAVEL_FINISH_DAY', coalesce(a.travel_km, 0)::text || ' km');
  return public._travel_today(me.id);
end $$;

-- Report: one row per travelling day with stops, trips, km, the route and the stop details
drop function if exists public.admin_travel_report(date, date);
create or replace function public.admin_travel_report(p_from date, p_to date)
returns table (
  user_id uuid, username text, full_name text, department text, work_date date,
  stops int, trips int, km numeric, route text, legs jsonb
)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  perform public._require_admin();
  return query
  select p.id, p.username, p.full_name, p.department, a.work_date,
         (select count(*) from public.attendance_legs l where l.attendance_id = a.id)::int,
         greatest((select count(*) from public.attendance_legs l where l.attendance_id = a.id) - 1, 0)::int,
         coalesce(a.travel_km, 0),
         (select string_agg(coalesce(l.site_name, 'Stop ' || l.leg), ' > ' order by l.leg)
            from public.attendance_legs l where l.attendance_id = a.id),
         (select jsonb_agg(jsonb_build_object(
                   'leg', l.leg, 'site', l.site_name,
                   'in',  to_char(l.in_at  at time zone 'Asia/Kolkata', 'HH24:MI'),
                   'out', to_char(l.out_at at time zone 'Asia/Kolkata', 'HH24:MI'),
                   'trip_km', l.trip_km, 'source', l.trip_source) order by l.leg)
            from public.attendance_legs l where l.attendance_id = a.id)
  from public.attendance a
  join public.profiles p on p.id = a.user_id
  where a.work_date between p_from and p_to
    and exists (select 1 from public.attendance_legs l where l.attendance_id = a.id)
  order by a.work_date desc, p.full_name;
end $$;

-- Trails older than 60 days are not needed any more (call from time to time, or schedule it)
create or replace function public.purge_old_travel_track() returns integer
language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  perform public._require_full_admin();
  delete from public.travel_track where recorded_at < now() - interval '60 days';
  get diagnostics n = row_count;
  return n;
end $$;

revoke execute on function public._route_km(uuid, timestamptz, timestamptz, double precision, double precision, double precision, double precision) from public, anon, authenticated;
revoke execute on function public._record_trip(bigint) from public, anon, authenticated;
revoke execute on function public._travel_today(uuid) from public, anon, authenticated;
revoke execute on function public._tracking_kind(uuid) from public, anon, authenticated;
revoke execute on function public.travel_check_in(double precision, double precision) from public, anon;
revoke execute on function public.travel_check_out(double precision, double precision) from public, anon;
revoke execute on function public.site_travel_check_in(double precision, double precision, bigint, text, text, text) from public, anon;
revoke execute on function public.site_travel_check_out(double precision, double precision, text, text) from public, anon;
revoke execute on function public.travel_finish_day() from public, anon;
revoke execute on function public.admin_travel_report(date, date) from public, anon;
revoke execute on function public.purge_old_travel_track() from public, anon;
revoke execute on function public.report_location(double precision, double precision, integer) from public, anon;
grant  execute on function public.travel_check_in(double precision, double precision) to authenticated;
grant  execute on function public.travel_check_out(double precision, double precision) to authenticated;
grant  execute on function public.site_travel_check_in(double precision, double precision, bigint, text, text, text) to authenticated;
grant  execute on function public.site_travel_check_out(double precision, double precision, text, text) to authenticated;
grant  execute on function public.travel_finish_day() to authenticated;
grant  execute on function public.admin_travel_report(date, date) to authenticated;
grant  execute on function public.purge_old_travel_track() to authenticated;
grant  execute on function public.report_location(double precision, double precision, integer) to authenticated;

-- ---------------------------------------------------------------------
-- 30. FIELD VISIT: GO FROM SITE 1 TO SITE 2 AND CALCULATE THE TRAVEL
--     * When starting a visit the employee can choose the site he starts from and the site he goes to.
--       The planned distance (straight line between the two sites) is saved with the visit.
--     * While the visit is open the live GPS trail is kept (every ~45 s). When the visit ends, the distance really
--       travelled is calculated from that trail (never shorter than the straight line from start to end;
--       if no GPS arrived the straight line is used and marked 'straight').
--     * Admin / HR see "Site 1 > Site 2", the planned km and the travelled km in Field Visits.
-- ---------------------------------------------------------------------
alter table public.visits add column if not exists from_site_id   bigint references public.sites(id) on delete set null;
alter table public.visits add column if not exists from_site_name text;
alter table public.visits add column if not exists to_site_id     bigint references public.sites(id) on delete set null;
alter table public.visits add column if not exists to_site_name   text;
alter table public.visits add column if not exists planned_km     numeric(8,1);
alter table public.visits add column if not exists travel_km      numeric(8,1);
alter table public.visits add column if not exists travel_source  text;       -- 'gps' | 'straight'

-- the old 4-argument version is replaced by one that also takes the two sites
drop function if exists public.start_visit(text, text, double precision, double precision);
create or replace function public.start_visit(
  p_place text, p_purpose text,
  p_lat double precision default null, p_lng double precision default null,
  p_from_site bigint default null, p_to_site bigint default null
) returns public.visits
language plpgsql security definer set search_path = public as $$
declare
  me  public.profiles := public._require_visit_access();
  d   date := public.ist_today();
  att public.attendance;
  v   public.visits;
  fs  public.sites;
  ts  public.sites;
  km  numeric;
begin
  if p_from_site is not null or p_to_site is not null then
    if p_from_site is null or p_to_site is null then
      raise exception 'Choose both the site you start from and the site you are going to';
    end if;
    if p_from_site = p_to_site then raise exception 'The two sites must be different'; end if;
    select * into fs from public.sites where id = p_from_site and active;
    select * into ts from public.sites where id = p_to_site   and active;
    if fs.id is null or ts.id is null then raise exception 'Choose two active work sites'; end if;
    km := round((public._distance_m(fs.lat, fs.lng, ts.lat, ts.lng) / 1000)::numeric, 1);
    if nullif(trim(p_place),'') is null then p_place := ts.name; end if;     -- the place defaults to the destination
  end if;

  if nullif(trim(p_place),'') is null   then raise exception 'Enter the place / client you are visiting'; end if;
  if nullif(trim(p_purpose),'') is null then raise exception 'Enter the purpose of the visit'; end if;
  if p_lat is null or p_lng is null     then raise exception 'Location is required to start a visit'; end if;

  select * into att from public.attendance where user_id = me.id and work_date = d;
  if att.id is null or att.check_in_at is null then
    raise exception 'Check in at the office first, then start your visit';
  end if;
  if att.check_out_at is not null then
    raise exception 'You have already checked out today';
  end if;
  if exists (select 1 from public.visits where user_id = me.id and end_at is null) then
    raise exception 'You already have a visit in progress. End it first';
  end if;

  insert into public.visits (user_id, visit_date, place, purpose, start_lat, start_lng,
                             from_site_id, from_site_name, to_site_id, to_site_name, planned_km)
  values (me.id, d, trim(p_place), trim(p_purpose), p_lat, p_lng,
          fs.id, fs.name, ts.id, ts.name, km)
  returning * into v;
  perform public._audit('VISIT_START', me.username || ' at ' || v.place
    || case when fs.id is not null then ' (' || fs.name || ' > ' || ts.name || ', ' || km || ' km planned)' else '' end);
  return v;
end $$;

-- The GPS trail is kept during a visit too (it is what the travelled distance is calculated from)
create or replace function public.report_location(
  p_lat double precision, p_lng double precision, p_accuracy integer default null
) returns text
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._require_active(); k text;
begin
  k := public._tracking_kind(me.id);
  if k is null then
    delete from public.live_locations where user_id = me.id;
    return null;
  end if;
  if p_lat is null or p_lng is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 then
    raise exception 'Invalid location';
  end if;
  insert into public.live_locations (user_id, lat, lng, accuracy_m, kind, updated_at)
  values (me.id, p_lat, p_lng, p_accuracy, k, now())
  on conflict (user_id) do update
     set lat = excluded.lat, lng = excluded.lng, accuracy_m = excluded.accuracy_m, kind = excluded.kind, updated_at = now();
  insert into public.travel_track (user_id, recorded_at, lat, lng, accuracy_m) values (me.id, clock_timestamp(), p_lat, p_lng, p_accuracy);
  return k;
end $$;

-- Ending a visit also calculates the distance travelled during it
create or replace function public.end_visit(
  p_outcome text default null,
  p_lat double precision default null, p_lng double precision default null
) returns public.visits
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._require_visit_access(); v public.visits; r record;
begin
  if p_lat is null or p_lng is null then raise exception 'Location is required to end a visit'; end if;
  update public.visits set
      end_at = now(), end_lat = p_lat, end_lng = p_lng,
      outcome = nullif(trim(p_outcome),''), status = 'Pending'
    where user_id = me.id and end_at is null
    returning * into v;
  if v.id is null then raise exception 'You have no visit in progress'; end if;
  if v.start_lat is not null and v.start_lng is not null then
    select * into r from public._route_km(me.id, v.start_at, clock_timestamp(), v.start_lat, v.start_lng, v.end_lat, v.end_lng);
    update public.visits set travel_km = r.km, travel_source = r.source where id = v.id returning * into v;
  end if;
  perform public._audit('VISIT_END', me.username || ' at ' || v.place || coalesce(' (' || v.travel_km || ' km travelled)', ''));
  return v;
end $$;

revoke execute on function public.start_visit(text, text, double precision, double precision, bigint, bigint) from public, anon;
revoke execute on function public.end_visit(text, double precision, double precision) from public, anon;
revoke execute on function public.report_location(double precision, double precision, integer) from public, anon;
grant  execute on function public.start_visit(text, text, double precision, double precision, bigint, bigint) to authenticated;
grant  execute on function public.end_visit(text, double precision, double precision) to authenticated;
grant  execute on function public.report_location(double precision, double precision, integer) to authenticated;

-- Make the API see new objects straight away


-- ---------------------------------------------------------------------
-- 31. OFFICE EMPLOYEES: CHECK IN / OUT ONLY AT THE OFFICE LOCATION (no selfie)
--     * The Admin marks one or more work sites as "Office" (Work Sites -> Office location).
--     * An office employee (not a site employee) checks in and out WITHOUT a selfie, but only while his phone / PC
--       is inside the office's allowed radius. Location is required for both check-in and check-out.
--     * Offices an employee may use: the offices assigned to him in "Work site access", or every office if none is assigned.
--     * If no office has been marked yet, nothing is enforced (as before).
-- ---------------------------------------------------------------------
alter table public.sites add column if not exists is_office boolean not null default false;

-- p_is_office null = keep the current setting
drop function if exists public.admin_save_site(bigint, text, double precision, double precision, integer, boolean);
create or replace function public.admin_save_site(
  p_id        bigint,
  p_name      text,
  p_lat       double precision,
  p_lng       double precision,
  p_radius    integer default 200,
  p_active    boolean default true,
  p_is_office boolean default null
) returns public.sites
language plpgsql security definer set search_path = public as $$
declare
  me public.profiles := public._require_full_admin();   -- work sites: Admin only
  r  public.sites;
begin
  if nullif(trim(p_name),'') is null then raise exception 'Enter the site name'; end if;
  if p_lat is null or p_lng is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 then
    raise exception 'Enter a valid latitude and longitude';
  end if;
  if p_radius is null or p_radius < 20 or p_radius > 100000 then
    raise exception 'Radius must be between 20 metres and 100 km';
  end if;

  if p_id is null then
    insert into public.sites (name, lat, lng, radius_m, active, is_office, created_by)
    values (trim(p_name), p_lat, p_lng, p_radius, coalesce(p_active, true), coalesce(p_is_office, false), me.id)
    returning * into r;
  else
    update public.sites
       set name = trim(p_name), lat = p_lat, lng = p_lng,
           radius_m = p_radius, active = coalesce(p_active, active), is_office = coalesce(p_is_office, is_office)
     where id = p_id
    returning * into r;
    if r.id is null then raise exception 'Site not found'; end if;
  end if;

  perform public._audit('SAVE_SITE', r.name || ' radius=' || r.radius_m || 'm active=' || r.active || ' office=' || r.is_office);
  return r;
end $$;

-- Is this person inside one of his offices? Raises an error if not. Returns (office name, metres) or nulls when no office is defined.
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
  has_assign := exists (select 1 from public.employee_sites e join public.sites s on s.id = e.site_id
                         where e.user_id = p_user and s.is_office);
  select s.name, public._distance_m(p_lat, p_lng, s.lat, s.lng), s.radius_m
    into best_name, best_d, best_r
    from public.sites s
   where s.active and s.is_office
     and (not has_assign or exists (select 1 from public.employee_sites e where e.user_id = p_user and e.site_id = s.id))
   order by public._distance_m(p_lat, p_lng, s.lat, s.lng)
   limit 1;
  if best_name is null then raise exception 'No office location is assigned to you. Ask HR / Admin'; end if;
  if best_d > best_r then
    raise exception 'You must be at the office to check in or out. You are % m away from %', round(best_d), best_name;
  end if;
  return query select best_name, round(best_d)::integer;
end $$;

create or replace function public.check_in(
  p_lat        double precision default null,
  p_lng        double precision default null,
  p_site_name  text default null,
  p_note       text default null,
  p_photo_path text default null,
  p_site_id    bigint default null
) returns public.attendance
language plpgsql security definer set search_path = public as $$
declare
  me        public.profiles := public._require_active();
  v_site    boolean := me.site_employee;      -- site employees always use the site flow
  v_now     timestamp := public.ist_now();
  v_outside boolean := false;
  v_office  text;
  g         record;
  r         public.attendance;
begin
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
    select o.site_name into v_office from public._office_check(me.id, p_lat, p_lng) o;
  end if;

  insert into public.attendance (user_id, work_date, check_in_at, is_late, source,
                                 site_name, note, check_in_lat, check_in_lng)
  values (me.id, v_now::date, now(),
          date_trunc('minute', v_now)::time > me.shift_start,
          case when v_site then 'site' else 'office' end,
          nullif(trim(coalesce(p_site_name, v_office)),''), nullif(trim(p_note),''), p_lat, p_lng)
  on conflict (user_id, work_date) do nothing
  returning * into r;

  if r.id is null then
    raise exception 'You have already checked in today';
  end if;

  if v_site then
    insert into public.selfie_records (user_id, attendance_id, kind, site_name, note, photo_path, lat, lng, outside, distance_m)
    values (me.id, r.id, 'IN', trim(p_site_name), nullif(trim(p_note),''), p_photo_path, p_lat, p_lng, v_outside, g.distance_m);
    perform public._audit(case when v_outside then 'SITE_CHECK_IN_OUTSIDE' else 'SITE_SELFIE_CHECK_IN' end,
      trim(p_site_name) || case when v_outside then ' (' || coalesce(g.distance_m::text, '?') || ' m away)' else '' end);
  else
    perform public._audit('CHECK_IN', to_char(v_now, 'HH24:MI') || coalesce(' at ' || v_office, ''));
  end if;
  return r;
end $$;

create or replace function public.check_out(
  p_lat        double precision default null,
  p_lng        double precision default null,
  p_site_name  text default null,
  p_note       text default null,
  p_photo_path text default null,
  p_site_id    bigint default null
) returns public.attendance
language plpgsql security definer set search_path = public as $$
declare
  me        public.profiles := public._require_active();
  v_site    boolean := me.site_employee;
  v_now     timestamp := public.ist_now();
  v_outside boolean := false;
  v_office  text;
  g         record;
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
    else
      if p_photo_path is null or split_part(p_photo_path, '/', 1) <> me.id::text then
        raise exception 'Take a selfie first';
      end if;
      if exists (select 1 from public.selfie_records
                  where attendance_id = r.id and photo_path = p_photo_path) then
        raise exception 'Check-out needs a new selfie, different from the check-in selfie';
      end if;
    end if;
  else
    select o.site_name into v_office from public._office_check(me.id, p_lat, p_lng) o;
  end if;

  update public.attendance
     set check_out_at  = now(),
         check_out_lat = p_lat,
         check_out_lng = p_lng,
         note          = coalesce(nullif(trim(p_note),''), note)
   where id = r.id
  returning * into r;

  if v_site then
    insert into public.selfie_records (user_id, attendance_id, kind, site_name, note, photo_path, lat, lng, outside, distance_m)
    values (me.id, r.id, 'OUT', trim(p_site_name), nullif(trim(p_note),''), p_photo_path, p_lat, p_lng, v_outside, g.distance_m);
    perform public._audit(case when v_outside then 'SITE_CHECK_OUT_OUTSIDE' else 'SITE_SELFIE_CHECK_OUT' end,
      trim(p_site_name) || case when v_outside then ' (' || coalesce(g.distance_m::text, '?') || ' m away)' else '' end);
  else
    perform public._audit('CHECK_OUT', to_char(v_now, 'HH24:MI') || coalesce(' at ' || v_office, ''));
  end if;
  return r;
end $$;

revoke execute on function public._office_check(uuid, double precision, double precision) from public, anon, authenticated;
revoke execute on function public.admin_save_site(bigint, text, double precision, double precision, integer, boolean, boolean) from public, anon;
revoke execute on function public.check_in(double precision, double precision, text, text, text, bigint) from public, anon;
revoke execute on function public.check_out(double precision, double precision, text, text, text, bigint) from public, anon;
grant  execute on function public.admin_save_site(bigint, text, double precision, double precision, integer, boolean, boolean) to authenticated;
grant  execute on function public.check_in(double precision, double precision, text, text, text, bigint) to authenticated;
grant  execute on function public.check_out(double precision, double precision, text, text, text, bigint) to authenticated;

-- ---------------------------------------------------------------------
-- 32. DESIGNATION: the job title of an employee (e.g. Site Engineer, Accountant), filled in by Admin / HR
-- ---------------------------------------------------------------------
alter table public.profiles add column if not exists designation text;

drop function if exists public.admin_update_profile(uuid, text, text, text, boolean, time, time, text);
create or replace function public.admin_update_profile(
  p_user          uuid,
  p_full_name     text default null,
  p_role          text default null,
  p_department    text default null,
  p_site_employee boolean default null,
  p_shift_start   time default null,
  p_shift_end     time default null,
  p_phone         text default null,
  p_designation   text default null
) returns public.profiles
language plpgsql security definer set search_path = public as $$
declare
  me     public.profiles := public._require_admin();
  target public.profiles;
begin
  select * into target from public.profiles where id = p_user for update;
  if target.id is null then raise exception 'User not found'; end if;

  if p_role is not null and p_role not in ('Employee','HR','Admin') then
    raise exception 'Invalid role';
  end if;
  if me.role <> 'Admin' then
    if target.id <> me.id and target.role <> 'Employee' then
      raise exception 'Only an Admin can change HR / Admin accounts';
    end if;
    if p_role is not null and p_role <> target.role then
      raise exception 'Only an Admin can change roles';
    end if;
  end if;
  if p_user = me.id and p_role is not null and p_role <> me.role then
    raise exception 'You cannot change your own role';
  end if;

  update public.profiles set
    full_name     = coalesce(nullif(trim(p_full_name),''), full_name),
    role          = coalesce(p_role, role),
    department    = case when p_department is null then department else nullif(trim(p_department),'') end,
    designation   = case when p_designation is null then designation else nullif(trim(p_designation),'') end,
    site_employee = coalesce(p_site_employee, site_employee),
    shift_start   = coalesce(p_shift_start, shift_start),
    shift_end     = coalesce(p_shift_end, shift_end),
    phone         = case when p_phone is null then phone else nullif(trim(p_phone),'') end
  where id = p_user
  returning * into target;

  perform public._audit('UPDATE_ACCESS',
    target.username || ' role=' || target.role || ' site=' || target.site_employee
    || ' shift=' || to_char(target.shift_start,'HH24:MI') || '-' || to_char(target.shift_end,'HH24:MI'));
  return target;
end $$;

revoke execute on function public.admin_update_profile(uuid, text, text, text, boolean, time, time, text, text) from public, anon;
grant  execute on function public.admin_update_profile(uuid, text, text, text, boolean, time, time, text, text) to authenticated;

-- ---------------------------------------------------------------------
-- 33. OFFICE + SITES IN ONE DAY, WITH THE DISTANCE FROM THE LOCATION
--     * At the OFFICE location an employee needs no selfie; at any other work site a selfie is required.
--     * An employee with Travel Access can check in / out at the office and at 2-3-4 sites in one day.
--     * Every check-in / check-out stores how many metres the person was from the location point; the app shows it to
--       the employee and to Admin / HR. Away from the office, the error says how many metres away the person is.
-- ---------------------------------------------------------------------
alter table public.attendance      add column if not exists check_in_dist_m  integer;
alter table public.attendance      add column if not exists check_out_dist_m integer;
alter table public.attendance_legs add column if not exists in_dist_m  integer;
alter table public.attendance_legs add column if not exists out_dist_m integer;

create or replace function public._is_office_site(p_site bigint) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select s.is_office from public.sites s where s.id = p_site), false)
$$;
revoke execute on function public._is_office_site(bigint) from public, anon, authenticated;

create or replace function public._travel_today(p_user uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'date',  public.ist_today(),
    'legs',  coalesce((select jsonb_agg(jsonb_build_object(
                'leg', l.leg, 'in_at', l.in_at, 'out_at', l.out_at, 'site_id', l.site_id, 'site_name', l.site_name,
                'in_lat', l.in_lat, 'in_lng', l.in_lng, 'out_lat', l.out_lat, 'out_lng', l.out_lng,
                'trip_km', l.trip_km, 'trip_source', l.trip_source,
                'in_dist_m', l.in_dist_m, 'out_dist_m', l.out_dist_m, 'is_office', public._is_office_site(l.site_id)) order by l.leg)
              from public.attendance_legs l where l.user_id = p_user and l.work_date = public.ist_today()), '[]'::jsonb),
    'km',    (select a.travel_km from public.attendance a where a.user_id = p_user and a.work_date = public.ist_today()),
    'open',  exists (select 1 from public.attendance_legs l where l.user_id = p_user and l.work_date = public.ist_today() and l.out_at is null),
    'done',  coalesce((select a.travel_done from public.attendance a where a.user_id = p_user and a.work_date = public.ist_today()), false),
    'max_legs', 30
  )
$$;
revoke execute on function public._travel_today(uuid) from public, anon, authenticated;
create or replace function public.check_in(
  p_lat        double precision default null,
  p_lng        double precision default null,
  p_site_name  text default null,
  p_note       text default null,
  p_photo_path text default null,
  p_site_id    bigint default null
) returns public.attendance
language plpgsql security definer set search_path = public as $$
declare
  me        public.profiles := public._require_active();
  v_site    boolean := me.site_employee and not public._is_office_site(p_site_id);   -- a site employee who picks the OFFICE needs no selfie
  v_now     timestamp := public.ist_now();
  v_outside boolean := false;
  v_office  text;
  v_od      integer;
  g         record;
  r         public.attendance;
begin
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

  insert into public.attendance (user_id, work_date, check_in_at, is_late, source,
                                 site_name, note, check_in_lat, check_in_lng, check_in_dist_m)
  values (me.id, v_now::date, now(),
          date_trunc('minute', v_now)::time > me.shift_start,
          case when v_site then 'site' else 'office' end,
          nullif(trim(coalesce(p_site_name, v_office)),''), nullif(trim(p_note),''), p_lat, p_lng, v_od)
  on conflict (user_id, work_date) do nothing
  returning * into r;

  if r.id is null then
    raise exception 'You have already checked in today';
  end if;

  if v_site then
    insert into public.selfie_records (user_id, attendance_id, kind, site_name, note, photo_path, lat, lng, outside, distance_m)
    values (me.id, r.id, 'IN', trim(p_site_name), nullif(trim(p_note),''), p_photo_path, p_lat, p_lng, v_outside, g.distance_m);
    perform public._audit(case when v_outside then 'SITE_CHECK_IN_OUTSIDE' else 'SITE_SELFIE_CHECK_IN' end,
      trim(p_site_name) || case when v_outside then ' (' || coalesce(g.distance_m::text, '?') || ' m away)' else '' end);
  else
    perform public._audit('CHECK_IN', to_char(v_now, 'HH24:MI') || coalesce(' at ' || v_office || ' (' || v_od || ' m from the office point)', ''));
  end if;
  return r;
end $$;

create or replace function public.check_out(
  p_lat        double precision default null,
  p_lng        double precision default null,
  p_site_name  text default null,
  p_note       text default null,
  p_photo_path text default null,
  p_site_id    bigint default null
) returns public.attendance
language plpgsql security definer set search_path = public as $$
declare
  me        public.profiles := public._require_active();
  v_site    boolean := me.site_employee and not public._is_office_site(p_site_id);
  v_now     timestamp := public.ist_now();
  v_outside boolean := false;
  v_office  text;
  v_od      integer;
  g         record;
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
    else
      if p_photo_path is null or split_part(p_photo_path, '/', 1) <> me.id::text then
        raise exception 'Take a selfie first';
      end if;
      if exists (select 1 from public.selfie_records
                  where attendance_id = r.id and photo_path = p_photo_path) then
        raise exception 'Check-out needs a new selfie, different from the check-in selfie';
      end if;
    end if;
  else
    select o.site_name, o.distance_m into v_office, v_od from public._office_check(me.id, p_lat, p_lng) o;
  end if;

  update public.attendance
     set check_out_at  = now(),
         check_out_lat = p_lat,
         check_out_lng = p_lng,
         check_out_dist_m = v_od,
         note          = coalesce(nullif(trim(p_note),''), note)
   where id = r.id
  returning * into r;

  if v_site then
    insert into public.selfie_records (user_id, attendance_id, kind, site_name, note, photo_path, lat, lng, outside, distance_m)
    values (me.id, r.id, 'OUT', trim(p_site_name), nullif(trim(p_note),''), p_photo_path, p_lat, p_lng, v_outside, g.distance_m);
    perform public._audit(case when v_outside then 'SITE_CHECK_OUT_OUTSIDE' else 'SITE_SELFIE_CHECK_OUT' end,
      trim(p_site_name) || case when v_outside then ' (' || coalesce(g.distance_m::text, '?') || ' m away)' else '' end);
  else
    perform public._audit('CHECK_OUT', to_char(v_now, 'HH24:MI') || coalesce(' at ' || v_office || ' (' || v_od || ' m from the office point)', ''));
  end if;
  return r;
end $$;

-- Site travel (selfie + named sites): any number of stops, next stop must be a different site
create or replace function public.site_travel_check_in(
  p_lat double precision default null, p_lng double precision default null,
  p_site_id bigint default null, p_site_name text default null,
  p_note text default null, p_photo_path text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me        public.profiles := public._require_active();
  v_now     timestamp := public.ist_now();
  a         public.attendance;
  prev      public.attendance_legs;
  g         record;
  v_outside boolean;
  n         int;
  lid       bigint;
  v_off     boolean := public._is_office_site(p_site_id);
  v_od      integer;
begin
  if not (me.travel_access and me.site_employee) then
    raise exception 'Site travel attendance is not enabled for your account';
  end if;
  if p_lat is null or p_lng is null then
    raise exception 'Location is required. Turn on location and try again';
  end if;
  perform set_config('app.travel_rpc', 'on', true);

  if v_off then
    -- the office: no selfie, but only inside the office area (the error says how far away the person is)
    select o.site_name, o.distance_m into p_site_name, v_od from public._office_check(me.id, p_lat, p_lng) o;
    p_photo_path := null; v_outside := false;
  else
    select * into g from public._geofence_check(p_site_id, p_lat, p_lng);
    v_outside := not g.inside; v_od := g.distance_m;
    p_site_name := coalesce(g.site_name, p_site_name);
    if nullif(trim(p_site_name),'') is null then raise exception 'Select the work site before submitting'; end if;
    if v_outside then p_photo_path := null;
    elsif p_photo_path is null or split_part(p_photo_path, '/', 1) <> me.id::text then
      raise exception 'Take a selfie first';
    end if;
  end if;

  insert into public.attendance (user_id, work_date, check_in_at, is_late, source, site_name, note, check_in_lat, check_in_lng)
  values (me.id, v_now::date, now(), date_trunc('minute', v_now)::time > me.shift_start, 'site',
          trim(p_site_name), nullif(trim(p_note),''), p_lat, p_lng)
  on conflict (user_id, work_date) do nothing;
  select * into a from public.attendance where user_id = me.id and work_date = v_now::date for update;

  if a.travel_done then raise exception 'You have already finished your travel day'; end if;
  select count(*) into n from public.attendance_legs where attendance_id = a.id;
  if exists (select 1 from public.attendance_legs where attendance_id = a.id and out_at is null) then
    raise exception 'You are already checked in. Check out first';
  end if;
  if n >= 30 then raise exception 'Maximum 30 stops a day reached'; end if;
  if n = 0 and a.check_out_at is not null then raise exception 'You have already checked out today'; end if;
  if n >= 1 then
    select * into prev from public.attendance_legs where attendance_id = a.id and leg = n;
    if prev.site_id is not distinct from p_site_id then
      raise exception 'The next stop must be a different work site than the previous one (%)', prev.site_name;
    end if;
    update public.attendance set check_out_at = null, check_out_lat = null, check_out_lng = null where id = a.id;
  end if;

  insert into public.attendance_legs (attendance_id, user_id, work_date, leg, in_lat, in_lng, site_id, site_name, in_dist_m)
  values (a.id, me.id, a.work_date, n + 1, p_lat, p_lng, p_site_id, trim(p_site_name), v_od) returning id into lid;
  if n >= 1 then perform public._record_trip(lid); end if;
  if not v_off then
    insert into public.selfie_records (user_id, attendance_id, kind, site_name, note, photo_path, lat, lng, outside, distance_m)
    values (me.id, a.id, 'IN', trim(p_site_name), nullif(trim(p_note),''), p_photo_path, p_lat, p_lng, v_outside, g.distance_m);
  end if;
  perform public._audit('SITE_TRAVEL_CHECK_IN', 'stop ' || (n + 1) || ' ' || trim(p_site_name));
  return public._travel_today(me.id);
end $$;

create or replace function public.site_travel_check_out(
  p_lat double precision default null, p_lng double precision default null,
  p_note text default null, p_photo_path text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me        public.profiles := public._require_active();
  v_now     timestamp := public.ist_now();
  lg        public.attendance_legs;
  g         record;
  v_outside boolean;
  d         double precision;
  v_off     boolean;
  v_od      integer;
begin
  if not (me.travel_access and me.site_employee) then
    raise exception 'Site travel attendance is not enabled for your account';
  end if;
  if p_lat is null or p_lng is null then
    raise exception 'Location is required. Turn on location and try again';
  end if;
  perform set_config('app.travel_rpc', 'on', true);

  select * into lg from public.attendance_legs
   where user_id = me.id and work_date = v_now::date and out_at is null
   order by leg desc limit 1 for update;
  if lg.id is null then raise exception 'No check-in to close. Check in first'; end if;

  d := public._distance_m(lg.in_lat, lg.in_lng, p_lat, p_lng);
  if d > 1000 then
    raise exception 'Check out from the same place where you checked in (you are % m away)', round(d);
  end if;

  v_off := public._is_office_site(lg.site_id);
  if v_off then
    select o.distance_m into v_od from public._office_check(me.id, p_lat, p_lng) o;   -- raises (with the distance) when not at the office
    p_photo_path := null; v_outside := false;
  else
    select * into g from public._geofence_check(lg.site_id, p_lat, p_lng);
    v_outside := not g.inside; v_od := g.distance_m;
    if v_outside then p_photo_path := null;
    else
      if p_photo_path is null or split_part(p_photo_path, '/', 1) <> me.id::text then raise exception 'Take a selfie first'; end if;
      if exists (select 1 from public.selfie_records where attendance_id = lg.attendance_id and photo_path = p_photo_path) then
        raise exception 'Check-out needs a new selfie, different from the check-in selfie';
      end if;
    end if;
  end if;

  update public.attendance_legs set out_at = clock_timestamp(), out_lat = p_lat, out_lng = p_lng, out_dist_m = v_od where id = lg.id;
  update public.attendance set check_out_at = clock_timestamp(), check_out_lat = p_lat, check_out_lng = p_lng,
         note = coalesce(nullif(trim(p_note),''), note)
   where id = lg.attendance_id;
  if not v_off then
    insert into public.selfie_records (user_id, attendance_id, kind, site_name, note, photo_path, lat, lng, outside, distance_m)
    values (me.id, lg.attendance_id, 'OUT', coalesce(lg.site_name, '-'), nullif(trim(p_note),''), p_photo_path, p_lat, p_lng, v_outside, g.distance_m);
  end if;
  perform public._audit('SITE_TRAVEL_CHECK_OUT', 'stop ' || lg.leg || ' ' || coalesce(lg.site_name, ''));
  return public._travel_today(me.id);
end $$;

revoke execute on function public.check_in(double precision, double precision, text, text, text, bigint) from public, anon;
revoke execute on function public.check_out(double precision, double precision, text, text, text, bigint) from public, anon;
revoke execute on function public.site_travel_check_in(double precision, double precision, bigint, text, text, text) from public, anon;
revoke execute on function public.site_travel_check_out(double precision, double precision, text, text) from public, anon;
grant  execute on function public.check_in(double precision, double precision, text, text, text, bigint) to authenticated;
grant  execute on function public.check_out(double precision, double precision, text, text, text, bigint) to authenticated;
grant  execute on function public.site_travel_check_in(double precision, double precision, bigint, text, text, text) to authenticated;
grant  execute on function public.site_travel_check_out(double precision, double precision, text, text) to authenticated;

-- ---------------------------------------------------------------------
-- 34. WORKING TIME 8:30 AM - 5:30 PM FOR EVERYONE
--     * Every existing account is set to 08:30 - 17:30 ONCE (a marker in the audit log stops it from running again,
--       so shifts you change later are not overwritten when this file is run again).
--     * New accounts get 08:30 - 17:30 by default.
-- ---------------------------------------------------------------------
alter table public.profiles alter column shift_start set default '08:30';
alter table public.profiles alter column shift_end   set default '17:30';
do $$
begin
  if not exists (select 1 from public.audit_log where action = 'SHIFT_830_530_SET') then
    update public.profiles set shift_start = '08:30', shift_end = '17:30';
    insert into public.audit_log (actor_id, action, detail) values (null, 'SHIFT_830_530_SET', 'All accounts set to 08:30 - 17:30');
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 35. EMPLOYEES CREATE THEIR OWN USERNAME AND PASSWORD (one-time setup code)
--     * Admin / HR create a one-time SETUP CODE for each employee (the code is shown once; only its hash is stored).
--     * The employee opens the app -> "First time? Create your login", enters the code and chooses a username and a password.
--     * The code works once. Until the employee has done this, the old username and password keep working;
--       after it, only the new ones work.
-- ---------------------------------------------------------------------
create table if not exists public.account_setup (
  user_id    uuid primary key references public.profiles(id) on delete cascade,
  code_hash  text not null unique,
  created_at timestamptz not null default now(),
  used_at    timestamptz
);
alter table public.account_setup enable row level security;
revoke all on public.account_setup from anon, authenticated;

-- Admin / HR: make (or renew) setup codes. Returns the codes ONCE. HR can only do this for employees.
create or replace function public.admin_make_setup_codes(p_users uuid[])
returns table (user_id uuid, username text, full_name text, code text)
language plpgsql security definer set search_path = public, extensions as $$
#variable_conflict use_column
declare
  me  public.profiles := public._require_admin();
  rec record; c text; i int;
  alpha constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  bytes bytea;
begin
  for rec in select p.* from public.profiles p
              where p.id = any(coalesce(p_users, '{}')) and p.active
                and (me.role = 'Admin' or p.role = 'Employee') loop
    bytes := gen_random_bytes(10); c := '';
    for i in 0..9 loop c := c || substr(alpha, (get_byte(bytes, i) % 32) + 1, 1); end loop;
    insert into public.account_setup (user_id, code_hash, created_at, used_at)
    values (rec.id, encode(digest(c, 'sha256'), 'hex'), now(), null)
    on conflict (user_id) do update set code_hash = excluded.code_hash, created_at = now(), used_at = null;
    user_id := rec.id; username := rec.username; full_name := rec.full_name; code := c;
    return next;
  end loop;
  perform public._audit('MAKE_SETUP_CODES', (select count(*) from public.profiles where id = any(coalesce(p_users, '{}')))::text || ' employees');
end $$;

-- Admin / HR: who has a pending code / who has finished
create or replace function public.admin_setup_status()
returns table (user_id uuid, code_made timestamptz, used_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  perform public._require_admin();
  return query select s.user_id, s.created_at, s.used_at from public.account_setup s;
end $$;

-- Public (before sign-in): the employee uses the code to choose a new username and password
create or replace function public.claim_account(p_code text, p_username text, p_password text)
returns text
language plpgsql security definer set search_path = public, extensions as $$
declare
  s    public.account_setup;
  v_u  text := lower(trim(coalesce(p_username, '')));
  v_old text;
begin
  select * into s from public.account_setup
   where code_hash = encode(digest(upper(regexp_replace(coalesce(p_code, ''), '\s', '', 'g')), 'sha256'), 'hex');
  if s.user_id is null or s.used_at is not null then
    raise exception 'This setup code is not valid or was already used. Ask HR / Admin for a new code';
  end if;
  if not exists (select 1 from public.profiles where id = s.user_id and active) then
    raise exception 'This account is not active. Contact HR';
  end if;
  if v_u !~ '^[a-z0-9._-]{2,40}$' then
    raise exception 'Username may contain letters, numbers, dot, dash and underscore (2-40 characters)';
  end if;
  if length(coalesce(p_password, '')) < 12 then
    raise exception 'Password must be at least 12 characters';
  end if;
  if exists (select 1 from public.profiles where username = v_u and id <> s.user_id) then
    raise exception 'This username is already taken. Choose another one';
  end if;

  select username into v_old from public.profiles where id = s.user_id;
  update public.profiles set username = v_u where id = s.user_id;
  update auth.users set encrypted_password = crypt(p_password, gen_salt('bf')), updated_at = now() where id = s.user_id;
  update public.account_setup set used_at = now() where user_id = s.user_id;
  insert into public.audit_log (actor_id, action, detail) values (s.user_id, 'CLAIM_ACCOUNT', v_old || ' -> ' || v_u);
  return v_u;
end $$;

revoke execute on function public.admin_make_setup_codes(uuid[]) from public, anon;
revoke execute on function public.admin_setup_status() from public, anon;
revoke execute on function public.claim_account(text, text, text) from public;
grant  execute on function public.admin_make_setup_codes(uuid[]) to authenticated;
grant  execute on function public.admin_setup_status() to authenticated;
grant  execute on function public.claim_account(text, text, text) to anon, authenticated;

-- ---------------------------------------------------------------------
-- 36. EMPLOYEES CREATE THEIR LOGIN WITH THEIR MOBILE NUMBER
--     * Admin / HR keep each employee's mobile number (Employee Detail -> Phone).
--     * "Reset login" (one employee, or all employees with reset_employee_logins.sql) removes the employee's username
--       and password: the account becomes "waiting for registration". Admin and HR logins are never touched.
--     * In the app the employee chooses "First time? Register with your mobile number", types the number and chooses his own
--       username and password. This works ONCE per reset, and only if exactly one waiting employee has that number.
-- ---------------------------------------------------------------------
alter table public.profiles add column if not exists login_claimed boolean not null default true;

-- last 10 digits of a phone number (91 / +91 / 0 prefixes and spaces are ignored)
create or replace function public._phone_key(p text) returns text
language sql immutable as $$
  select right(regexp_replace(coalesce(p, ''), '\D', '', 'g'), 10)
$$;

-- remove one employee's username and password (internal)
create or replace function public._reset_login(p_user uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  update public.profiles set login_claimed = false, username = 'pending-' || left(replace(id::text, '-', ''), 12)
   where id = p_user and role = 'Employee';
  update auth.users set encrypted_password = crypt(encode(gen_random_bytes(24), 'hex'), gen_salt('bf')), updated_at = now()
   where id = p_user and exists (select 1 from public.profiles where id = p_user and role = 'Employee');
end $$;

-- Admin / HR: reset the login of one employee (he registers again with his mobile number)
create or replace function public.admin_reset_login(p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._require_admin(); t public.profiles;
begin
  select * into t from public.profiles where id = p_user;
  if t.id is null or t.role <> 'Employee' then raise exception 'Only an employee login can be reset here'; end if;
  perform public._reset_login(p_user);
  perform public._audit('RESET_LOGIN', t.full_name);
end $$;

-- Public (before sign-in): the employee registers with his mobile number
create or replace function public.register_with_mobile(p_mobile text, p_username text, p_password text)
returns text
language plpgsql security definer set search_path = public, extensions as $$
declare
  k   text := public._phone_key(p_mobile);
  ids uuid[];
  v_u text := lower(trim(coalesce(p_username, '')));
begin
  if length(k) < 10 then raise exception 'Enter your 10-digit mobile number'; end if;
  if v_u !~ '^[a-z0-9._-]{2,40}$' then
    raise exception 'Username may contain letters, numbers, dot, dash and underscore (2-40 characters)';
  end if;
  if length(coalesce(p_password, '')) < 12 then raise exception 'Password must be at least 12 characters'; end if;

  select array_agg(id) into ids from public.profiles
   where role = 'Employee' and active and not login_claimed and public._phone_key(phone) = k;
  if coalesce(array_length(ids, 1), 0) <> 1 then
    -- the same message for "unknown number", "already registered" and "number used twice": nothing is revealed
    raise exception 'This mobile number cannot be registered. Check the number, or ask HR / Admin';
  end if;
  if exists (select 1 from public.profiles where username = v_u) then
    raise exception 'This username is already taken. Choose another one';
  end if;

  update public.profiles set username = v_u, login_claimed = true where id = ids[1];
  update auth.users set encrypted_password = crypt(p_password, gen_salt('bf')), updated_at = now() where id = ids[1];
  insert into public.audit_log (actor_id, action, detail) values (ids[1], 'REGISTER_MOBILE', v_u);
  return v_u;
end $$;

revoke execute on function public._phone_key(text) from public, anon, authenticated;
revoke execute on function public._reset_login(uuid) from public, anon, authenticated;
revoke execute on function public.admin_reset_login(uuid) from public, anon;
revoke execute on function public.register_with_mobile(text, text, text) from public;
grant  execute on function public.admin_reset_login(uuid) to authenticated;
grant  execute on function public.register_with_mobile(text, text, text) to anon, authenticated;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------
-- 35. LATE MARK RULES
--     * Office employees: 15 minutes grace. Check-in up to shift start + 15 min (08:45) is NOT late;
--       check-in after 08:45 is marked Late.
--     * Site employees are never marked Late.
--     * Applies to every check-in path (office, site, travel, regularization) through one trigger.
-- ---------------------------------------------------------------------
create or replace function public._set_is_late() returns trigger
language plpgsql security definer set search_path = public as $$
declare p public.profiles;
begin
  if new.check_in_at is null then new.is_late := false; return new; end if;
  select * into p from public.profiles where id = new.user_id;
  new.is_late := (not coalesce(p.site_employee, false))
                 and date_trunc('minute', new.check_in_at at time zone 'Asia/Kolkata')::time
                     > p.shift_start + interval '15 minutes';
  return new;
end $$;

drop trigger if exists attendance_set_late on public.attendance;
create trigger attendance_set_late before insert or update of check_in_at on public.attendance
  for each row execute function public._set_is_late();

revoke execute on function public._set_is_late() from public, anon, authenticated;

-- One-time recalculation of existing records (marker stops it re-running)
do $$
begin
  if not exists (select 1 from public.audit_log where action = 'LATE_RULE_845_SET') then
    update public.attendance a set is_late = (not p.site_employee)
        and date_trunc('minute', a.check_in_at at time zone 'Asia/Kolkata')::time > p.shift_start + interval '15 minutes'
      from public.profiles p
     where p.id = a.user_id and a.check_in_at is not null;
    insert into public.audit_log (actor_id, action, detail) values (null, 'LATE_RULE_845_SET', 'Late after shift start + 15 min; site employees never late');
  end if;
end $$;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------
-- 36. TOUR (employees working outside the city)
--     * An employee applies for a tour: city, from / to date, reason. Admin / HR approve or reject.
--     * Approved tour days count as PRESENT on working days (no Absent / salary cut), shown as "Tour - <city>".
--       A real check-in on a tour day still wins. Weekly offs and holidays stay as they are.
--     * A tour cannot overlap another pending / approved tour or an approved / pending leave.
-- ---------------------------------------------------------------------
create table if not exists public.tours (
  id           bigint generated always as identity primary key,
  user_id      uuid not null references public.profiles(id) on delete cascade,
  city         text not null check (length(trim(city)) > 0),
  from_day     date not null,
  to_day       date not null,
  reason       text not null,
  status       text not null default 'Pending' check (status in ('Pending','Approved','Rejected','Cancelled')),
  reviewed_by  uuid references public.profiles(id),
  reviewed_at  timestamptz,
  review_note  text,
  created_at   timestamptz not null default now(),
  check (to_day >= from_day)
);
create index if not exists tours_user_idx on public.tours (user_id, from_day);
create index if not exists tours_status_idx on public.tours (status);

alter table public.tours enable row level security;
drop policy if exists tours_read on public.tours;
create policy tours_read on public.tours for select to authenticated
  using (user_id = auth.uid() or public.is_staff_admin());
revoke all on public.tours from anon;
grant select on public.tours to authenticated;

create or replace function public.apply_tour(p_city text, p_from date, p_to date, p_reason text)
returns public.tours
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._require_active(); r public.tours;
begin
  if nullif(trim(p_city),'') is null then raise exception 'Enter the city'; end if;
  if p_to < p_from then raise exception 'End date cannot be before start date'; end if;
  if nullif(trim(p_reason),'') is null then raise exception 'Enter the purpose of the tour'; end if;
  if exists (select 1 from public.tours where user_id = me.id and status in ('Pending','Approved')
              and from_day <= p_to and to_day >= p_from) then
    raise exception 'These dates overlap with another tour request';
  end if;
  if exists (select 1 from public.leaves where user_id = me.id and status in ('Pending','Approved')
              and from_day <= p_to and to_day >= p_from) then
    raise exception 'These dates overlap with a leave request';
  end if;
  insert into public.tours (user_id, city, from_day, to_day, reason)
  values (me.id, trim(p_city), p_from, p_to, trim(p_reason)) returning * into r;
  perform public._audit('TOUR_REQUEST', r.city || ' ' || p_from || ' to ' || p_to);
  return r;
end $$;

create or replace function public.cancel_tour(p_id bigint) returns public.tours
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._require_active(); r public.tours;
begin
  update public.tours set status = 'Cancelled'
   where id = p_id and user_id = me.id and status = 'Pending' returning * into r;
  if r.id is null then raise exception 'Only your own pending requests can be cancelled'; end if;
  perform public._audit('CANCEL_TOUR', p_id::text);
  return r;
end $$;

create or replace function public.review_tour(p_id bigint, p_approve boolean, p_note text default null)
returns public.tours
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._require_admin(); r public.tours;
begin
  select * into r from public.tours where id = p_id for update;
  if r.id is null then raise exception 'Tour request not found'; end if;
  if r.status <> 'Pending' then raise exception 'This request is already %', lower(r.status); end if;
  update public.tours
     set status = case when p_approve then 'Approved' else 'Rejected' end,
         reviewed_by = me.id, reviewed_at = now(), review_note = nullif(trim(p_note),'')
   where id = p_id returning * into r;
  perform public._audit(case when p_approve then 'APPROVE_TOUR' else 'REJECT_TOUR' end, p_id::text);
  return r;
end $$;

revoke execute on function public.apply_tour(text, date, date, text) from public, anon;
revoke execute on function public.cancel_tour(bigint) from public, anon;
revoke execute on function public.review_tour(bigint, boolean, text) from public, anon;
grant  execute on function public.apply_tour(text, date, date, text) to authenticated;
grant  execute on function public.cancel_tour(bigint) to authenticated;
grant  execute on function public.review_tour(bigint, boolean, text) to authenticated;

do $$
begin
  if not exists (select 1 from pg_publication_tables
                  where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'tours') then
    alter publication supabase_realtime add table public.tours;
  end if;
end $$;

-- Monthly attendance: an approved tour day counts as Present (on a working day with no punch)
create or replace function public._month_attendance(p_user uuid, p_year int, p_month int)
returns table (
  day date, dow text, status text, in_time text, out_time text,
  hours numeric, is_late boolean, notes text, source text, site_name text
)
language sql stable security definer set search_path = public as $$
  with d as (
    select g::date as day
    from generate_series(make_date(p_year, p_month, 1)::timestamp,
                         (make_date(p_year, p_month, 1) + interval '1 month - 1 day'),
                         interval '1 day') g
  )
  select d.day,
         to_char(d.day, 'Dy'),
         case when d.day > public.ist_today()       then 'Upcoming'
              when h.day is not null                then 'Holiday'
              when lv.leave_type is not null        then 'Leave'
              when a.check_out_at is not null       then 'Present'
              when a.check_in_at  is not null       then 'Checked In'
              when tr.city is not null and public._is_workday(p_user, d.day) then 'Present'
              when public._is_weekly_off(p_user, d.day) then 'Rest Day'
              else 'Absent' end,
         to_char(a.check_in_at  at time zone 'Asia/Kolkata', 'HH24:MI'),
         to_char(a.check_out_at at time zone 'Asia/Kolkata', 'HH24:MI'),
         round(a.work_minutes / 60.0, 2),
         coalesce(a.is_late, false),
         coalesce(h.name, lv.leave_type, 'Tour - ' || tr.city, ''),
         a.source,
         a.site_name
  from d
  left join public.attendance a on a.user_id = p_user and a.work_date = d.day
  left join public.holidays   h on h.day = d.day
  left join lateral (
    select l.leave_type from public.leaves l
     where l.user_id = p_user and l.status = 'Approved'
       and d.day between l.from_day and l.to_day
     order by l.id desc limit 1) lv on true
  left join lateral (
    select t.city from public.tours t
     where t.user_id = p_user and t.status = 'Approved'
       and d.day between t.from_day and t.to_day
     order by t.id desc limit 1) tr on true
  order by d.day
$$;

-- Live board: an employee on an approved tour shows "On Tour"
create or replace function public.admin_today_board(p_date date default null)
returns table (
  user_id uuid, username text, full_name text, department text, role text,
  site_employee boolean, shift_start time,
  check_in_at timestamptz, check_out_at timestamptz,
  in_time text, out_time text, status text, is_late boolean,
  work_minutes int, source text, site_name text, leave_type text
)
language plpgsql stable security definer set search_path = public as $$
declare
  v_day date := coalesce(p_date, public.ist_today());
  v_holiday text;
begin
  perform public._require_admin();
  select name into v_holiday from public.holidays where day = v_day;
  return query
  select p.id, p.username, p.full_name, p.department, p.role,
         p.site_employee, p.shift_start,
         a.check_in_at, a.check_out_at,
         to_char(a.check_in_at  at time zone 'Asia/Kolkata', 'HH24:MI'),
         to_char(a.check_out_at at time zone 'Asia/Kolkata', 'HH24:MI'),
         case when a.check_out_at is not null then 'Present'
              when a.check_in_at  is not null then 'Checked In'
              when lv.leave_type  is not null then 'Leave'
              when v_holiday      is not null then 'Holiday'
              when public._is_weekly_off(p.id, v_day) then 'Rest Day'
              when tr.city        is not null then 'On Tour'
              when v_day = public.ist_today() then 'Not Checked In'
              else 'Absent' end,
         coalesce(a.is_late, false),
         case when a.check_out_at is null and a.check_in_at is not null and v_day = public.ist_today()
              then (extract(epoch from (now() - a.check_in_at)) / 60)::int
              else a.work_minutes end,
         a.source, coalesce(a.site_name, 'Tour - ' || tr.city), lv.leave_type
  from public.profiles p
  left join public.attendance a on a.user_id = p.id and a.work_date = v_day
  left join lateral (
    select l.leave_type from public.leaves l
     where l.user_id = p.id and l.status = 'Approved' and v_day between l.from_day and l.to_day
     limit 1) lv on true
  left join lateral (
    select t.city from public.tours t
     where t.user_id = p.id and t.status = 'Approved' and v_day between t.from_day and t.to_day
     limit 1) tr on true
  where p.active
  order by (a.check_in_at is null), a.check_in_at desc nulls last, p.full_name;
end $$;

revoke execute on function public._month_attendance(uuid, int, int) from public, anon, authenticated;
revoke execute on function public.admin_today_board(date) from public, anon;
grant  execute on function public.admin_today_board(date) to authenticated;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------
-- 37. TOUR REPORT: expenses, documents and the tasks completed on a tour
--     * While an APPROVED tour is running (and for 7 days after its last day) the employee adds:
--         - Expenses  : date, category, amount, note and a receipt photo
--         - Documents : a title and a photo / scan of the document
--         - Tasks     : what was completed (meeting, work) and a remark
--     * Admin / HR see everything per tour with the total expense. Nothing can be added to a tour that is not approved.
-- ---------------------------------------------------------------------
create table if not exists public.tour_expenses (
  id            bigint generated always as identity primary key,
  tour_id       bigint not null references public.tours(id) on delete cascade,
  user_id       uuid   not null references public.profiles(id) on delete cascade,
  expense_date  date   not null,
  category      text   not null check (category in ('Travel','Food','Stay','Local transport','Fuel','Other')),
  amount        numeric(12,2) not null check (amount > 0),
  note          text,
  receipt_path  text,
  created_at    timestamptz not null default now()
);
create table if not exists public.tour_tasks (
  id          bigint generated always as identity primary key,
  tour_id     bigint not null references public.tours(id) on delete cascade,
  user_id     uuid   not null references public.profiles(id) on delete cascade,
  task_date   date   not null,
  task        text   not null check (length(trim(task)) > 0),
  remark      text,
  created_at  timestamptz not null default now()
);
create table if not exists public.tour_documents (
  id          bigint generated always as identity primary key,
  tour_id     bigint not null references public.tours(id) on delete cascade,
  user_id     uuid   not null references public.profiles(id) on delete cascade,
  title       text   not null check (length(trim(title)) > 0),
  file_path   text   not null,
  created_at  timestamptz not null default now()
);
create index if not exists tour_expenses_tour_idx  on public.tour_expenses (tour_id);
create index if not exists tour_tasks_tour_idx     on public.tour_tasks (tour_id);
create index if not exists tour_documents_tour_idx on public.tour_documents (tour_id);

do $$
declare t text;
begin
  foreach t in array array['tour_expenses','tour_tasks','tour_documents'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists %I on public.%I', t || '_read', t);
    execute format('create policy %I on public.%I for select to authenticated using (user_id = auth.uid() or public.is_staff_admin())', t || '_read', t);
    execute format('revoke all on public.%I from anon', t);
    execute format('grant select on public.%I to authenticated', t);
    if not exists (select 1 from pg_publication_tables
                    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

-- The caller's own approved tour that is still open for entries (internal)
create or replace function public._tour_open(p_tour bigint) returns public.tours
language plpgsql stable security definer set search_path = public as $$
declare me public.profiles := public._require_active(); t public.tours;
begin
  select * into t from public.tours where id = p_tour and user_id = me.id;
  if t.id is null then raise exception 'Tour not found'; end if;
  if t.status <> 'Approved' then raise exception 'You can add expenses and reports only to an approved tour'; end if;
  if public.ist_today() < t.from_day then raise exception 'This tour starts on %', to_char(t.from_day, 'DD-MM-YYYY'); end if;
  if public.ist_today() > t.to_day + 7 then raise exception 'This tour is closed (entries are allowed up to 7 days after it ends)'; end if;
  return t;
end $$;

create or replace function public.add_tour_expense(
  p_tour bigint, p_date date, p_category text, p_amount numeric, p_note text default null, p_receipt text default null
) returns public.tour_expenses
language plpgsql security definer set search_path = public as $$
declare t public.tours := public._tour_open(p_tour); r public.tour_expenses;
begin
  if p_date is null or p_date < t.from_day or p_date > t.to_day then
    raise exception 'The expense date must be within the tour dates (% to %)', to_char(t.from_day,'DD-MM-YYYY'), to_char(t.to_day,'DD-MM-YYYY');
  end if;
  if p_amount is null or p_amount <= 0 then raise exception 'Enter the amount'; end if;
  if p_receipt is not null and split_part(p_receipt, '/', 1) <> t.user_id::text then raise exception 'Invalid receipt file'; end if;
  insert into public.tour_expenses (tour_id, user_id, expense_date, category, amount, note, receipt_path)
  values (t.id, t.user_id, p_date, p_category, round(p_amount, 2), nullif(trim(p_note),''), p_receipt)
  returning * into r;
  perform public._audit('TOUR_EXPENSE', t.city || ' ' || p_category || ' ' || r.amount);
  return r;
end $$;

create or replace function public.add_tour_task(
  p_tour bigint, p_date date, p_task text, p_remark text default null
) returns public.tour_tasks
language plpgsql security definer set search_path = public as $$
declare t public.tours := public._tour_open(p_tour); r public.tour_tasks;
begin
  if p_date is null or p_date < t.from_day or p_date > t.to_day + 7 then
    raise exception 'Choose a date within the tour dates';
  end if;
  if nullif(trim(p_task),'') is null then raise exception 'Enter the task / meeting completed'; end if;
  insert into public.tour_tasks (tour_id, user_id, task_date, task, remark)
  values (t.id, t.user_id, p_date, trim(p_task), nullif(trim(p_remark),'')) returning * into r;
  perform public._audit('TOUR_TASK', t.city || ' ' || left(r.task, 60));
  return r;
end $$;

create or replace function public.add_tour_document(p_tour bigint, p_title text, p_path text)
returns public.tour_documents
language plpgsql security definer set search_path = public as $$
declare t public.tours := public._tour_open(p_tour); r public.tour_documents;
begin
  if nullif(trim(p_title),'') is null then raise exception 'Enter the document name'; end if;
  if p_path is null or split_part(p_path, '/', 1) <> t.user_id::text then raise exception 'Attach the document first'; end if;
  insert into public.tour_documents (tour_id, user_id, title, file_path)
  values (t.id, t.user_id, trim(p_title), p_path) returning * into r;
  perform public._audit('TOUR_DOCUMENT', t.city || ' ' || r.title);
  return r;
end $$;

-- Removes one of the caller's own entries while the tour is still open. Returns the file path to delete from storage (or null).
create or replace function public.delete_tour_item(p_kind text, p_id bigint) returns text
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._require_active(); v_tour bigint; v_path text;
begin
  if p_kind = 'expense' then
    select tour_id, receipt_path into v_tour, v_path from public.tour_expenses where id = p_id and user_id = me.id;
  elsif p_kind = 'task' then
    select tour_id into v_tour from public.tour_tasks where id = p_id and user_id = me.id;
  elsif p_kind = 'document' then
    select tour_id, file_path into v_tour, v_path from public.tour_documents where id = p_id and user_id = me.id;
  else raise exception 'Unknown item'; end if;
  if v_tour is null then raise exception 'Entry not found'; end if;
  perform public._tour_open(v_tour);
  if p_kind = 'expense' then delete from public.tour_expenses where id = p_id;
  elsif p_kind = 'task' then delete from public.tour_tasks where id = p_id;
  else delete from public.tour_documents where id = p_id; end if;
  perform public._audit('TOUR_DELETE_' || upper(p_kind), p_id::text);
  return v_path;
end $$;

revoke execute on function public._tour_open(bigint) from public, anon, authenticated;
revoke execute on function public.add_tour_expense(bigint, date, text, numeric, text, text) from public, anon;
revoke execute on function public.add_tour_task(bigint, date, text, text) from public, anon;
revoke execute on function public.add_tour_document(bigint, text, text) from public, anon;
revoke execute on function public.delete_tour_item(text, bigint) from public, anon;
grant  execute on function public.add_tour_expense(bigint, date, text, numeric, text, text) to authenticated;
grant  execute on function public.add_tour_task(bigint, date, text, text) to authenticated;
grant  execute on function public.add_tour_document(bigint, text, text) to authenticated;
grant  execute on function public.delete_tour_item(text, bigint) to authenticated;

-- Private bucket for receipts and tour documents. Path: <user-uuid>/<tour-id>/<timestamp>.jpg
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('tour_files', 'tour_files', false, 8388608, array['image/jpeg','image/png','image/webp'])
on conflict (id) do update
  set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists tour_files_upload_own on storage.objects;
create policy tour_files_upload_own on storage.objects for insert to authenticated
  with check (bucket_id = 'tour_files' and (storage.foldername(name))[1] = auth.uid()::text and public.is_active_user());
drop policy if exists tour_files_read on storage.objects;
create policy tour_files_read on storage.objects for select to authenticated
  using (bucket_id = 'tour_files' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_staff_admin()));
drop policy if exists tour_files_delete_own on storage.objects;
create policy tour_files_delete_own on storage.objects for delete to authenticated
  using (bucket_id = 'tour_files' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_staff_admin()));

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------
-- 38. ACCESS CONTROL: Tour and Documents are switched on per employee by Admin / HR
--     * profiles.tour_access      : the employee can use Tour (apply, expenses, report). Existing tour users keep it.
--     * profiles.documents_access : the employee can upload documents with a remark (e.g. site-to-site handover papers)
--                                   and sees the documents Admin / HR upload for him.
--     * Admin / HR can upload a document for any employee (letters, forms, slips) with a remark, and see everything
--       the employee uploaded. Files live in the private "employee_docs" bucket: <employee-uuid>/<timestamp>-<name>.
-- ---------------------------------------------------------------------
alter table public.profiles add column if not exists tour_access      boolean not null default false;
alter table public.profiles add column if not exists documents_access boolean not null default false;

do $$
begin
  if not exists (select 1 from public.audit_log where action = 'TOUR_ACCESS_BACKFILL') then
    update public.profiles set tour_access = true where id in (select user_id from public.tours);
    insert into public.audit_log (actor_id, action, detail) values (null, 'TOUR_ACCESS_BACKFILL', 'Employees with an existing tour keep Tour access');
  end if;
end $$;

create or replace function public.admin_set_feature_access(p_user uuid, p_feature text, p_enabled boolean)
returns public.profiles
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._require_admin(); target public.profiles;
begin
  if p_feature not in ('tour', 'documents') then raise exception 'Unknown access'; end if;
  select * into target from public.profiles where id = p_user for update;
  if target.id is null then raise exception 'User not found'; end if;
  if me.role <> 'Admin' and target.id <> me.id and target.role <> 'Employee' then
    raise exception 'Only an Admin can change HR / Admin accounts';
  end if;
  if p_feature = 'tour' then
    update public.profiles set tour_access = p_enabled where id = p_user returning * into target;
  else
    update public.profiles set documents_access = p_enabled where id = p_user returning * into target;
  end if;
  perform public._audit('FEATURE_ACCESS', target.username || ' ' || p_feature || '=' || p_enabled);
  return target;
end $$;

-- Tour now needs the access switch
create or replace function public.apply_tour(p_city text, p_from date, p_to date, p_reason text)
returns public.tours
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._require_active(); r public.tours;
begin
  if not me.tour_access then raise exception 'Tour is not enabled for your account. Ask your Admin'; end if;
  if nullif(trim(p_city),'') is null then raise exception 'Enter the city'; end if;
  if p_to < p_from then raise exception 'End date cannot be before start date'; end if;
  if nullif(trim(p_reason),'') is null then raise exception 'Enter the purpose of the tour'; end if;
  if exists (select 1 from public.tours where user_id = me.id and status in ('Pending','Approved')
              and from_day <= p_to and to_day >= p_from) then
    raise exception 'These dates overlap with another tour request';
  end if;
  if exists (select 1 from public.leaves where user_id = me.id and status in ('Pending','Approved')
              and from_day <= p_to and to_day >= p_from) then
    raise exception 'These dates overlap with a leave request';
  end if;
  insert into public.tours (user_id, city, from_day, to_day, reason)
  values (me.id, trim(p_city), p_from, p_to, trim(p_reason)) returning * into r;
  perform public._audit('TOUR_REQUEST', r.city || ' ' || p_from || ' to ' || p_to);
  return r;
end $$;

create or replace function public._tour_open(p_tour bigint) returns public.tours
language plpgsql stable security definer set search_path = public as $$
declare me public.profiles := public._require_active(); t public.tours;
begin
  if not me.tour_access then raise exception 'Tour is not enabled for your account. Ask your Admin'; end if;
  select * into t from public.tours where id = p_tour and user_id = me.id;
  if t.id is null then raise exception 'Tour not found'; end if;
  if t.status <> 'Approved' then raise exception 'You can add expenses and reports only to an approved tour'; end if;
  if public.ist_today() < t.from_day then raise exception 'This tour starts on %', to_char(t.from_day, 'DD-MM-YYYY'); end if;
  if public.ist_today() > t.to_day + 7 then raise exception 'This tour is closed (entries are allowed up to 7 days after it ends)'; end if;
  return t;
end $$;

create table if not exists public.employee_documents (
  id           bigint generated always as identity primary key,
  user_id      uuid not null references public.profiles(id) on delete cascade,   -- the employee the document belongs to
  direction    text not null check (direction in ('from_employee', 'from_admin')),
  title        text not null check (length(trim(title)) > 0),
  remark       text,
  file_path    text not null,
  file_name    text,
  uploaded_by  uuid references public.profiles(id) on delete set null,
  created_at   timestamptz not null default now()
);
create index if not exists employee_documents_user_idx on public.employee_documents (user_id, id desc);
alter table public.employee_documents enable row level security;
drop policy if exists employee_documents_read on public.employee_documents;
create policy employee_documents_read on public.employee_documents for select to authenticated
  using (user_id = auth.uid() or public.is_staff_admin());
revoke all on public.employee_documents from anon;
grant select on public.employee_documents to authenticated;

do $$
begin
  if not exists (select 1 from pg_publication_tables
                  where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'employee_documents') then
    alter publication supabase_realtime add table public.employee_documents;
  end if;
end $$;

-- p_user null (or yourself) = the employee uploads his own document (needs Documents access)
-- p_user = another employee = Admin / HR upload a document for him
create or replace function public.add_employee_document(
  p_user uuid, p_title text, p_remark text, p_path text, p_file_name text default null
) returns public.employee_documents
language plpgsql security definer set search_path = public as $$
declare
  me     public.profiles := public._require_active();
  v_for  uuid := coalesce(p_user, me.id);
  v_dir  text;
  t      public.profiles;
  r      public.employee_documents;
begin
  if v_for = me.id then
    if not me.documents_access then raise exception 'Documents are not enabled for your account. Ask your Admin'; end if;
    v_dir := 'from_employee';
  else
    me := public._require_admin();
    select * into t from public.profiles where id = v_for and active;
    if t.id is null then raise exception 'User not found'; end if;
    if me.role <> 'Admin' and t.role <> 'Employee' then raise exception 'Only an Admin can change HR / Admin accounts'; end if;
    v_dir := 'from_admin';
  end if;
  if nullif(trim(p_title),'') is null then raise exception 'Enter the document name'; end if;
  if p_path is null or split_part(p_path, '/', 1) <> v_for::text then raise exception 'Attach the document first'; end if;
  insert into public.employee_documents (user_id, direction, title, remark, file_path, file_name, uploaded_by)
  values (v_for, v_dir, trim(p_title), nullif(trim(p_remark),''), p_path, nullif(trim(p_file_name),''), me.id)
  returning * into r;
  perform public._audit('EMPLOYEE_DOCUMENT', v_dir || ' ' || r.title);
  return r;
end $$;

-- Admin / HR: delete a document. Returns the file path to remove from storage.
create or replace function public.delete_employee_document(p_id bigint) returns text
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._require_admin(); v_path text; v_title text;
begin
  delete from public.employee_documents where id = p_id returning file_path, title into v_path, v_title;
  if v_path is null then raise exception 'Document not found'; end if;
  perform public._audit('DELETE_EMPLOYEE_DOCUMENT', v_title);
  return v_path;
end $$;

revoke execute on function public.admin_set_feature_access(uuid, text, boolean) from public, anon;
revoke execute on function public.apply_tour(text, date, date, text) from public, anon;
revoke execute on function public._tour_open(bigint) from public, anon, authenticated;
revoke execute on function public.add_employee_document(uuid, text, text, text, text) from public, anon;
revoke execute on function public.delete_employee_document(bigint) from public, anon;
grant  execute on function public.admin_set_feature_access(uuid, text, boolean) to authenticated;
grant  execute on function public.apply_tour(text, date, date, text) to authenticated;
grant  execute on function public.add_employee_document(uuid, text, text, text, text) to authenticated;
grant  execute on function public.delete_employee_document(bigint) to authenticated;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('employee_docs', 'employee_docs', false, 10485760, array[
  'application/pdf', 'image/jpeg', 'image/png', 'image/webp',
  'application/msword', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'application/vnd.ms-excel', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'])
on conflict (id) do update
  set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists employee_docs_upload on storage.objects;
create policy employee_docs_upload on storage.objects for insert to authenticated
  with check (
    bucket_id = 'employee_docs'
    and (public.is_staff_admin()
         or ((storage.foldername(name))[1] = auth.uid()::text
             and exists (select 1 from public.profiles p where p.id = auth.uid() and p.active and p.documents_access)))
  );
drop policy if exists employee_docs_read on storage.objects;
create policy employee_docs_read on storage.objects for select to authenticated
  using (bucket_id = 'employee_docs' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_staff_admin()));
drop policy if exists employee_docs_delete on storage.objects;
create policy employee_docs_delete on storage.objects for delete to authenticated
  using (bucket_id = 'employee_docs' and public.is_staff_admin());

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------
-- 39. WIDE SITE: check-out from a different place than the check-in (site employees)
--     * Some sites spread over many km (roads, pipelines): the employee checks in at one end and checks out at another.
--     * Admin / HR switch "Wide Site Check-out" ON for such a site employee (Access Control).
--     * For that employee a check-out:
--         - is NOT refused / flagged for being away from the site centre or from the check-in place,
--         - still needs location and a NEW selfie (different from the check-in selfie),
--         - saves its own location, so Admin / HR see both the check-in and the check-out place.
--     * Check-in is unchanged (still at the chosen site). The 1 km same-place rule of travel check-out is lifted too.
-- ---------------------------------------------------------------------
alter table public.profiles add column if not exists wide_site_access boolean not null default false;

create or replace function public.admin_set_feature_access(p_user uuid, p_feature text, p_enabled boolean)
returns public.profiles
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._require_admin(); target public.profiles;
begin
  if p_feature not in ('tour', 'documents', 'wide_site') then raise exception 'Unknown access'; end if;
  select * into target from public.profiles where id = p_user for update;
  if target.id is null then raise exception 'User not found'; end if;
  if me.role <> 'Admin' and target.id <> me.id and target.role <> 'Employee' then
    raise exception 'Only an Admin can change HR / Admin accounts';
  end if;
  if p_feature = 'tour' then
    update public.profiles set tour_access = p_enabled where id = p_user returning * into target;
  elsif p_feature = 'documents' then
    update public.profiles set documents_access = p_enabled where id = p_user returning * into target;
  else
    update public.profiles set wide_site_access = p_enabled where id = p_user returning * into target;
  end if;
  perform public._audit('FEATURE_ACCESS', target.username || ' ' || p_feature || '=' || p_enabled);
  return target;
end $$;

create or replace function public.check_out(
  p_lat        double precision default null,
  p_lng        double precision default null,
  p_site_name  text default null,
  p_note       text default null,
  p_photo_path text default null,
  p_site_id    bigint default null
) returns public.attendance
language plpgsql security definer set search_path = public as $$
declare
  me        public.profiles := public._require_active();
  v_site    boolean := me.site_employee and not public._is_office_site(p_site_id);
  v_now     timestamp := public.ist_now();
  v_outside boolean := false;
  v_office  text;
  v_od      integer;
  g         record;
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

  if not me.site_employee and (p_photo_path is not null or nullif(trim(p_site_name),'') is not null) then
    raise exception 'Site selfie attendance is not enabled for your account';
  end if;

  if v_site then
    if p_lat is null or p_lng is null then
      raise exception 'Location is required. Turn on location and try again';
    end if;
    select * into g from public._geofence_check(p_site_id, p_lat, p_lng);
    v_outside := not g.inside;
    if me.wide_site_access then v_outside := false; end if;      -- wide site: check-out may be anywhere
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
  else
    select o.site_name, o.distance_m into v_office, v_od from public._office_check(me.id, p_lat, p_lng) o;
  end if;

  update public.attendance
     set check_out_at  = now(),
         check_out_lat = p_lat,
         check_out_lng = p_lng,
         check_out_dist_m = v_od,
         note          = coalesce(nullif(trim(p_note),''), note)
   where id = r.id
  returning * into r;

  if v_site then
    insert into public.selfie_records (user_id, attendance_id, kind, site_name, note, photo_path, lat, lng, outside, distance_m)
    values (me.id, r.id, 'OUT', trim(p_site_name), nullif(trim(p_note),''), p_photo_path, p_lat, p_lng, v_outside, g.distance_m);
    perform public._audit(case when v_outside then 'SITE_CHECK_OUT_OUTSIDE' else 'SITE_SELFIE_CHECK_OUT' end,
      trim(p_site_name) || case when v_outside then ' (' || coalesce(g.distance_m::text, '?') || ' m away)'
                                when me.wide_site_access then ' (wide site, ' || coalesce(g.distance_m::text, '?') || ' m from the site centre)' else '' end);
  else
    perform public._audit('CHECK_OUT', to_char(v_now, 'HH24:MI') || coalesce(' at ' || v_office || ' (' || v_od || ' m from the office point)', ''));
  end if;
  return r;
end $$;

create or replace function public.site_travel_check_out(
  p_lat double precision default null, p_lng double precision default null,
  p_note text default null, p_photo_path text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me        public.profiles := public._require_active();
  v_now     timestamp := public.ist_now();
  lg        public.attendance_legs;
  g         record;
  v_outside boolean;
  d         double precision;
  v_off     boolean;
  v_od      integer;
begin
  if not (me.travel_access and me.site_employee) then
    raise exception 'Site travel attendance is not enabled for your account';
  end if;
  if p_lat is null or p_lng is null then
    raise exception 'Location is required. Turn on location and try again';
  end if;
  perform set_config('app.travel_rpc', 'on', true);

  select * into lg from public.attendance_legs
   where user_id = me.id and work_date = v_now::date and out_at is null
   order by leg desc limit 1 for update;
  if lg.id is null then raise exception 'No check-in to close. Check in first'; end if;

  d := public._distance_m(lg.in_lat, lg.in_lng, p_lat, p_lng);
  if d > 1000 and not me.wide_site_access then
    raise exception 'Check out from the same place where you checked in (you are % m away)', round(d);
  end if;

  v_off := public._is_office_site(lg.site_id);
  if v_off then
    select o.distance_m into v_od from public._office_check(me.id, p_lat, p_lng) o;
    p_photo_path := null; v_outside := false;
  else
    select * into g from public._geofence_check(lg.site_id, p_lat, p_lng);
    v_outside := not g.inside; v_od := g.distance_m;
    if me.wide_site_access then v_outside := false; end if;      -- wide site: check-out may be anywhere
    if v_outside then p_photo_path := null;
    else
      if p_photo_path is null or split_part(p_photo_path, '/', 1) <> me.id::text then raise exception 'Take a selfie first'; end if;
      if exists (select 1 from public.selfie_records where attendance_id = lg.attendance_id and photo_path = p_photo_path) then
        raise exception 'Check-out needs a new selfie, different from the check-in selfie';
      end if;
    end if;
  end if;

  update public.attendance_legs set out_at = clock_timestamp(), out_lat = p_lat, out_lng = p_lng, out_dist_m = v_od where id = lg.id;
  update public.attendance set check_out_at = clock_timestamp(), check_out_lat = p_lat, check_out_lng = p_lng,
         note = coalesce(nullif(trim(p_note),''), note)
   where id = lg.attendance_id;
  if not v_off then
    insert into public.selfie_records (user_id, attendance_id, kind, site_name, note, photo_path, lat, lng, outside, distance_m)
    values (me.id, lg.attendance_id, 'OUT', coalesce(lg.site_name, '-'), nullif(trim(p_note),''), p_photo_path, p_lat, p_lng, v_outside, g.distance_m);
  end if;
  perform public._audit('SITE_TRAVEL_CHECK_OUT', 'stop ' || lg.leg || ' ' || coalesce(lg.site_name, ''));
  return public._travel_today(me.id);
end $$;

revoke execute on function public.admin_set_feature_access(uuid, text, boolean) from public, anon;
revoke execute on function public.check_out(double precision, double precision, text, text, text, bigint) from public, anon;
revoke execute on function public.site_travel_check_out(double precision, double precision, text, text) from public, anon;
grant  execute on function public.admin_set_feature_access(uuid, text, boolean) to authenticated;
grant  execute on function public.check_out(double precision, double precision, text, text, text, bigint) to authenticated;
grant  execute on function public.site_travel_check_out(double precision, double precision, text, text) to authenticated;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------
-- 40. LOGIN REGISTRATION WITH ADMIN APPROVAL + FOREIGN LOCATION CHECK-OUT
--
--  A. Employees create their own username and password:
--     1. The employee types his mobile number in the app -> a LOGIN REQUEST goes to Admin / HR (Approvals -> Login).
--     2. Admin / HR approve it. The approval shows a 6-digit CODE (shown once); they pass it to the employee.
--        (Sending the code by SMS needs an SMS provider; until one is connected the code is given by Admin / HR.)
--     3. The employee enters mobile number + code, chooses a username and a password. Works once; the code is valid 2 days
--        and is locked after 5 wrong tries.
--     The old direct "register with mobile number" function is removed, so nobody can skip the approval.
--
--  B. FOREIGN LOCATION check-out (site employees with "Foreign Location Access" switched on by Admin / HR):
--     * The check-out can be made from any place. A selfie is still required at check-in and at check-out.
--     * When the check-out place is outside the site area ("foreign location") a REASON is required.
--     * The check-out coordinates, the distance to the site and the reason are saved; Admin / HR see them.
-- ---------------------------------------------------------------------
create table if not exists public.login_requests (
  id           bigint generated always as identity primary key,
  user_id      uuid not null references public.profiles(id) on delete cascade,
  mobile       text not null,
  status       text not null default 'Pending' check (status in ('Pending','Approved','Rejected','Used')),
  code_hash    text,
  attempts     integer not null default 0,
  created_at   timestamptz not null default now(),
  reviewed_by  uuid references public.profiles(id),
  reviewed_at  timestamptz,
  used_at      timestamptz
);
create index if not exists login_requests_status_idx on public.login_requests (status, id desc);
alter table public.login_requests enable row level security;
drop policy if exists login_requests_read on public.login_requests;
create policy login_requests_read on public.login_requests for select to authenticated
  using (public.is_staff_admin());
revoke all on public.login_requests from anon;
grant select on public.login_requests to authenticated;
do $$
begin
  if not exists (select 1 from pg_publication_tables
                  where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'login_requests') then
    alter publication supabase_realtime add table public.login_requests;
  end if;
end $$;

-- Public (before sign-in): the employee asks for approval with his mobile number.
-- The answer is always the same, so nobody can find out which numbers exist.
create or replace function public.request_login(p_mobile text) returns text
language plpgsql security definer set search_path = public as $$
declare k text := public._phone_key(p_mobile); ids uuid[];
begin
  if length(k) < 10 then raise exception 'Enter your 10-digit mobile number'; end if;
  select array_agg(id) into ids from public.profiles
   where role = 'Employee' and active and not login_claimed and public._phone_key(phone) = k;
  if coalesce(array_length(ids, 1), 0) = 1 then
    delete from public.login_requests where user_id = ids[1] and status in ('Pending', 'Approved');
    insert into public.login_requests (user_id, mobile) values (ids[1], k);
  end if;
  return 'Your request was sent to Admin / HR. After they approve it you will get a 6-digit code.';
end $$;

-- Admin / HR: approve (returns the code ONCE) or reject a login request
create or replace function public.review_login_request(p_id bigint, p_approve boolean) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare me public.profiles := public._require_admin(); r public.login_requests; v_code text;
begin
  select * into r from public.login_requests where id = p_id for update;
  if r.id is null then raise exception 'Request not found'; end if;
  if r.status <> 'Pending' then raise exception 'This request is already %', lower(r.status); end if;
  if p_approve then
    v_code := lpad(((('x' || encode(gen_random_bytes(3), 'hex'))::bit(24)::int) % 1000000)::text, 6, '0');
    update public.login_requests
       set status = 'Approved', code_hash = encode(digest(v_code || r.user_id::text, 'sha256'), 'hex'),
           attempts = 0, reviewed_by = me.id, reviewed_at = now()
     where id = p_id;
    perform public._audit('APPROVE_LOGIN_REQUEST', r.user_id::text);
    return v_code;
  end if;
  update public.login_requests set status = 'Rejected', reviewed_by = me.id, reviewed_at = now() where id = p_id;
  perform public._audit('REJECT_LOGIN_REQUEST', r.user_id::text);
  return null;
end $$;

-- The direct registration (no approval) is removed
drop function if exists public.register_with_mobile(text, text, text);

-- Public (before sign-in): mobile number + the approved code + the username and password he chooses
create or replace function public.register_with_mobile(p_mobile text, p_code text, p_username text, p_password text)
returns text
language plpgsql security definer set search_path = public, extensions as $$
declare
  k   text := public._phone_key(p_mobile);
  r   public.login_requests;
  v_u text := lower(trim(coalesce(p_username, '')));
  bad constant text := 'This code is not valid. Check the mobile number and the code, or ask HR / Admin';
begin
  if length(k) < 10 then raise exception 'Enter your 10-digit mobile number'; end if;
  if v_u !~ '^[a-z0-9._-]{2,40}$' then
    raise exception 'Username may contain letters, numbers, dot, dash and underscore (2-40 characters)';
  end if;
  if length(coalesce(p_password, '')) < 12 then raise exception 'Password must be at least 12 characters'; end if;

  select q.* into r from public.login_requests q
    join public.profiles p on p.id = q.user_id
   where q.status = 'Approved' and q.mobile = k and p.active and not p.login_claimed
     and q.reviewed_at > now() - interval '2 days'
   order by q.id desc limit 1 for update of q;
  if r.id is null or r.attempts >= 5 then raise exception '%', bad; end if;
  if r.code_hash <> encode(digest(regexp_replace(coalesce(p_code, ''), '\D', '', 'g') || r.user_id::text, 'sha256'), 'hex') then
    update public.login_requests set attempts = attempts + 1 where id = r.id;
    raise exception '%', bad;
  end if;
  if exists (select 1 from public.profiles where username = v_u and id <> r.user_id) then
    raise exception 'This username is already taken. Choose another one';
  end if;

  update public.profiles set username = v_u, login_claimed = true where id = r.user_id;
  update auth.users set encrypted_password = crypt(p_password, gen_salt('bf')), updated_at = now() where id = r.user_id;
  update public.login_requests set status = 'Used', used_at = now(), code_hash = null where id = r.id;
  insert into public.audit_log (actor_id, action, detail) values (r.user_id, 'REGISTER_MOBILE', v_u);
  return v_u;
end $$;

revoke execute on function public.request_login(text) from public;
revoke execute on function public.review_login_request(bigint, boolean) from public, anon;
revoke execute on function public.register_with_mobile(text, text, text, text) from public;
grant  execute on function public.request_login(text) to anon, authenticated;
grant  execute on function public.review_login_request(bigint, boolean) to authenticated;
grant  execute on function public.register_with_mobile(text, text, text, text) to anon, authenticated;

-- ---- B. Foreign location ----
alter table public.selfie_records add column if not exists foreign_loc boolean not null default false;
alter table public.selfie_records add column if not exists reason      text;
alter table public.attendance     add column if not exists check_out_reason text;

drop function if exists public.check_out(double precision, double precision, text, text, text, bigint);
create or replace function public.check_out(
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

  if not me.site_employee and (p_photo_path is not null or nullif(trim(p_site_name),'') is not null) then
    raise exception 'Site selfie attendance is not enabled for your account';
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
  else
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

  if v_site then
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

drop function if exists public.site_travel_check_out(double precision, double precision, text, text);
create or replace function public.site_travel_check_out(
  p_lat double precision default null, p_lng double precision default null,
  p_note text default null, p_photo_path text default null, p_reason text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me        public.profiles := public._require_active();
  v_now     timestamp := public.ist_now();
  lg        public.attendance_legs;
  g         record;
  v_outside boolean;
  v_foreign boolean := false;
  d         double precision;
  v_off     boolean;
  v_od      integer;
begin
  if not (me.travel_access and me.site_employee) then
    raise exception 'Site travel attendance is not enabled for your account';
  end if;
  if p_lat is null or p_lng is null then
    raise exception 'Location is required. Turn on location and try again';
  end if;
  perform set_config('app.travel_rpc', 'on', true);

  select * into lg from public.attendance_legs
   where user_id = me.id and work_date = v_now::date and out_at is null
   order by leg desc limit 1 for update;
  if lg.id is null then raise exception 'No check-in to close. Check in first'; end if;

  d := public._distance_m(lg.in_lat, lg.in_lng, p_lat, p_lng);
  if d > 1000 and not me.wide_site_access then
    raise exception 'Check out from the same place where you checked in (you are % m away)', round(d);
  end if;

  v_off := public._is_office_site(lg.site_id);
  if v_off then
    select o.distance_m into v_od from public._office_check(me.id, p_lat, p_lng) o;
    p_photo_path := null; v_outside := false;
  else
    select * into g from public._geofence_check(lg.site_id, p_lat, p_lng);
    v_outside := not g.inside; v_od := g.distance_m;
    if me.wide_site_access and v_outside then
      v_foreign := true; v_outside := false;
      if nullif(trim(p_reason),'') is null then
        raise exception 'Give the reason for checking out from another (foreign) location';
      end if;
    end if;
    if v_outside then p_photo_path := null;
    else
      if p_photo_path is null or split_part(p_photo_path, '/', 1) <> me.id::text then raise exception 'Take a selfie first'; end if;
      if exists (select 1 from public.selfie_records where attendance_id = lg.attendance_id and photo_path = p_photo_path) then
        raise exception 'Check-out needs a new selfie, different from the check-in selfie';
      end if;
    end if;
  end if;

  update public.attendance_legs set out_at = clock_timestamp(), out_lat = p_lat, out_lng = p_lng, out_dist_m = v_od where id = lg.id;
  update public.attendance set check_out_at = clock_timestamp(), check_out_lat = p_lat, check_out_lng = p_lng,
         check_out_reason = case when v_foreign then trim(p_reason) else check_out_reason end,
         note = coalesce(nullif(trim(p_note),''), note)
   where id = lg.attendance_id;
  if not v_off then
    insert into public.selfie_records (user_id, attendance_id, kind, site_name, note, photo_path, lat, lng, outside, distance_m, foreign_loc, reason)
    values (me.id, lg.attendance_id, 'OUT', coalesce(lg.site_name, '-'), nullif(trim(p_note),''), p_photo_path, p_lat, p_lng, v_outside, g.distance_m,
            v_foreign, case when v_foreign then trim(p_reason) else null end);
  end if;
  perform public._audit('SITE_TRAVEL_CHECK_OUT', 'stop ' || lg.leg || ' ' || coalesce(lg.site_name, '')
    || case when v_foreign then ' (foreign location): ' || trim(p_reason) else '' end);
  return public._travel_today(me.id);
end $$;

revoke execute on function public.check_out(double precision, double precision, text, text, text, bigint, text) from public, anon;
revoke execute on function public.site_travel_check_out(double precision, double precision, text, text, text) from public, anon;
grant  execute on function public.check_out(double precision, double precision, text, text, text, bigint, text) to authenticated;
grant  execute on function public.site_travel_check_out(double precision, double precision, text, text, text) to authenticated;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------
-- 41. SITE EMPLOYEES WORK 9:00 AM - 6:00 PM
--     Every existing site employee is set to 09:00 - 18:00 ONCE (a marker in the audit log stops it from running again,
--     so a shift changed later is not overwritten). Office employees keep 08:30 - 17:30.
-- ---------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from public.audit_log where action = 'SITE_SHIFT_900_1800_SET') then
    update public.profiles set shift_start = '09:00', shift_end = '18:00' where site_employee and role = 'Employee';
    insert into public.audit_log (actor_id, action, detail) values (null, 'SITE_SHIFT_900_1800_SET', 'All site employees set to 09:00 - 18:00');
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 42. NO LATE MARK FOR ANY SITE EMPLOYEE
--     The trigger in section 35 already stops new late marks for site employees. This also clears every late mark
--     that is already stored for a site employee (all past days). Safe to run again at any time.
-- ---------------------------------------------------------------------
update public.attendance a
   set is_late = false
  from public.profiles p
 where p.id = a.user_id and p.site_employee and a.is_late;

-- ---------------------------------------------------------------------
-- 42b. MANY CHECK-INS A DAY, AT ANY PLACE (travel employees)
--      * A travel employee can check in and out as many times as needed in one day: office, a site, another site, the office
--        again ... Every stop has its own check-in and check-out. The next stop does NOT have to be a different site.
--      * The distance between two stops (check-out place -> next check-in place) is calculated for every move.
--      * A normal check-in / check-out made earlier the same day (before the employee used the stop-by-stop flow) is taken in as
--        stop 1, so the next check-in is no longer refused with "You have already checked out today".
-- ---------------------------------------------------------------------
-- (there is NO per-day limit on check-ins / visits; the system maximum is 30 stops a day)

create or replace function public.travel_check_in(
  p_lat double precision default null, p_lng double precision default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me    public.profiles := public._require_active();
  v_now timestamp := public.ist_now();
  a     public.attendance;
  n     int;
  lid   bigint;
  v_new bigint;
begin
  if not me.travel_access or me.site_employee then
    raise exception 'Travel attendance is not enabled for your account';
  end if;
  if p_lat is null or p_lng is null then
    raise exception 'Location is required. Turn on location and try again';
  end if;
  perform set_config('app.travel_rpc', 'on', true);

  insert into public.attendance (user_id, work_date, check_in_at, is_late, source, check_in_lat, check_in_lng)
  values (me.id, v_now::date, now(), date_trunc('minute', v_now)::time > me.shift_start, 'office', p_lat, p_lng)
  on conflict (user_id, work_date) do nothing
  returning id into v_new;
  select * into a from public.attendance where user_id = me.id and work_date = v_now::date for update;

  if a.travel_done then update public.attendance set travel_done = false where id = a.id; end if;   -- pressing Finish does not block the check-ins the Admin allows
  select count(*) into n from public.attendance_legs where attendance_id = a.id;
  -- an earlier plain check-in / check-out of today becomes stop 1
  if n = 0 and v_new is null and a.check_in_at is not null and a.check_in_lat is not null and a.check_in_lng is not null then
    insert into public.attendance_legs (attendance_id, user_id, work_date, leg, in_at, in_lat, in_lng, out_at, out_lat, out_lng, site_name)
    values (a.id, me.id, a.work_date, 1, a.check_in_at, a.check_in_lat, a.check_in_lng, a.check_out_at, a.check_out_lat, a.check_out_lng, a.site_name);
    n := 1;
  end if;
  if exists (select 1 from public.attendance_legs where attendance_id = a.id and out_at is null) then
    raise exception 'You are already checked in. Check out first';
  end if;
  insert into public.attendance_legs (attendance_id, user_id, work_date, leg, in_lat, in_lng)
  values (a.id, me.id, a.work_date, n + 1, p_lat, p_lng) returning id into lid;
  if n >= 1 then
    update public.attendance set check_out_at = null, check_out_lat = null, check_out_lng = null where id = a.id;
    perform public._record_trip(lid);
  end if;
  perform public._audit('TRAVEL_CHECK_IN', 'stop ' || (n + 1) || ' ' || to_char(v_now, 'HH24:MI'));
  return public._travel_today(me.id);
end $$;

create or replace function public.site_travel_check_in(
  p_lat double precision default null, p_lng double precision default null,
  p_site_id bigint default null, p_site_name text default null,
  p_note text default null, p_photo_path text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me        public.profiles := public._require_active();
  v_now     timestamp := public.ist_now();
  a         public.attendance;
  g         record;
  v_outside boolean;
  n         int;
  lid       bigint;
  v_new     bigint;
  v_off     boolean := public._is_office_site(p_site_id);
  v_od      integer;
begin
  if not (me.travel_access and me.site_employee) then
    raise exception 'Site travel attendance is not enabled for your account';
  end if;
  if p_lat is null or p_lng is null then
    raise exception 'Location is required. Turn on location and try again';
  end if;
  perform set_config('app.travel_rpc', 'on', true);

  if v_off then
    select o.site_name, o.distance_m into p_site_name, v_od from public._office_check(me.id, p_lat, p_lng) o;
    p_photo_path := null; v_outside := false;
  else
    select * into g from public._geofence_check(p_site_id, p_lat, p_lng);
    v_outside := not g.inside; v_od := g.distance_m;
    p_site_name := coalesce(g.site_name, p_site_name);
    if nullif(trim(p_site_name),'') is null then raise exception 'Select the work site before submitting'; end if;
    if v_outside then p_photo_path := null;
    elsif p_photo_path is null or split_part(p_photo_path, '/', 1) <> me.id::text then
      raise exception 'Take a selfie first';
    end if;
  end if;

  insert into public.attendance (user_id, work_date, check_in_at, is_late, source, site_name, note, check_in_lat, check_in_lng)
  values (me.id, v_now::date, now(), date_trunc('minute', v_now)::time > me.shift_start, 'site',
          trim(p_site_name), nullif(trim(p_note),''), p_lat, p_lng)
  on conflict (user_id, work_date) do nothing
  returning id into v_new;
  select * into a from public.attendance where user_id = me.id and work_date = v_now::date for update;

  if a.travel_done then update public.attendance set travel_done = false where id = a.id; end if;   -- pressing Finish does not block the check-ins the Admin allows
  select count(*) into n from public.attendance_legs where attendance_id = a.id;
  -- an earlier plain check-in / check-out of today becomes stop 1
  if n = 0 and v_new is null and a.check_in_at is not null and a.check_in_lat is not null and a.check_in_lng is not null then
    insert into public.attendance_legs (attendance_id, user_id, work_date, leg, in_at, in_lat, in_lng, out_at, out_lat, out_lng, site_name)
    values (a.id, me.id, a.work_date, 1, a.check_in_at, a.check_in_lat, a.check_in_lng, a.check_out_at, a.check_out_lat, a.check_out_lng, a.site_name);
    n := 1;
  end if;
  if exists (select 1 from public.attendance_legs where attendance_id = a.id and out_at is null) then
    raise exception 'You are already checked in. Check out first';
  end if;
  if n >= 1 then
    update public.attendance set check_out_at = null, check_out_lat = null, check_out_lng = null where id = a.id;
  end if;

  insert into public.attendance_legs (attendance_id, user_id, work_date, leg, in_lat, in_lng, site_id, site_name, in_dist_m)
  values (a.id, me.id, a.work_date, n + 1, p_lat, p_lng, p_site_id, trim(p_site_name), v_od) returning id into lid;
  if n >= 1 then perform public._record_trip(lid); end if;
  if not v_off then
    insert into public.selfie_records (user_id, attendance_id, kind, site_name, note, photo_path, lat, lng, outside, distance_m)
    values (me.id, a.id, 'IN', trim(p_site_name), nullif(trim(p_note),''), p_photo_path, p_lat, p_lng, v_outside, g.distance_m);
  end if;
  perform public._audit('SITE_TRAVEL_CHECK_IN', 'stop ' || (n + 1) || ' ' || trim(p_site_name));
  return public._travel_today(me.id);
end $$;

revoke execute on function public.travel_check_in(double precision, double precision) from public, anon;
revoke execute on function public.site_travel_check_in(double precision, double precision, bigint, text, text, text) from public, anon;
grant  execute on function public.travel_check_in(double precision, double precision) to authenticated;
grant  execute on function public.site_travel_check_in(double precision, double precision, bigint, text, text, text) to authenticated;
-- ---------------------------------------------------------------------

-- Today's travel status: max_legs is the system maximum (30 stops a day), not a per-employee setting
create or replace function public._travel_today(p_user uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'date',  public.ist_today(),
    'legs',  coalesce((select jsonb_agg(jsonb_build_object(
                'leg', l.leg, 'in_at', l.in_at, 'out_at', l.out_at, 'site_id', l.site_id, 'site_name', l.site_name,
                'in_lat', l.in_lat, 'in_lng', l.in_lng, 'out_lat', l.out_lat, 'out_lng', l.out_lng,
                'trip_km', l.trip_km, 'trip_source', l.trip_source,
                'in_dist_m', l.in_dist_m, 'out_dist_m', l.out_dist_m, 'is_office', public._is_office_site(l.site_id)) order by l.leg)
              from public.attendance_legs l where l.user_id = p_user and l.work_date = public.ist_today()), '[]'::jsonb),
    'km',    (select a.travel_km from public.attendance a where a.user_id = p_user and a.work_date = public.ist_today()),
    'open',  exists (select 1 from public.attendance_legs l where l.user_id = p_user and l.work_date = public.ist_today() and l.out_at is null),
    'done',  coalesce((select a.travel_done from public.attendance a where a.user_id = p_user and a.work_date = public.ist_today()), false),
    'max_legs', 30
  )
$$;
revoke execute on function public._travel_today(uuid) from public, anon, authenticated;
-- 42c. FIELD VISITS HAVE NO PER-DAY LIMIT
--      * The old "Visits / check-ins allowed per day" setting (1-6) is removed everywhere.
-- ---------------------------------------------------------------------
create or replace function public.start_visit(
  p_place text, p_purpose text,
  p_lat double precision default null, p_lng double precision default null,
  p_from_site bigint default null, p_to_site bigint default null
) returns public.visits
language plpgsql security definer set search_path = public as $$
declare
  me  public.profiles := public._require_visit_access();
  d   date := public.ist_today();
  att public.attendance;
  v   public.visits;
  fs  public.sites;
  ts  public.sites;
  km  numeric;
begin
  if p_from_site is not null or p_to_site is not null then
    if p_from_site is null or p_to_site is null then
      raise exception 'Choose both the site you start from and the site you are going to';
    end if;
    if p_from_site = p_to_site then raise exception 'The two sites must be different'; end if;
    select * into fs from public.sites where id = p_from_site and active;
    select * into ts from public.sites where id = p_to_site   and active;
    if fs.id is null or ts.id is null then raise exception 'Choose two active work sites'; end if;
    km := round((public._distance_m(fs.lat, fs.lng, ts.lat, ts.lng) / 1000)::numeric, 1);
    if nullif(trim(p_place),'') is null then p_place := ts.name; end if;
  end if;

  if nullif(trim(p_place),'') is null   then raise exception 'Enter the place / client you are visiting'; end if;
  if nullif(trim(p_purpose),'') is null then raise exception 'Enter the purpose of the visit'; end if;
  if p_lat is null or p_lng is null     then raise exception 'Location is required to start a visit'; end if;

  select * into att from public.attendance where user_id = me.id and work_date = d;
  if att.id is null or att.check_in_at is null then
    raise exception 'Check in at the office first, then start your visit';
  end if;
  if att.check_out_at is not null then
    raise exception 'You have already checked out today';
  end if;
  if exists (select 1 from public.visits where user_id = me.id and end_at is null) then
    raise exception 'You already have a visit in progress. End it first';
  end if;

  insert into public.visits (user_id, visit_date, place, purpose, start_lat, start_lng,
                             from_site_id, from_site_name, to_site_id, to_site_name, planned_km)
  values (me.id, d, trim(p_place), trim(p_purpose), p_lat, p_lng,
          fs.id, fs.name, ts.id, ts.name, km)
  returning * into v;
  perform public._audit('VISIT_START', me.username || ' at ' || v.place
    || case when fs.id is not null then ' (' || fs.name || ' > ' || ts.name || ', ' || km || ' km planned)' else '' end);
  return v;
end $$;

revoke execute on function public.start_visit(text, text, double precision, double precision, bigint, bigint) from public, anon;
grant  execute on function public.start_visit(text, text, double precision, double precision, bigint, bigint) to authenticated;
-- ---------------------------------------------------------------------
-- 43. SUPABASE SECURITY ADVISOR CLEAN-UP
--     * "Function Search Path Mutable": every function in schema public gets a fixed search_path.
--     * "Public / Signed-In Users Can Execute SECURITY DEFINER function":
--         - anon (not signed in) may run ONLY the 4 login functions the sign-in screen needs;
--         - internal helpers (names starting with "_") and trigger functions are not callable from the app at all.
--     The app's own RPC functions (check_in, apply_leave, ...) stay callable by signed-in users: they check the caller
--     inside, so the advisor keeps listing them as informational warnings. That is expected and safe.
--     Safe to run again.
-- ---------------------------------------------------------------------
do $$
declare r record;
begin
  -- 1. fixed search_path on every public function that has none (extension functions are skipped)
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.prokind = 'f'
       and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search_path=%')
       and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
  loop
    execute format('alter function %s set search_path = public', r.sig);
  end loop;

  -- 2. internal helpers and trigger functions cannot be called from the app
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.prokind = 'f'
       and (p.proname like E'\\_%' or p.prorettype = 'trigger'::regtype)
       and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
  loop
    execute format('revoke execute on function %s from public, anon, authenticated', r.sig);
  end loop;
end $$;

-- 3. not-signed-in visitors: only the login functions
revoke execute on all functions in schema public from public, anon;
grant execute on function public.login_email(text) to anon;
grant execute on function public.request_login(text) to anon;
grant execute on function public.register_with_mobile(text, text, text, text) to anon;
grant execute on function public.claim_account(text, text, text) to anon;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------
-- 44. REMOVE THE "SECURITY DEFINER FUNCTION CALLABLE BY USERS" WARNINGS
--     The real (SECURITY DEFINER) functions move to schema "private", which the API does not expose.
--     Each public function stays under the same name / arguments / result as a SECURITY INVOKER wrapper that calls it,
--     so the app works unchanged and the Security Advisor no longer lists them.
--     The 3 row-security helpers (is_staff_admin, is_active_user, is_full_admin) are moved without a wrapper.
--     Safe to run again (run it after section 43; the whole file is meant to be run top to bottom).
-- ---------------------------------------------------------------------
create schema if not exists private;
revoke all on schema private from public;
grant usage on schema private to authenticated, anon;

do $$
declare
  r record; v_args text; v_res text; v_ident text; v_names text; v_vol text; v_body text; v_call text;
begin
  for r in
    select p.oid, p.proname, p.pronargs, p.proargnames, p.provolatile
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.prokind = 'f' and p.prosecdef
       and p.proname not like E'\\_%' and p.prorettype <> 'trigger'::regtype
       and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
  loop
    begin
      v_args  := pg_get_function_arguments(r.oid);
      v_res   := pg_get_function_result(r.oid);
      v_ident := pg_get_function_identity_arguments(r.oid);
      v_vol   := case r.provolatile when 'i' then 'immutable' when 's' then 'stable' else 'volatile' end;
      if r.pronargs = 0 then
        v_names := '';
      else
        if exists (select 1 from unnest(r.proargnames[1:r.pronargs]) x where x is null) then
          raise notice 'skipped % (unnamed arguments)', r.proname; continue;
        end if;
        select string_agg(quote_ident(x), ', ' order by o) into v_names
          from unnest(r.proargnames[1:r.pronargs]) with ordinality t(x, o);
      end if;

      execute format('drop function if exists private.%I(%s)', r.proname, v_ident);   -- leftover from an earlier run
      execute format('alter function public.%I(%s) set schema private', r.proname, v_ident);
      execute format('revoke all on function private.%I(%s) from public, anon', r.proname, v_ident);
      execute format('grant execute on function private.%I(%s) to authenticated', r.proname, v_ident);

      if r.proname not in ('is_staff_admin', 'is_active_user', 'is_full_admin') then
        v_call := format('private.%I(%s)', r.proname, v_names);
        v_body := case when v_res = 'void' then 'select ' || v_call else 'select * from ' || v_call end;
        execute format('create function public.%I(%s) returns %s language sql %s security invoker set search_path = public as $w$ %s $w$',
                       r.proname, v_args, v_res, v_vol, v_body);
        execute format('revoke all on function public.%I(%s) from public, anon', r.proname, v_ident);
        execute format('grant execute on function public.%I(%s) to authenticated', r.proname, v_ident);
      end if;
    exception when others then
      raise notice 'kept % in public: %', r.proname, sqlerrm;
    end;
  end loop;
end $$;

-- the login screen (not signed in) still needs these four
grant execute on function public.login_email(text) to anon;
grant execute on function public.request_login(text) to anon;
grant execute on function public.register_with_mobile(text, text, text, text) to anon;
grant execute on function public.claim_account(text, text, text) to anon;
grant execute on function private.login_email(text) to anon;
grant execute on function private.request_login(text) to anon;
grant execute on function private.register_with_mobile(text, text, text, text) to anon;
grant execute on function private.claim_account(text, text, text) to anon;

notify pgrst, 'reload schema';
-- ---------------------------------------------------------------------
-- 45. EMPLOYEE DETAILS FORM (C. V. Patil & Associates "Employee Form") + KYC DOCUMENTS
--     * employee_details       : one row per person with every field of the paper form
--                                (personal, address, PAN / Aadhar, education, skills, family, vehicle, bank, joining date).
--     * employee_detail_files  : one file per kind - photo, PAN, Aadhar, graduation, CV, bank passbook (1st page).
--                                A new upload replaces the old one.
--     * The employee fills and edits his own form (no Documents access needed). Admin / HR can fill or edit it for
--       any Employee (only an Admin can do so for HR / Admin accounts) and can view / download every file.
--     * Files live in the private "employee_detail_docs" bucket: <employee-uuid>/<kind>-<timestamp>-<name>.
--     Safe to run again. Run it after section 44.
-- ---------------------------------------------------------------------
create table if not exists public.employee_details (
  user_id            uuid primary key references public.profiles(id) on delete cascade,
  surname            text,
  first_name         text,
  father_name        text,
  mother_name        text,
  date_of_birth      date,
  gender             text,
  marital_status     text,
  permanent_address  text,
  local_address      text,
  tel_no             text,
  cell_no            text,
  email              text,
  pan_no             text,
  aadhar_no          text,
  education          jsonb not null default '[]'::jsonb,   -- [{degree, specialization, year, marks}]
  software_skills    text,
  family             jsonb not null default '[]'::jsonb,   -- [{name, relation, contact}]
  vehicle_company    text,
  vehicle_no         text,
  license_no         text,
  bank_name          text,
  bank_address       text,
  bank_branch        text,
  bank_account_no    text,
  ifsc_code          text,
  joining_date       date,
  resign_date        date,
  uan_no             text,
  declared           boolean not null default false,
  updated_at         timestamptz not null default now(),
  updated_by         uuid references public.profiles(id) on delete set null
);
alter table public.employee_details add column if not exists resign_date date;
alter table public.employee_details add column if not exists uan_no text;
alter table public.employee_details enable row level security;
drop policy if exists employee_details_read on public.employee_details;
create policy employee_details_read on public.employee_details for select to authenticated
  using (user_id = auth.uid() or private.is_staff_admin());
revoke all on public.employee_details from anon;
grant select on public.employee_details to authenticated;

create table if not exists public.employee_detail_files (
  id           bigint generated always as identity primary key,
  user_id      uuid not null references public.profiles(id) on delete cascade,
  kind         text not null check (kind in ('photo', 'pan', 'aadhar', 'graduation', 'cv', 'bank')),
  file_path    text not null,
  file_name    text,
  uploaded_by  uuid references public.profiles(id) on delete set null,
  created_at   timestamptz not null default now(),
  unique (user_id, kind)
);
alter table public.employee_detail_files enable row level security;
drop policy if exists employee_detail_files_read on public.employee_detail_files;
create policy employee_detail_files_read on public.employee_detail_files for select to authenticated
  using (user_id = auth.uid() or private.is_staff_admin());
revoke all on public.employee_detail_files from anon;
grant select on public.employee_detail_files to authenticated;

do $$
begin
  if not exists (select 1 from pg_publication_tables
                  where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'employee_detail_files') then
    alter publication supabase_realtime add table public.employee_detail_files;
  end if;
end $$;

-- Who may change the form / files of p_user: himself, or Admin / HR (HR only for plain Employees)
create or replace function public._detail_actor(p_user uuid) returns public.profiles
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._require_active(); t public.profiles;
begin
  if p_user is null or p_user = me.id then return me; end if;
  me := public._require_admin();
  select * into t from public.profiles where id = p_user and active;
  if t.id is null then raise exception 'User not found'; end if;
  if me.role <> 'Admin' and t.role <> 'Employee' then raise exception 'Only an Admin can change HR / Admin accounts'; end if;
  return me;
end $$;

-- p_user null = your own form. p_data = the form fields (see the columns above).
create or replace function public.save_employee_details(p_user uuid, p_data jsonb)
returns public.employee_details
language plpgsql security definer set search_path = public as $$
declare
  me   public.profiles := public._detail_actor(p_user);
  v_for uuid := coalesce(p_user, me.id);
  d    jsonb := coalesce(p_data, '{}'::jsonb);
  r    public.employee_details;
  v_pan text := upper(nullif(trim(d->>'pan_no'), ''));
  v_aad text := regexp_replace(coalesce(d->>'aadhar_no', ''), '\s', '', 'g');
  v_ifsc text := upper(nullif(trim(d->>'ifsc_code'), ''));
  v_dob  date := nullif(trim(d->>'date_of_birth'), '')::date;
  v_join date := nullif(trim(d->>'joining_date'), '')::date;
  v_resign date := nullif(trim(d->>'resign_date'), '')::date;
  v_uan text := nullif(regexp_replace(coalesce(d->>'uan_no', ''), '\s', '', 'g'), '');
begin
  if nullif(trim(d->>'permanent_address'), '') is null then raise exception 'Enter the permanent address'; end if;
  if nullif(trim(d->>'local_address'), '') is null then raise exception 'Enter the local address'; end if;
  if nullif(trim(d->>'cell_no'), '') is null then raise exception 'Enter the cell number'; end if;
  if v_pan is not null and v_pan !~ '^[A-Z]{5}[0-9]{4}[A-Z]$' then raise exception 'PAN number looks wrong (example ABCDE1234F)'; end if;
  if v_aad <> '' and v_aad !~ '^[0-9]{12}$' then raise exception 'Aadhar number must be 12 digits'; end if;
  if v_ifsc is not null and v_ifsc !~ '^[A-Z]{4}0[A-Z0-9]{6}$' then raise exception 'IFSC code looks wrong (example SBIN0001234)'; end if;
  if nullif(trim(d->>'bank_name'), '') is null then raise exception 'Enter the bank name'; end if;
  if nullif(trim(d->>'bank_address'), '') is null then raise exception 'Enter the bank address'; end if;
  if nullif(trim(d->>'bank_branch'), '') is null then raise exception 'Enter the bank branch'; end if;
  if nullif(trim(d->>'bank_account_no'), '') is null then raise exception 'Enter the bank account number'; end if;
  if v_ifsc is null then raise exception 'Enter the IFSC code'; end if;
  if v_join is null then raise exception 'Enter the joining date'; end if;
  if v_resign is not null and v_resign < v_join then raise exception 'Resign date cannot be before the joining date'; end if;
  if v_uan is not null and v_uan !~ '^[0-9]{12}$' then raise exception 'UAN number must be 12 digits'; end if;
  if v_dob is not null and v_dob >= public.ist_today() then raise exception 'Date of birth must be in the past'; end if;

  insert into public.employee_details as e (
    user_id, surname, first_name, father_name, mother_name, date_of_birth, gender, marital_status,
    permanent_address, local_address, tel_no, cell_no, email, pan_no, aadhar_no,
    education, software_skills, family, vehicle_company, vehicle_no, license_no,
    bank_name, bank_address, bank_branch, bank_account_no, ifsc_code, joining_date, resign_date, uan_no, declared, updated_at, updated_by
  ) values (
    v_for, nullif(trim(d->>'surname'), ''), nullif(trim(d->>'first_name'), ''), nullif(trim(d->>'father_name'), ''),
    nullif(trim(d->>'mother_name'), ''), v_dob, nullif(trim(d->>'gender'), ''), nullif(trim(d->>'marital_status'), ''),
    trim(d->>'permanent_address'), trim(d->>'local_address'), nullif(trim(d->>'tel_no'), ''), trim(d->>'cell_no'),
    nullif(trim(d->>'email'), ''), v_pan, nullif(v_aad, ''),
    case when jsonb_typeof(d->'education') = 'array' then d->'education' else '[]'::jsonb end,
    nullif(trim(d->>'software_skills'), ''),
    case when jsonb_typeof(d->'family') = 'array' then d->'family' else '[]'::jsonb end,
    nullif(trim(d->>'vehicle_company'), ''), nullif(trim(d->>'vehicle_no'), ''), nullif(trim(d->>'license_no'), ''),
    trim(d->>'bank_name'), trim(d->>'bank_address'), trim(d->>'bank_branch'), trim(d->>'bank_account_no'), v_ifsc,
    v_join, v_resign, v_uan, coalesce((d->>'declared')::boolean, false), now(), me.id
  )
  on conflict (user_id) do update set
    surname = excluded.surname, first_name = excluded.first_name, father_name = excluded.father_name,
    mother_name = excluded.mother_name, date_of_birth = excluded.date_of_birth, gender = excluded.gender,
    marital_status = excluded.marital_status, permanent_address = excluded.permanent_address,
    local_address = excluded.local_address, tel_no = excluded.tel_no, cell_no = excluded.cell_no, email = excluded.email,
    pan_no = excluded.pan_no, aadhar_no = excluded.aadhar_no, education = excluded.education,
    software_skills = excluded.software_skills, family = excluded.family, vehicle_company = excluded.vehicle_company,
    vehicle_no = excluded.vehicle_no, license_no = excluded.license_no, bank_name = excluded.bank_name,
    bank_address = excluded.bank_address, bank_branch = excluded.bank_branch, bank_account_no = excluded.bank_account_no,
    ifsc_code = excluded.ifsc_code, joining_date = excluded.joining_date, resign_date = excluded.resign_date, uan_no = excluded.uan_no, declared = excluded.declared,
    updated_at = now(), updated_by = me.id
  returning * into r;
  -- the joining date of the form is the one payroll uses
  update public.profiles set joining_date = v_join where id = v_for and joining_date is distinct from v_join;
  perform public._audit('EMPLOYEE_DETAILS', 'saved for ' || (select username from public.profiles where id = v_for));
  return r;
end $$;

-- Attach (or replace) one document of the form. Returns the OLD file path (to delete from storage), or null.
create or replace function public.set_employee_detail_file(p_user uuid, p_kind text, p_path text, p_file_name text default null)
returns text
language plpgsql security definer set search_path = public as $$
declare
  me    public.profiles := public._detail_actor(p_user);
  v_for uuid := coalesce(p_user, me.id);
  v_old text;
begin
  if p_kind not in ('photo', 'pan', 'aadhar', 'graduation', 'cv', 'bank') then raise exception 'Unknown document'; end if;
  if p_path is null or split_part(p_path, '/', 1) <> v_for::text then raise exception 'Attach the document first'; end if;
  select file_path into v_old from public.employee_detail_files where user_id = v_for and kind = p_kind;
  insert into public.employee_detail_files (user_id, kind, file_path, file_name, uploaded_by)
  values (v_for, p_kind, p_path, nullif(trim(p_file_name), ''), me.id)
  on conflict (user_id, kind) do update
    set file_path = excluded.file_path, file_name = excluded.file_name, uploaded_by = excluded.uploaded_by, created_at = now();
  perform public._audit('EMPLOYEE_DETAIL_FILE', p_kind || ' for ' || (select username from public.profiles where id = v_for));
  return v_old;
end $$;

-- Remove one document of the form. Returns the file path to delete from storage.
create or replace function public.delete_employee_detail_file(p_user uuid, p_kind text) returns text
language plpgsql security definer set search_path = public as $$
declare
  me    public.profiles := public._detail_actor(p_user);
  v_for uuid := coalesce(p_user, me.id);
  v_path text;
begin
  delete from public.employee_detail_files where user_id = v_for and kind = p_kind returning file_path into v_path;
  if v_path is null then raise exception 'Document not found'; end if;
  perform public._audit('DELETE_EMPLOYEE_DETAIL_FILE', p_kind || ' for ' || (select username from public.profiles where id = v_for));
  return v_path;
end $$;

revoke execute on function public._detail_actor(uuid) from public, anon, authenticated;
revoke execute on function public.save_employee_details(uuid, jsonb) from public, anon;
revoke execute on function public.set_employee_detail_file(uuid, text, text, text) from public, anon;
revoke execute on function public.delete_employee_detail_file(uuid, text) from public, anon;
grant  execute on function public.save_employee_details(uuid, jsonb) to authenticated;
grant  execute on function public.set_employee_detail_file(uuid, text, text, text) to authenticated;
grant  execute on function public.delete_employee_detail_file(uuid, text) to authenticated;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('employee_detail_docs', 'employee_detail_docs', false, 10485760, array[
  'application/pdf', 'image/jpeg', 'image/png', 'image/webp',
  'application/msword', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document'])
on conflict (id) do update
  set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists employee_detail_docs_upload on storage.objects;
create policy employee_detail_docs_upload on storage.objects for insert to authenticated
  with check (
    bucket_id = 'employee_detail_docs'
    and (private.is_staff_admin()
         or ((storage.foldername(name))[1] = auth.uid()::text
             and exists (select 1 from public.profiles p where p.id = auth.uid() and p.active)))
  );
drop policy if exists employee_detail_docs_read on storage.objects;
create policy employee_detail_docs_read on storage.objects for select to authenticated
  using (bucket_id = 'employee_detail_docs' and ((storage.foldername(name))[1] = auth.uid()::text or private.is_staff_admin()));
drop policy if exists employee_detail_docs_delete on storage.objects;
create policy employee_detail_docs_delete on storage.objects for delete to authenticated
  using (bucket_id = 'employee_detail_docs' and ((storage.foldername(name))[1] = auth.uid()::text or private.is_staff_admin()));

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------
-- 46. SELF REGISTRATION (Employee / HR) WITH OTP AND ADMIN APPROVAL
--     1. The person opens the app and chooses Employee or HR, fills the registration form and verifies a one-time
--        password (OTP) sent to the mobile number (SMS) or the e-mail address (done by Supabase Auth).
--     2. After the OTP he chooses a username and a password. The request goes to Admin / HR (Approvals -> Registration).
--        Until it is approved the account is NOT active: he cannot sign in and every function refuses him.
--     3. Approve = the account is activated at once and he can sign in. Reject = he is told so when he tries to sign in.
--        HR registrations can be approved by an Admin only; Employee registrations by Admin or HR.
--
--     Needs in Supabase Dashboard -> Authentication:
--       * Providers -> Email: enabled, and the "Magic Link" / "Confirm signup" e-mail templates must show {{ .Token }}
--       * Providers -> Phone: enabled with an SMS provider (Twilio, MessageBird, Vonage ...) for the SMS OTP
--       * "Allow new users to sign up" ON (every new self-registered account starts inactive, see the trigger below)
--     Safe to run again.
-- ---------------------------------------------------------------------
alter table public.profiles add column if not exists approval_status text not null default 'Approved';
alter table public.profiles drop constraint if exists profiles_approval_status_check;
alter table public.profiles add constraint profiles_approval_status_check check (approval_status in ('Pending', 'Approved', 'Rejected'));
-- false = verified the OTP but has not sent the registration form yet (not shown to Admin / HR)
alter table public.profiles add column if not exists reg_submitted boolean not null default true;
alter table public.profiles add column if not exists email text;
alter table public.profiles add column if not exists registered_at timestamptz;

-- New login accounts: accounts made by Admin / HR (the Edge Function creates them with a confirmed e-mail) and the very
-- first account are active. Everything else (a person who verified an OTP in the app) starts inactive and pending.
-- The client cannot fake "confirmed": it is set by the server.
create or replace function public._handle_new_auth_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  meta jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
  v_username text := lower(coalesce(nullif(meta->>'username',''), split_part(coalesce(new.email, ''), '@', 1)));
  v_first boolean := not exists (select 1 from public.profiles);
  v_self boolean := not v_first and new.email_confirmed_at is null;
begin
  v_username := left(regexp_replace(v_username, '[^a-z0-9._-]', '', 'g'), 34);
  if length(v_username) < 2 then v_username := 'user' || substr(new.id::text, 1, 8); end if;
  if exists (select 1 from public.profiles where username = v_username) then
    v_username := v_username || '-' || substr(new.id::text, 1, 4);
  end if;

  insert into public.profiles (id, username, full_name, department, role, active, approval_status, reg_submitted, email, phone)
  values (new.id,
          v_username,
          coalesce(nullif(meta->>'full_name',''), v_username),
          nullif(meta->>'department',''),
          case when v_first then 'Admin' else 'Employee' end,   -- role is NEVER taken from metadata
          not v_self,
          case when v_self then 'Pending' else 'Approved' end,
          not v_self,
          case when v_self then nullif(new.email, '') end,
          case when v_self then nullif(new.phone, '') end)
  on conflict (id) do nothing;
  return new;
end $$;

-- Sign-in helper. Also answers for a person whose registration is waiting / rejected, so the app can tell him why he cannot
-- enter (the password is still checked by Supabase Auth first).
do $$
declare v_schema text := case when exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                                            where n.nspname = 'private' and p.proname = 'login_email') then 'private' else 'public' end;
begin
  execute format(
    'create or replace function %I.login_email(p_username text) returns text '
    'language sql stable security definer set search_path = public as '
    '''select u.email from public.profiles p join auth.users u on u.id = p.id '
    'where p.username = lower(trim(p_username)) '
    'and (p.active or (p.reg_submitted and p.approval_status in (''''Pending'''', ''''Rejected'''')))''',
    v_schema);
end $$;

-- After the OTP: the signed-in (still inactive) person sends the registration form
create or replace function public.submit_registration(
  p_full_name text, p_username text, p_role text, p_mobile text default null, p_email text default null, p_department text default null
) returns text
language plpgsql security definer set search_path = public as $$
declare
  me public.profiles;
  v_u text := lower(trim(coalesce(p_username, '')));
  v_name text := trim(coalesce(p_full_name, ''));
  v_mobile text := public._phone_key(p_mobile);
  v_email text := nullif(lower(trim(coalesce(p_email, ''))), '');
begin
  select * into me from public.profiles where id = auth.uid();
  if me.id is null then raise exception 'Verify the OTP first' using errcode = '28000'; end if;
  if me.approval_status = 'Approved' then raise exception 'This account is already registered. Sign in instead'; end if;
  if me.approval_status = 'Pending' and me.reg_submitted then raise exception 'Your registration is already waiting for Admin approval'; end if;
  if p_role not in ('Employee', 'HR') then raise exception 'Choose Employee or HR'; end if;
  if v_name = '' then raise exception 'Enter your full name'; end if;
  if v_u !~ '^[a-z0-9._-]{2,40}$' then
    raise exception 'Username may contain letters, numbers, dot, dash and underscore (2-40 characters)';
  end if;
  if exists (select 1 from public.profiles where username = v_u and id <> me.id) then
    raise exception 'This username is already taken. Choose another one';
  end if;
  if v_mobile <> '' and length(v_mobile) < 10 then raise exception 'Enter a 10-digit mobile number'; end if;
  if v_email is not null and v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Enter a valid e-mail address'; end if;

  update public.profiles
     set username = v_u, full_name = v_name, role = p_role, department = nullif(trim(coalesce(p_department, '')), ''),
         phone = coalesce(nullif(v_mobile, ''), phone), email = coalesce(v_email, email),
         active = false, approval_status = 'Pending', reg_submitted = true, registered_at = now()
   where id = me.id;

  -- sign-in is by username: a mobile-only account needs an e-mail for Supabase Auth, so it gets an internal one
  update auth.users
     set email = v_u || '@cvp-attendance.app', email_confirmed_at = coalesce(email_confirmed_at, now()), updated_at = now()
   where id = me.id and coalesce(email, '') = '';

  insert into public.audit_log (actor_id, action, detail) values (me.id, 'REGISTRATION_REQUEST', v_u || ' (' || p_role || ')');
  return 'Your registration was sent to the Admin. You can sign in after it is approved.';
end $$;

-- Admin / HR: approve (the account becomes active at once) or reject a registration
create or replace function public.review_registration(p_user uuid, p_approve boolean) returns void
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._require_admin(); t public.profiles;
begin
  select * into t from public.profiles where id = p_user for update;
  if t.id is null or not t.reg_submitted or t.approval_status <> 'Pending' then raise exception 'This registration is not waiting for approval'; end if;
  if t.role <> 'Employee' and me.role <> 'Admin' then raise exception 'Only an Admin can approve an HR registration'; end if;
  if p_approve then
    update public.profiles set active = true, approval_status = 'Approved', login_claimed = true where id = p_user;
    perform public._audit('APPROVE_REGISTRATION', t.username || ' (' || t.role || ')');
  else
    update public.profiles set active = false, approval_status = 'Rejected' where id = p_user;
    perform public._audit('REJECT_REGISTRATION', t.username || ' (' || t.role || ')');
  end if;
end $$;

revoke execute on function public.submit_registration(text, text, text, text, text, text) from public, anon;
revoke execute on function public.review_registration(uuid, boolean) from public, anon;
grant  execute on function public.submit_registration(text, text, text, text, text, text) to authenticated;
grant  execute on function public.review_registration(uuid, boolean) to authenticated;
grant  execute on function public.login_email(text) to anon, authenticated;

notify pgrst, 'reload schema';

-- =====================================================================
-- =====================================================================
--  UPDATES ADDED AFTER SECTION 46  (parts A to F, then H)
--   A  HR same access as Admin            B  Working hours and overtime       C  Document submission and review
--   D  Salary Management (Admin / HR)     E  Employee registration + login approval
--   F  Payroll months (Draft / Finalized)  I  Field Site Journeys  J  Leave eligibility (6 months)
--   H  Function permissions (always last)
--  update_approval_status.sql is not repeated: section 46 above already contains it.
--  Every part is safe to run again. On a database that is already set up you do NOT need to run this whole file again:
--  run only the part you are missing (copy from its "PART" line to the next "PART" line).
-- =====================================================================
-- =====================================================================

-- #####################################################################
-- PART A - HR HAS THE SAME ACCESS AS ADMIN
-- (from hr_same_as_admin.sql)
-- #####################################################################
-- ---------------------------------------------------------------------
-- HR HAS THE SAME ACCESS AS ADMIN
-- Work sites, salary / payroll, audit trail, app updates, roles, HR / Admin accounts, HR registrations.
-- Run in Supabase Dashboard -> SQL Editor -> New query -> Run.  Safe to run again.
-- Run AFTER update_approval_status.sql.
-- ---------------------------------------------------------------------

-- 1. "Full admin" now means Admin or HR (used by salary, audit log, sites, app updates ... and their security policies)
create or replace function public.is_full_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and active and role in ('Admin', 'HR'))
$$;
-- after the security clean-up the row-security helper lives in schema "private": keep that copy in step too
do $$
begin
  if to_regprocedure('private.is_full_admin()') is not null then
    execute $f$
      create or replace function private.is_full_admin() returns boolean
      language sql stable security definer set search_path = public as $b$
        select exists (select 1 from public.profiles where id = auth.uid() and active and role in ('Admin', 'HR'))
      $b$ $f$;
  end if;
end $$;

create or replace function public._require_full_admin() returns public.profiles
language plpgsql stable security definer set search_path = public as $$
declare p public.profiles;
begin
  p := public._require_active();
  if p.role not in ('Admin', 'HR') then
    raise exception 'Only an Admin / HR can do this' using errcode = '42501';
  end if;
  return p;
end $$;

-- 2. Every other function that checks  me.role <> 'Admin'  (change roles, HR / Admin accounts, bulk settings,
--    HR registrations ...) is rewritten so that HR passes those checks too.
do $$
declare r record; d text;
begin
  for r in
    select p.oid
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname in ('public', 'private') and p.prokind = 'f'     -- "private" too: the real functions live there after section 44
       and (pg_get_functiondef(p.oid) like '%me.role <> ''Admin''%' or pg_get_functiondef(p.oid) like '%me.role = ''Admin''%')
  loop
    d := pg_get_functiondef(r.oid);
    d := replace(d, 'me.role <> ''Admin''', 'me.role not in (''Admin'', ''HR'')');
    d := replace(d, 'me.role = ''Admin''',  'me.role in (''Admin'', ''HR'')');
    execute d;
  end loop;
end $$;

notify pgrst, 'reload schema';

-- #####################################################################
-- PART B - WORKING HOURS: NO FIXED TIMES, UNPAID BREAK, 8-HOUR DAY, OVERTIME, WORKING HOURS AND OVERTIME REPORT
-- (from working_hours.sql)
-- #####################################################################
-- ---------------------------------------------------------------------
-- CHECK-IN / CHECK-OUT AND WORKING HOURS
--   * No fixed check-in / check-out times: nobody is marked "late" for arriving after a shift start any more.
--     Employees check in and out when they really start and finish at their assigned site.
--   * Working hours = check-out minus check-in, MINUS the unpaid break (a company setting, see below).
--   * 8 hours is the standard working day; everything beyond it is overtime. Time worked on a weekly off / holiday is all overtime.
--   * Admin / HR report: admin_working_hours_report (employee, site, date, check-in, check-out, total, regular, overtime hours).
-- Run in Supabase Dashboard -> SQL Editor -> New query -> Run.  Safe to run again.
--
-- To change the rules later, edit the one settings row, for example:
--   update public.payroll_settings set standard_minutes = 480, unpaid_break_minutes = 30, break_after_minutes = 300 where id = 1;
--   (unpaid_break_minutes = 0 means no break is deducted)
-- ---------------------------------------------------------------------
alter table public.payroll_settings add column if not exists standard_minutes     integer not null default 480 check (standard_minutes > 0);
alter table public.payroll_settings add column if not exists unpaid_break_minutes integer not null default 60  check (unpaid_break_minutes >= 0);
-- the unpaid break is deducted only on a day when the person worked MORE than this many minutes (default 5 hours)
alter table public.payroll_settings add column if not exists break_after_minutes  integer not null default 300 check (break_after_minutes >= 0);

-- worked minutes after the unpaid break
create or replace function public._work_net_minutes(p_gross integer) returns integer
language sql stable security definer set search_path = public as $$
  select case
           when p_gross is null then null
           when p_gross > s.break_after_minutes then greatest(p_gross - s.unpaid_break_minutes, 0)
           else p_gross end
  from public.payroll_settings s where s.id = 1
$$;

-- No fixed times: a check-in is never "late"
create or replace function public._no_fixed_times() returns trigger
language plpgsql as $$ begin new.is_late := false; return new; end $$;
drop trigger if exists attendance_no_late on public.attendance;
create trigger attendance_no_late before insert or update on public.attendance
  for each row execute function public._no_fixed_times();

-- Overtime per day (used by the Salary Report and every overtime figure): minutes beyond the standard day,
-- all minutes on a weekly off / holiday. Working minutes are counted after the unpaid break.
create or replace function public._month_overtime(p_user uuid, p_year int, p_month int)
returns table (day date, work_minutes int, shift_minutes int, ot_minutes int)
language sql stable security definer set search_path = public as $$
  select a.work_date,
         public._work_net_minutes(a.work_minutes),
         s.standard_minutes,
         case when not public._is_workday(a.user_id, a.work_date) then public._work_net_minutes(a.work_minutes)
              else greatest(public._work_net_minutes(a.work_minutes) - s.standard_minutes, 0) end
  from public.attendance a
  cross join public.payroll_settings s
  where s.id = 1 and a.user_id = p_user and a.work_minutes is not null
    and a.work_date between make_date(p_year, p_month, 1)
                        and (make_date(p_year, p_month, 1) + interval '1 month - 1 day')::date
$$;

-- Working Hours and Overtime Report: one row per employee per day
drop function if exists public.admin_working_hours_report(date, date, uuid);
create or replace function public.admin_working_hours_report(p_from date, p_to date, p_user uuid default null)
returns table (
  user_id uuid, username text, full_name text, department text, site_name text, work_date date,
  check_in text, check_out text,
  gross_minutes int, break_minutes int, total_minutes int, regular_minutes int, overtime_minutes int
)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare std int;
begin
  perform public._require_admin();
  select standard_minutes into std from public.payroll_settings where id = 1;
  return query
  select p.id, p.username, p.full_name, p.department,
         coalesce(nullif(trim(a.site_name), ''),
                  (select string_agg(distinct l.site_name, ', ') from public.attendance_legs l where l.attendance_id = a.id and l.site_name is not null),
                  'Office'),
         a.work_date,
         to_char(a.check_in_at  at time zone 'Asia/Kolkata', 'HH24:MI'),
         to_char(a.check_out_at at time zone 'Asia/Kolkata', 'HH24:MI'),
         a.work_minutes,
         a.work_minutes - public._work_net_minutes(a.work_minutes),
         public._work_net_minutes(a.work_minutes),
         case when public._work_net_minutes(a.work_minutes) is null then null
              when not public._is_workday(a.user_id, a.work_date) then 0
              else least(public._work_net_minutes(a.work_minutes), std) end,
         case when public._work_net_minutes(a.work_minutes) is null then null
              when not public._is_workday(a.user_id, a.work_date) then public._work_net_minutes(a.work_minutes)
              else greatest(public._work_net_minutes(a.work_minutes) - std, 0) end
  from public.attendance a
  join public.profiles p on p.id = a.user_id
  where a.work_date between p_from and p_to and a.check_in_at is not null
    and (p_user is null or a.user_id = p_user)
  order by p.full_name, a.work_date;
end $$;

revoke execute on function public._work_net_minutes(integer) from public, anon, authenticated;
revoke execute on function public._no_fixed_times() from public, anon, authenticated;
revoke execute on function public.admin_working_hours_report(date, date, uuid) from public, anon;
grant  execute on function public.admin_working_hours_report(date, date, uuid) to authenticated;

notify pgrst, 'reload schema';

-- #####################################################################
-- PART C - DOCUMENT SUBMISSION AND REVIEW
-- (from document_review.sql)
-- #####################################################################
-- ---------------------------------------------------------------------
-- DOCUMENT SUBMISSION AND MANAGEMENT: category + review workflow for submitted documents
--   * An employee (with Documents access) submits a document with a category and a remark -> status "Submitted".
--   * Admin / HR open it, set the status (Under Review / Approved / Rejected) and write a note. The employee sees both.
--   * Everything that already exists (upload, view, download, delete, Documents Report, private storage) is kept.
-- Run in Supabase Dashboard -> SQL Editor -> New query -> Run.  Safe to run again.
-- ---------------------------------------------------------------------
alter table public.employee_documents add column if not exists category    text;
alter table public.employee_documents add column if not exists status      text not null default 'Submitted';
alter table public.employee_documents add column if not exists review_note text;
alter table public.employee_documents add column if not exists reviewed_by uuid references public.profiles(id) on delete set null;
alter table public.employee_documents add column if not exists reviewed_at timestamptz;

alter table public.employee_documents drop constraint if exists employee_documents_status_check;
alter table public.employee_documents add constraint employee_documents_status_check
  check (status in ('Submitted', 'Under Review', 'Approved', 'Rejected', 'Sent'));

-- documents that Admin / HR sent to an employee are not reviewed: they are "Sent"
update public.employee_documents set status = 'Sent' where direction = 'from_admin' and status = 'Submitted';

create index if not exists employee_documents_status_idx on public.employee_documents (status);

-- Upload (replaces the old 5-argument version: a new optional category is added)
drop function if exists public.add_employee_document(uuid, text, text, text, text);
create or replace function public.add_employee_document(
  p_user uuid, p_title text, p_remark text, p_path text, p_file_name text default null, p_category text default null
) returns public.employee_documents
language plpgsql security definer set search_path = public as $$
declare
  me     public.profiles := public._require_active();
  v_for  uuid := coalesce(p_user, me.id);
  v_dir  text;
  t      public.profiles;
  r      public.employee_documents;
begin
  if v_for = me.id then
    if not me.documents_access then raise exception 'Documents are not enabled for your account. Ask your Admin'; end if;
    v_dir := 'from_employee';
  else
    me := public._require_admin();
    select * into t from public.profiles where id = v_for and active;
    if t.id is null then raise exception 'User not found'; end if;
    if me.role not in ('Admin', 'HR') and t.role <> 'Employee' then raise exception 'Only an Admin can change HR / Admin accounts'; end if;
    v_dir := 'from_admin';
  end if;
  if nullif(trim(p_title),'') is null then raise exception 'Enter the document name'; end if;
  if p_path is null or split_part(p_path, '/', 1) <> v_for::text then raise exception 'Attach the document first'; end if;
  insert into public.employee_documents (user_id, direction, title, remark, file_path, file_name, uploaded_by, category, status)
  values (v_for, v_dir, trim(p_title), nullif(trim(p_remark),''), p_path, nullif(trim(p_file_name),''), me.id,
          nullif(trim(p_category),''), case when v_dir = 'from_admin' then 'Sent' else 'Submitted' end)
  returning * into r;
  perform public._audit('EMPLOYEE_DOCUMENT', v_dir || ' ' || r.title);
  return r;
end $$;

-- Admin / HR: review a document an employee submitted
create or replace function public.review_employee_document(p_id bigint, p_status text, p_note text default null)
returns public.employee_documents
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._require_admin(); r public.employee_documents;
begin
  if p_status not in ('Under Review', 'Approved', 'Rejected') then raise exception 'Choose Under Review, Approved or Rejected'; end if;
  update public.employee_documents
     set status = p_status, review_note = nullif(trim(p_note),''), reviewed_by = me.id, reviewed_at = now()
   where id = p_id and direction = 'from_employee'
  returning * into r;
  if r.id is null then raise exception 'Document not found (only documents submitted by employees can be reviewed)'; end if;
  perform public._audit('REVIEW_DOCUMENT', r.title || ' -> ' || p_status);
  return r;
end $$;

revoke execute on function public.add_employee_document(uuid, text, text, text, text, text) from public, anon;
revoke execute on function public.review_employee_document(bigint, text, text) from public, anon;
grant  execute on function public.add_employee_document(uuid, text, text, text, text, text) to authenticated;
grant  execute on function public.review_employee_document(bigint, text, text) to authenticated;

notify pgrst, 'reload schema';

-- #####################################################################
-- PART D - SALARY MANAGEMENT: BASIC SALARY, INCREMENTS WITH EFFECTIVE DATES, RESIGNED EMPLOYEES
-- (from salary_management.sql)
-- #####################################################################
-- =====================================================================
-- SALARY MANAGEMENT
--   * Salary history: first the Basic salary, then every increment with its effective date. Nothing is ever edited or deleted.
--   * Only the Admin can set a salary or add an increment (HR can view). Employees can see their own salary.
--   * Payroll uses the salary that applies on each day of the month (an increment is pro-rated from its effective date).
--   * Employees who leave stay in the Salary Management section and in every report:
--       - up to the month of leaving the salary is paid up to the leaving date,
--       - from the next month every salary column shows "-" and the row says "Resigned".
-- Run this file once in the Supabase SQL Editor.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Leaving date
--    Employee Form "Resign date" is used first; otherwise the day the account was deleted (deactivated).
-- ---------------------------------------------------------------------
alter table public.profiles add column if not exists left_on date;

-- accounts that were already deleted before this update
update public.profiles p
   set left_on = coalesce((select d.resign_date from public.employee_details d where d.user_id = p.id), p.updated_at::date)
 where not p.active and p.left_on is null;

create or replace function public._track_left_on() returns trigger
language plpgsql as $$
begin
  if new.active then
    new.left_on := null;
  elsif tg_op = 'UPDATE' and old.active then
    new.left_on := coalesce((select d.resign_date from public.employee_details d where d.user_id = new.id),
                            (now() at time zone 'Asia/Kolkata')::date);
  end if;
  return new;
end $$;

drop trigger if exists profiles_track_left_on on public.profiles;
create trigger profiles_track_left_on before update on public.profiles
  for each row execute function public._track_left_on();

-- ---------------------------------------------------------------------
-- 2. Salary history
-- ---------------------------------------------------------------------
create table if not exists public.salary_history (
  id              bigint generated always as identity primary key,
  user_id         uuid not null references public.profiles(id) on delete cascade,
  kind            text not null check (kind in ('Basic', 'Increment')),
  salary          numeric(12,2) not null check (salary >= 0),   -- monthly salary from the effective date
  increment       numeric(12,2) not null default 0,             -- raise over the salary before it
  effective_date  date not null,
  note            text,
  created_by      uuid references public.profiles(id),
  created_at      timestamptz not null default now(),
  unique (user_id, effective_date)
);
create index if not exists salary_history_user_idx on public.salary_history (user_id, effective_date);

-- keep the salaries that were already saved: they become the Basic salary
insert into public.salary_history (user_id, kind, salary, increment, effective_date, note)
select es.user_id, 'Basic', es.monthly_salary, 0, date '2000-01-01', 'Existing salary'
  from public.employee_salary es
 where es.monthly_salary > 0
   and not exists (select 1 from public.salary_history h where h.user_id = es.user_id);

alter table public.salary_history enable row level security;
drop policy if exists salary_history_read on public.salary_history;
create policy salary_history_read on public.salary_history for select to authenticated
  using (public.is_full_admin() or user_id = auth.uid());
-- nobody writes to the table directly: only admin_increment_salary() below
revoke all on public.salary_history from anon, authenticated;
grant select on public.salary_history to authenticated;

-- the old "set salary" function would bypass the history: switch it off
revoke execute on function public.admin_set_salary(uuid, numeric) from public, anon, authenticated;

-- Salary that applies on one day (0 before the first entry)
create or replace function public._salary_on(p_user uuid, p_day date) returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce((select h.salary from public.salary_history h
                    where h.user_id = p_user and h.effective_date <= p_day
                    order by h.effective_date desc limit 1), 0)
$$;
revoke execute on function public._salary_on(uuid, date) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 3. Admin only: set the Basic salary (first time) or add an increment with an effective date
-- ---------------------------------------------------------------------
create or replace function public.admin_increment_salary(
  p_user uuid, p_salary numeric, p_effective date default null, p_note text default null
) returns public.salary_history
language plpgsql security definer set search_path = public as $$
declare
  me public.profiles := public._require_active();
  target public.profiles;
  last_h public.salary_history;
  res public.salary_history;
  v_eff date;
begin
  if me.role not in ('Admin', 'HR') then raise exception 'Only the Admin / HR can change salaries' using errcode = '42501'; end if;
  if p_salary is null or p_salary < 0 then raise exception 'Enter a valid salary'; end if;
  select * into target from public.profiles where id = p_user;
  if target.id is null then raise exception 'Employee not found'; end if;

  select * into last_h from public.salary_history where user_id = p_user order by effective_date desc limit 1;
  if last_h.id is null then
    insert into public.salary_history (user_id, kind, salary, increment, effective_date, note, created_by)
    values (p_user, 'Basic', round(p_salary, 2), 0, date '2000-01-01', nullif(trim(p_note), ''), me.id)
    returning * into res;
    perform public._audit('SET_SALARY', target.username || ' basic = ' || round(p_salary, 2));
  else
    v_eff := coalesce(p_effective, public.ist_today());
    if v_eff <= last_h.effective_date and last_h.kind <> 'Basic' then
      raise exception 'The effective date must be after the last salary change (%)', to_char(last_h.effective_date, 'DD-MM-YYYY');
    end if;
    if v_eff <= last_h.effective_date then v_eff := last_h.effective_date + 1; end if;
    if round(p_salary, 2) = last_h.salary then raise exception 'The new salary is the same as the current salary'; end if;
    insert into public.salary_history (user_id, kind, salary, increment, effective_date, note, created_by)
    values (p_user, 'Increment', round(p_salary, 2), round(p_salary, 2) - last_h.salary, v_eff, nullif(trim(p_note), ''), me.id)
    returning * into res;
    perform public._audit('SALARY_INCREMENT', target.username || ': ' || last_h.salary || ' -> ' || round(p_salary, 2) || ' from ' || v_eff);
  end if;
  return res;
end $$;
revoke execute on function public.admin_increment_salary(uuid, numeric, date, text) from public, anon;
grant  execute on function public.admin_increment_salary(uuid, numeric, date, text) to authenticated;

-- ---------------------------------------------------------------------
-- 4. Salary Management table (Admin / HR can view)
-- ---------------------------------------------------------------------
drop function if exists public.admin_salary_overview();
create or replace function public.admin_salary_overview()
returns table (
  user_id uuid, username text, full_name text, department text, active boolean, joining_date date, left_on date,
  basic numeric, inc1 numeric, inc1_on date, inc2 numeric, inc2_on date, increments int,
  current_salary numeric, current_from date
)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  perform public._require_full_admin();
  return query
  select p.id, p.username, p.full_name, p.department, p.active, p.joining_date, l.left_d,
         (select h.salary from public.salary_history h where h.user_id = p.id order by h.effective_date limit 1),
         (select i.increment from public.salary_history i where i.user_id = p.id and i.kind = 'Increment' order by i.effective_date limit 1),
         (select i.effective_date from public.salary_history i where i.user_id = p.id and i.kind = 'Increment' order by i.effective_date limit 1),
         (select i.increment from public.salary_history i where i.user_id = p.id and i.kind = 'Increment' order by i.effective_date offset 1 limit 1),
         (select i.effective_date from public.salary_history i where i.user_id = p.id and i.kind = 'Increment' order by i.effective_date offset 1 limit 1),
         (select count(*)::int from public.salary_history i where i.user_id = p.id and i.kind = 'Increment'),
         -- after the month of leaving there is no current salary any more
         case when l.left_d is not null and date_trunc('month', l.left_d::timestamp) < date_trunc('month', public.ist_today()::timestamp)
              then null else public._salary_on(p.id, public.ist_today()) end,
         (select h.effective_date from public.salary_history h where h.user_id = p.id and h.effective_date <= public.ist_today() order by h.effective_date desc limit 1)
    from public.profiles p
    left join public.employee_details d on d.user_id = p.id
    cross join lateral (select coalesce(d.resign_date, p.left_on) as left_d) l
   where p.active or l.left_d is not null
   order by p.full_name;
end $$;
revoke execute on function public.admin_salary_overview() from public, anon;
grant  execute on function public.admin_salary_overview() to authenticated;

-- Complete history of one employee
drop function if exists public.admin_salary_history(uuid);
create or replace function public.admin_salary_history(p_user uuid)
returns table (id bigint, kind text, salary numeric, increment numeric, effective_date date, note text, created_at timestamptz, set_by text)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  perform public._require_full_admin();
  return query
  select h.id, h.kind, h.salary, h.increment, h.effective_date, h.note, h.created_at, c.full_name
    from public.salary_history h left join public.profiles c on c.id = h.created_by
   where h.user_id = p_user
   order by h.effective_date desc;
end $$;
revoke execute on function public.admin_salary_history(uuid) from public, anon;
grant  execute on function public.admin_salary_history(uuid) to authenticated;

-- Employee: own salary history (only the changes that have already started)
drop function if exists public.my_salary();
create or replace function public.my_salary()
returns table (kind text, salary numeric, increment numeric, effective_date date)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  perform public._require_active();
  return query
  select h.kind, h.salary, h.increment, h.effective_date
    from public.salary_history h
   where h.user_id = auth.uid() and h.effective_date <= public.ist_today()
   order by h.effective_date desc;
end $$;
revoke execute on function public.my_salary() from public, anon;
grant  execute on function public.my_salary() to authenticated;

-- ---------------------------------------------------------------------
-- 5. Month summary of every report: people who have left stay in the list
--    (absent days are counted only up to the leaving date)
-- ---------------------------------------------------------------------
drop function if exists public.admin_month_summary(int, int);
create or replace function public.admin_month_summary(p_year int, p_month int)
returns table (
  user_id uuid, username text, full_name text, department text,
  present int, absent int, on_leave int, late int, holidays int, hours numeric, left_on date
)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  perform public._require_admin();
  return query
  select p.id, p.username, p.full_name, p.department,
         count(*) filter (where m.status in ('Present','Checked In'))::int,
         count(*) filter (where m.status = 'Absent' and (l.left_d is null or m.day <= l.left_d))::int,
         count(*) filter (where m.status = 'Leave')::int,
         count(*) filter (where m.is_late and m.status in ('Present','Checked In'))::int,
         count(*) filter (where m.status = 'Holiday')::int,
         coalesce(sum(m.hours), 0),
         l.left_d
  from public.profiles p
  left join public.employee_details d on d.user_id = p.id
  cross join lateral (select coalesce(d.resign_date, p.left_on) as left_d) l
  cross join lateral public._month_attendance(p.id, p_year, p_month) m
  where p.active or l.left_d is not null
  group by p.id, p.username, p.full_name, p.department, l.left_d
  order by p.full_name;
end $$;
revoke execute on function public.admin_month_summary(int, int) from public, anon;
grant  execute on function public.admin_month_summary(int, int) to authenticated;

-- ---------------------------------------------------------------------
-- 6. Salary sheet: uses the salary history, and keeps people who have left
--    * salary of a month = the salary of each day of the month averaged (an increment is paid from its effective date)
--    * month of leaving: the days after the leaving date are unpaid
--    * months after leaving: every figure is 0 (shown as "-")
-- ---------------------------------------------------------------------
drop function if exists public.admin_payroll(int, int);
create or replace function public.admin_payroll(p_year int, p_month int)
returns table (
  user_id uuid, username text, full_name text, department text,
  monthly_salary numeric, days_in_month int, present int, absent int,
  leave_days int, paid_leave int, unpaid_leave int, not_joined int, unpaid_days int, payable_days int,
  overtime_hours numeric, overtime_pay numeric, deduction numeric, net_salary numeric, left_on date
)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare
  st      public.payroll_settings;
  m0      date := make_date(p_year, p_month, 1);
  m1      date := (make_date(p_year, p_month, 1) + interval '1 month - 1 day')::date;
  v_dim   int  := extract(day from (make_date(p_year, p_month, 1) + interval '1 month - 1 day'))::int;
  rec     record;
  v_left  date;
  v_sal   numeric; v_pres int; v_abs int; v_l int; v_lop int; v_paid int; v_unpaid int; v_nj int; v_after int;
  v_unpd  int; v_work int; v_ot int; v_hr numeric; v_otpay numeric; v_ded numeric; v_shift_h numeric;
begin
  perform public._require_full_admin();
  select * into st from public.payroll_settings where id = 1;
  for rec in
    select p.*, coalesce(d.resign_date, p.left_on) as left_d
      from public.profiles p left join public.employee_details d on d.user_id = p.id
     where p.active or coalesce(d.resign_date, p.left_on) is not null
     order by p.full_name
  loop
    v_left := rec.left_d;

    -- months after the month of leaving: nothing is paid
    if v_left is not null and date_trunc('month', v_left::timestamp) < date_trunc('month', m0::timestamp) then
      return query select rec.id, rec.username, rec.full_name, rec.department, 0::numeric, v_dim, 0, 0,
                          0, 0, 0, 0, v_dim, 0, 0::numeric, 0::numeric, 0::numeric, 0::numeric, v_left;
      continue;
    end if;

    select coalesce(avg(public._salary_on(rec.id, g::date)), 0) into v_sal
      from generate_series(m0::timestamp, m1::timestamp, interval '1 day') g;
    v_sal := round(v_sal, 2);

    select count(*) filter (where m.status in ('Present','Checked In')),
           count(*) filter (where m.status = 'Absent' and m.day < public.ist_today()
                                      and m.day >= coalesce(rec.joining_date, date '1900-01-01')
                                      and (v_left is null or m.day <= v_left))
      into v_pres, v_abs
      from public._month_attendance(rec.id, p_year, p_month) m;

    select coalesce(sum(u.days) filter (where lt.counts_balance), 0),
           coalesce(sum(u.days) filter (where not lt.counts_balance), 0)
      into v_l, v_lop
      from public._leave_usage(rec.id, m0, m1, array['Approved']) u
      join public.leave_types lt on lt.name = u.leave_type;

    v_paid   := least(v_l, st.paid_leaves_per_month);
    v_unpaid := v_l - v_paid + v_lop;
    v_nj     := case when rec.joining_date is null or rec.joining_date <= m0 then 0
                     else (least(rec.joining_date, m1 + 1) - m0) end;
    v_after  := case when v_left is not null and v_left < m1 then (m1 - v_left) else 0 end;   -- days after leaving
    v_unpd   := least(v_dim, v_abs + v_unpaid + v_nj + v_after);

    select count(*) into v_work
      from generate_series(m0::timestamp, m1::timestamp, interval '1 day') g
     where public._is_workday(rec.id, g::date);
    v_shift_h := extract(epoch from (rec.shift_end - rec.shift_start)) / 3600;
    select coalesce(sum(o.ot_minutes), 0) into v_ot from public._month_overtime(rec.id, p_year, p_month) o;

    v_hr    := case when v_work > 0 and v_shift_h > 0 then v_sal / (v_work * v_shift_h) else 0 end;
    v_otpay := round(v_ot / 60.0 * v_hr * st.overtime_multiplier, 2);
    v_ded   := round(v_sal / v_dim * v_unpd, 2);

    return query select rec.id, rec.username, rec.full_name, rec.department, v_sal, v_dim, v_pres, v_abs,
                        v_l + v_lop, v_paid, v_unpaid, v_nj, v_unpd, v_dim - v_unpd,
                        round(v_ot / 60.0, 2), v_otpay, v_ded, round(v_sal - v_ded + v_otpay, 2), v_left;
  end loop;
end $$;
revoke execute on function public.admin_payroll(int, int) from public, anon;
grant  execute on function public.admin_payroll(int, int) to authenticated;

-- #####################################################################
-- PART E - EMPLOYEE REGISTRATION AND LOGIN APPROVAL (New employee? Register / Check status / Create login / Pending Login Approvals)
-- (from employee_registration.sql; includes the matching fix of fix_registration_match.sql)
-- #####################################################################
-- =====================================================================
-- EMPLOYEE REGISTRATION AND LOGIN APPROVAL WORKFLOW   (run this ONE file; safe to run again)
--
--   1. "New employee? Register": the employee types the Full Name and ONE contact - the e-mail ID or the mobile number -
--      that HR / Admin saved in the employee record. The details are matched with that record.
--   2. A code is sent to that e-mail / mobile number (Supabase Auth). The employee types it.
--   3. The verified request goes to "Pending Login Approvals" (HR and Admin): Approve or Reject.
--   4. Only after approval the employee opens "Check status / Create login", gets a code again and creates the
--      Username, Password and Confirm Password. The password is saved by Supabase Auth only; nobody can see it.
--   5. HR / Admin see username, account status, verification, approval and login status - never the password.
--   6. Login works only after approval AND account creation.
--
--   Employee sees:  Pending Verification -> Pending Approval -> Approved - Create Login -> Active   (or Rejected)
--
--   Needs in Supabase Dashboard -> Authentication:
--     * Providers -> Email: enabled; the "Confirm signup" and "Magic Link" templates must contain {{ .Token }} (the code)
--     * Providers -> Phone: enabled with an SMS provider, only if employees verify with a mobile number
--     * "Allow new users to sign up" ON (a person who verifies a code gets an inactive helper account that is deleted
--       when the login is created)
-- =====================================================================
alter table public.profiles add column if not exists login_claimed boolean not null default true;
alter table public.profiles add column if not exists email text;

create or replace function public._phone_key(p text) returns text
language sql immutable as $$
  select right(regexp_replace(coalesce(p, ''), '\D', '', 'g'), 10)
$$;
revoke execute on function public._phone_key(text) from public, anon, authenticated;

create or replace function public._norm(p text) returns text
language sql immutable as $$
  select lower(regexp_replace(trim(coalesce(p, '')), '\s+', ' ', 'g'))
$$;

-- ---------------------------------------------------------------------
-- 1. Registration requests
-- ---------------------------------------------------------------------
create table if not exists public.employee_registrations (
  id                bigint generated always as identity primary key,
  employee_id       uuid not null references public.profiles(id) on delete cascade,   -- the record made by Admin / HR
  verifier_id       uuid,                                                              -- the Auth user that verified the code
  channel           text,
  full_name         text not null,
  mobile            text,
  email             text,
  department        text,
  designation       text,
  email_verified_at timestamptz,
  phone_verified_at timestamptz,
  status            text not null default 'Pending Verification'
                      check (status in ('Pending Verification', 'Pending Approval', 'Approved', 'Active', 'Rejected')),
  created_at        timestamptz not null default now(),
  submitted_at      timestamptz,
  reviewed_by       uuid references public.profiles(id),
  reviewed_at       timestamptz,
  review_note       text,
  login_created_at  timestamptz
);
alter table public.employee_registrations add column if not exists channel text;
alter table public.employee_registrations alter column mobile drop not null;
alter table public.employee_registrations alter column email drop not null;
create unique index if not exists employee_registrations_open_idx on public.employee_registrations (employee_id)
  where status in ('Pending Verification', 'Pending Approval', 'Approved');
create index if not exists employee_registrations_status_idx on public.employee_registrations (status, id desc);
create index if not exists employee_registrations_verifier_idx on public.employee_registrations (verifier_id);

alter table public.employee_registrations enable row level security;
drop policy if exists employee_registrations_read on public.employee_registrations;
create policy employee_registrations_read on public.employee_registrations for select to authenticated
  using (private.is_staff_admin());
-- nobody writes to the table directly: only the functions below
revoke all on public.employee_registrations from anon, authenticated;
grant select on public.employee_registrations to authenticated;

do $$
begin
  if not exists (select 1 from pg_publication_tables
                  where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'employee_registrations') then
    alter publication supabase_realtime add table public.employee_registrations;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 2. Matching with the employee record made by Admin / HR
-- ---------------------------------------------------------------------
-- the one active employee record with this e-mail / mobile number (read from what Admin / HR saved in the app)
create or replace function public._registration_match2(p_channel text, p_contact text, p_name text) returns uuid
language plpgsql stable security definer set search_path = public as $$
declare ids uuid[]; k text; v text;
begin
  if p_channel = 'mobile' then
    k := right(regexp_replace(coalesce(p_contact, ''), '\D', '', 'g'), 10);
    if length(k) < 10 then return null; end if;
    select array_agg(distinct p.id) into ids
      from public.profiles p left join public.employee_details d on d.user_id = p.id
     where p.role = 'Employee' and p.active
       and (right(regexp_replace(coalesce(p.phone, ''), '\D', '', 'g'), 10) = k
         or right(regexp_replace(coalesce(d.cell_no, ''), '\D', '', 'g'), 10) = k);
  elsif p_channel = 'email' then
    v := lower(trim(coalesce(p_contact, '')));
    if v !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then return null; end if;
    select array_agg(distinct p.id) into ids
      from public.profiles p left join public.employee_details d on d.user_id = p.id
     where p.role = 'Employee' and p.active
       and (lower(coalesce(d.email, '')) = v or lower(coalesce(p.email, '')) = v);
  else
    return null;
  end if;
  if coalesce(array_length(ids, 1), 0) <> 1 then return null; end if;
  return ids[1];
end $$;
revoke execute on function public._registration_match2(text, text, text) from public, anon, authenticated;

-- Before sign-in: do the details match? (true / false only: nothing about the record is revealed)
drop function if exists public.check_registration_details(text, text);
create or replace function public.check_registration_details(p_channel text, p_contact text, p_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select public._registration_match2(lower(trim(coalesce(p_channel, ''))), p_contact, p_name) is not null
$$;
revoke execute on function public.check_registration_details(text, text, text) from public;
grant  execute on function public.check_registration_details(text, text, text) to anon, authenticated;

-- ---------------------------------------------------------------------
-- 3. The employee: code verified -> the request goes to HR / Admin
-- ---------------------------------------------------------------------
create or replace function public.start_registration(p_channel text, p_contact text, p_name text) returns text
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  au auth.users;
  e uuid;
  emp public.profiles;
  ch text := lower(trim(coalesce(p_channel, '')));
  v_email text := null;
  v_mobile text := null;
  r public.employee_registrations;
begin
  if uid is null then raise exception 'Verify the code first' using errcode = '28000'; end if;
  if ch not in ('email', 'mobile') then raise exception 'Choose e-mail or mobile number'; end if;
  select * into au from auth.users where id = uid;
  if ch = 'email' then
    v_email := lower(trim(coalesce(p_contact, '')));
    if au.email_confirmed_at is null or lower(coalesce(au.email, '')) <> v_email then
      raise exception 'Verify your e-mail with the code first';
    end if;
  else
    v_mobile := public._phone_key(p_contact);
    if au.phone_confirmed_at is null or public._phone_key(au.phone) <> v_mobile then
      raise exception 'Verify your mobile number with the code first';
    end if;
  end if;

  e := public._registration_match2(ch, p_contact, p_name);
  if e is null then
    raise exception 'These details do not match an employee record that is waiting for a login. Check them, or ask HR / Admin';
  end if;
  if e = uid then raise exception 'Not allowed'; end if;
  select * into emp from public.profiles where id = e;

  -- the same e-mail address cannot belong to two employees
  if v_email is not null and (
       exists (select 1 from public.employee_registrations x
                where lower(coalesce(x.email, '')) = v_email and x.employee_id <> e and x.status in ('Pending Approval', 'Approved', 'Active'))
    ) then
    raise exception 'This e-mail address is already used by another employee';
  end if;

  select * into r from public.employee_registrations
   where employee_id = e and status in ('Pending Verification', 'Pending Approval', 'Approved') for update;
  if r.id is not null and r.status = 'Pending Approval' then
    raise exception 'Your registration is already waiting for HR / Admin approval';
  elsif r.id is not null and r.status = 'Approved' then
    raise exception 'Your registration is already approved. Use "Check status / Create login"';
  elsif r.id is not null then
    update public.employee_registrations
       set verifier_id = uid, channel = ch, status = 'Pending Approval', submitted_at = now(),
           email = v_email, mobile = coalesce(v_mobile, public._phone_key(emp.phone)),
           email_verified_at = case when ch = 'email' then au.email_confirmed_at end,
           phone_verified_at = case when ch = 'mobile' then au.phone_confirmed_at end
     where id = r.id;
  else
    insert into public.employee_registrations
      (employee_id, verifier_id, channel, full_name, mobile, email, department, designation, email_verified_at, phone_verified_at, status, submitted_at)
    values (e, uid, ch, emp.full_name, coalesce(v_mobile, public._phone_key(emp.phone)), v_email, emp.department, emp.designation,
            case when ch = 'email' then au.email_confirmed_at end, case when ch = 'mobile' then au.phone_confirmed_at end,
            'Pending Approval', now());
  end if;
  insert into public.audit_log (actor_id, action, detail) values (e, 'REGISTRATION_REQUEST', emp.full_name || ' (' || ch || ')');
  return 'Pending Approval';
end $$;

-- The employee (signed in with the code): where is my request?
drop function if exists public.my_registration();
create or replace function public.my_registration()
returns table (id bigint, status text, full_name text, email text, mobile text, review_note text,
               submitted_at timestamptz, reviewed_at timestamptz, message text)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  if auth.uid() is null then raise exception 'Verify the code first' using errcode = '28000'; end if;
  return query
  select r.id, r.status, r.full_name, r.email, r.mobile, r.review_note, r.submitted_at, r.reviewed_at,
         case r.status
           when 'Pending Verification' then 'Register again to send your request to HR / Admin.'
           when 'Pending Approval'     then 'Your request is waiting for HR / Admin approval.'
           when 'Approved'             then 'Approved. Create your username and password now.'
           when 'Active'               then 'Your login is active. Sign in with your username and password.'
           when 'Rejected'             then 'Your request was rejected.' || coalesce(' Reason: ' || nullif(r.review_note, ''), '') || ' Contact HR / Admin.'
         end
    from public.employee_registrations r
   where r.verifier_id = auth.uid()
   order by r.id desc limit 1;
end $$;

-- A code verified for "Check status": link the helper account to the request that has this e-mail / mobile number
create or replace function public.claim_registration_status(p_channel text, p_contact text) returns text
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid(); au auth.users; r public.employee_registrations;
  ch text := lower(trim(coalesce(p_channel, '')));
begin
  if uid is null then raise exception 'Verify the code first' using errcode = '28000'; end if;
  select * into au from auth.users where id = uid;
  if ch = 'email' then
    if au.email_confirmed_at is null or lower(coalesce(au.email, '')) <> lower(trim(coalesce(p_contact, ''))) then
      raise exception 'Verify your e-mail with the code first';
    end if;
    select * into r from public.employee_registrations
     where lower(coalesce(email, '')) = lower(trim(p_contact)) order by id desc limit 1 for update;
  elsif ch = 'mobile' then
    if au.phone_confirmed_at is null or public._phone_key(au.phone) <> public._phone_key(p_contact) then
      raise exception 'Verify your mobile number with the code first';
    end if;
    select * into r from public.employee_registrations
     where mobile = public._phone_key(p_contact) order by id desc limit 1 for update;
  else
    raise exception 'Choose e-mail or mobile number';
  end if;
  if r.id is null then raise exception 'No registration was found for this contact. Register first'; end if;
  -- the request must have been verified with the same kind of contact
  if r.channel is distinct from ch then raise exception 'Use the same e-mail / mobile number you registered with'; end if;
  update public.employee_registrations set verifier_id = uid where id = r.id;
  return r.status;
end $$;

-- ---------------------------------------------------------------------
-- 4. HR / Admin: approve or reject
-- ---------------------------------------------------------------------
create or replace function public.review_registration_request(p_id bigint, p_approve boolean, p_note text default null) returns text
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._require_admin(); r public.employee_registrations;
begin
  select * into r from public.employee_registrations where id = p_id for update;
  if r.id is null then raise exception 'Request not found'; end if;
  if r.status <> 'Pending Approval' then raise exception 'This request is already %', lower(r.status); end if;
  if r.employee_id = me.id then raise exception 'You cannot review your own request'; end if;
  update public.employee_registrations
     set status = case when p_approve then 'Approved' else 'Rejected' end,
         reviewed_by = me.id, reviewed_at = now(), review_note = nullif(trim(coalesce(p_note, '')), '')
   where id = p_id;
  perform public._audit(case when p_approve then 'APPROVE_REGISTRATION_REQUEST' else 'REJECT_REGISTRATION_REQUEST' end, r.full_name);
  return case when p_approve then 'Approved' else 'Rejected' end;
end $$;

-- ---------------------------------------------------------------------
-- 5. The employee, after approval: create the username and password
-- ---------------------------------------------------------------------
create or replace function public.complete_registration_login(p_username text, p_password text, p_confirm text) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare
  uid uuid := auth.uid();
  r public.employee_registrations;
  v_u text := lower(trim(coalesce(p_username, '')));
begin
  if uid is null then raise exception 'Verify the code first' using errcode = '28000'; end if;
  select * into r from public.employee_registrations
   where verifier_id = uid and status = 'Approved' order by id desc limit 1 for update;
  if r.id is null then raise exception 'Your registration is not approved yet'; end if;

  if v_u !~ '^[a-z0-9._-]{2,40}$' then
    raise exception 'Username may contain letters, numbers, dot, dash and underscore (2-40 characters)';
  end if;
  if v_u like 'pending-%' then raise exception 'Choose another username'; end if;
  if p_password is distinct from p_confirm then raise exception 'The two passwords are not the same'; end if;
  if length(coalesce(p_password, '')) < 12 then raise exception 'The password must be at least 12 characters'; end if;
  if p_password !~ '[A-Z]' or p_password !~ '[a-z]' or p_password !~ '[0-9]' or p_password !~ '[^A-Za-z0-9]' then
    raise exception 'The password needs an upper-case letter, a lower-case letter, a number and a special character';
  end if;
  if length(v_u) >= 3 and position(v_u in lower(p_password)) > 0 then raise exception 'The password must not contain the username'; end if;
  if exists (select 1 from public.profiles where lower(username) = v_u and id <> r.employee_id) then
    raise exception 'This username is already taken. Choose another one';
  end if;
  if not exists (select 1 from public.profiles where id = r.employee_id and role = 'Employee' and active) then
    raise exception 'This employee record is no longer active';
  end if;

  begin
    update public.profiles set username = v_u, login_claimed = true, email = coalesce(r.email, email) where id = r.employee_id;
  exception when unique_violation then
    raise exception 'This username is already taken. Choose another one';
  end;
  -- the password is saved by Supabase Auth only (bcrypt hash); it is never stored anywhere else
  update auth.users set encrypted_password = crypt(p_password, gen_salt('bf')), updated_at = now() where id = r.employee_id;
  update public.employee_registrations set status = 'Active', login_created_at = now() where id = r.id;
  insert into public.audit_log (actor_id, action, detail) values (r.employee_id, 'LOGIN_CREATED', v_u);

  -- the helper account that proved the e-mail / mobile number is no longer needed
  begin
    delete from auth.users where id = uid;
  exception when others then
    update public.profiles set active = false where id = uid;
  end;
  return v_u;
end $$;

-- ---------------------------------------------------------------------
-- 6. HR / Admin: registration and login status of every employee (never the password)
-- ---------------------------------------------------------------------
drop function if exists public.admin_login_overview();
create or replace function public.admin_login_overview()
returns table (
  user_id uuid, username text, role text, active boolean, login_claimed boolean, reg_id bigint, reg_status text, email text,
  email_verified boolean, phone_verified boolean, approval text, reviewed_at timestamptz, account_created_at timestamptz
)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  perform public._require_admin();
  return query
  select p.id,
         case when p.login_claimed then p.username else null end,
         p.role, p.active, p.login_claimed, r.id, r.status,
         coalesce(r.email, p.email),
         (r.email_verified_at is not null),
         (r.phone_verified_at is not null),
         case when r.status in ('Pending Approval') then 'Pending'
              when r.status in ('Approved', 'Active') then 'Approved'
              when r.status = 'Rejected' then 'Rejected' end,
         r.reviewed_at,
         coalesce(r.login_created_at, case when p.login_claimed then p.created_at end)
    from public.profiles p
    left join lateral (select x.* from public.employee_registrations x where x.employee_id = p.id order by x.id desc limit 1) r on true
   where p.approval_status = 'Approved' and p.reg_submitted
   order by p.full_name;
end $$;

-- ---------------------------------------------------------------------
-- 7. Grants; the older routes that skip the approval are switched off
-- ---------------------------------------------------------------------
revoke execute on function public.start_registration(text, text, text) from public, anon;
revoke execute on function public.my_registration() from public, anon;
revoke execute on function public.claim_registration_status(text, text) from public, anon;
revoke execute on function public.review_registration_request(bigint, boolean, text) from public, anon;
revoke execute on function public.complete_registration_login(text, text, text) from public, anon;
revoke execute on function public.admin_login_overview() from public, anon;
grant  execute on function public.start_registration(text, text, text) to authenticated;
grant  execute on function public.my_registration() to authenticated;
grant  execute on function public.claim_registration_status(text, text) to authenticated;
grant  execute on function public.review_registration_request(bigint, boolean, text) to authenticated;
grant  execute on function public.complete_registration_login(text, text, text) to authenticated;
grant  execute on function public.admin_login_overview() to authenticated;

do $$
declare f text;
begin
  foreach f in array array[
    'public.request_login(text)',
    'public.register_with_mobile(text, text, text)',
    'public.register_with_mobile(text, text, text, text)',
    'public.submit_registration(text, text, text, text, text, text)',
    'public.complete_self_registration(text, text, text, text, text)'
  ] loop
    if to_regprocedure(f) is not null then
      execute format('revoke execute on function %s from public, anon, authenticated', f);
    end if;
  end loop;
end $$;

notify pgrst, 'reload schema';


-- #####################################################################
-- PART F - PAYROLL MONTHS: Draft / Ready to finalize / Finalized (locked)
-- (from payroll_months.sql)
-- #####################################################################
-- =====================================================================
-- PAYROLL MONTHS: Draft -> Ready to finalize -> Finalized (locked)
--   * The current month is "Draft - live salaries": it follows the salaries and attendance as they are today.
--   * A past month that is not finalized yet is "Ready to finalize".
--   * Admin presses "Finalize" on a past month. A finalized month is locked: a later increment can only start AFTER the
--     last finalized month, so a finalized month never changes.
-- Needs salary_management.sql first. Run in Supabase SQL Editor (copy all the text, then Run). Safe to run again.
-- =====================================================================
create table if not exists public.payroll_months (
  year          int not null,
  month         int not null check (month between 1 and 12),
  finalized_at  timestamptz not null default now(),
  finalized_by  uuid references public.profiles(id),
  primary key (year, month)
);
alter table public.payroll_months enable row level security;
drop policy if exists payroll_months_read on public.payroll_months;
create policy payroll_months_read on public.payroll_months for select to authenticated using (public.is_full_admin());
-- nobody writes to the table directly: only admin_finalize_month() below
revoke all on public.payroll_months from anon, authenticated;
grant select on public.payroll_months to authenticated;

-- the last 6 months and their status (Admin / HR can view)
drop function if exists public.admin_payroll_months();
create or replace function public.admin_payroll_months()
returns table (year int, month int, status text)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
begin
  perform public._require_full_admin();
  return query
  select extract(year from g)::int, extract(month from g)::int,
         case when pm.year is not null then 'Finalized'
              when g = date_trunc('month', public.ist_today()::timestamp)::date then 'Draft'
              else 'Ready' end
    from generate_series(date_trunc('month', public.ist_today()::timestamp)::date - interval '5 months',
                         date_trunc('month', public.ist_today()::timestamp)::date, interval '1 month') g
    left join public.payroll_months pm on pm.year = extract(year from g)::int and pm.month = extract(month from g)::int
   order by g desc;
end $$;
revoke execute on function public.admin_payroll_months() from public, anon;
grant  execute on function public.admin_payroll_months() to authenticated;

-- Admin only: lock a month that is over
create or replace function public.admin_finalize_month(p_year int, p_month int) returns text
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._require_active(); m0 date := make_date(p_year, p_month, 1);
begin
  if me.role not in ('Admin', 'HR') then raise exception 'Only the Admin / HR can finalize a month' using errcode = '42501'; end if;
  if m0 >= date_trunc('month', public.ist_today()::timestamp)::date then raise exception 'Only a month that is over can be finalized'; end if;
  insert into public.payroll_months (year, month, finalized_by) values (p_year, p_month, me.id) on conflict do nothing;
  perform public._audit('FINALIZE_PAYROLL', to_char(m0, 'Mon YYYY'));
  return 'Finalized';
end $$;
revoke execute on function public.admin_finalize_month(int, int) from public, anon;
grant  execute on function public.admin_finalize_month(int, int) to authenticated;

-- A salary change can never start inside a finalized month
create or replace function public._lock_finalized_salary() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_end date;
begin
  select max((make_date(year, month, 1) + interval '1 month - 1 day')::date) into v_end from public.payroll_months;
  if v_end is not null and new.effective_date <= v_end and new.effective_date > date '2000-01-01' then
    raise exception 'Months up to % are finalized. An increment can only start after that date', to_char(v_end, 'DD-MM-YYYY');
  end if;
  return new;
end $$;
drop trigger if exists salary_history_lock on public.salary_history;
create trigger salary_history_lock before insert on public.salary_history
  for each row execute function public._lock_finalized_salary();
revoke execute on function public._lock_finalized_salary() from public, anon, authenticated;

notify pgrst, 'reload schema';


-- #####################################################################
-- PART I - FIELD SITE JOURNEYS + FIELD SITE / FOREIGN LOCATION ACCESS
-- (from field_journeys.sql)
-- #####################################################################
-- =====================================================================
-- FIELD SITE JOURNEYS (employees travelling between project locations)
--   * Start Journey: from site (= the previous destination of the day), to site, client / project, purpose, GPS and time.
--   * Reached Site : arrival time and GPS, destination geofence check, duration and GPS-based distance.
--   * Record keeping only: there is NO approval / rejection. Admin / HR see every journey; a journey is "Verified" only when
--     it arrived inside the destination site area AND real GPS points were recorded. Missing GPS is never invented:
--     without GPS points the journey is "Unverified" and its distance is marked 'straight' (straight line, not a route).
--   * Own access switch: Access Control -> 'Field Site Journey Access' (set per employee by Admin / HR). People who already have Visit Access
--     keep working: they get the new switch ON once, when this file is run.
--   * Retried taps are safe: every tap carries a key, a repeated key returns the same journey and never makes a second one.
-- Run AFTER cvp_attendance_schema.sql, in Supabase SQL Editor.  Safe to run again.
-- =====================================================================
-- the access switch
alter table public.profiles add column if not exists journey_access boolean not null default false;
do $$
begin
  if not exists (select 1 from public.audit_log where action = 'JOURNEY_ACCESS_BACKFILL') then
    update public.profiles set journey_access = true where visit_access;
    insert into public.audit_log (actor_id, action, detail) values (null, 'JOURNEY_ACCESS_BACKFILL', 'Employees with Visit Access keep Field Site Journey access');
  end if;
end $$;

create or replace function public._require_journey_access() returns public.profiles
language plpgsql stable security definer set search_path = public as $$
declare p public.profiles;
begin
  p := public._require_active();
  if not p.journey_access then
    raise exception 'Field Site Journey access is not enabled for your account. Contact your Admin.' using errcode = '42501';
  end if;
  return p;
end $$;
revoke execute on function public._require_journey_access() from public, anon, authenticated;

-- Admin / HR: switch the access on or off for one employee
create or replace function public.admin_set_journey_access(p_user uuid, p_enabled boolean)
returns public.profiles
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._require_admin(); target public.profiles;
begin
  select * into target from public.profiles where id = p_user for update;
  if target.id is null then raise exception 'User not found'; end if;
  if me.role not in ('Admin', 'HR') and target.id <> me.id and target.role <> 'Employee' then
    raise exception 'Only an Admin can change HR / Admin accounts';
  end if;
  update public.profiles set journey_access = p_enabled where id = p_user returning * into target;
  perform public._audit('JOURNEY_ACCESS', target.username || ' journey_access=' || p_enabled);
  return target;
end $$;
revoke execute on function public.admin_set_journey_access(uuid, boolean) from public, anon;
grant  execute on function public.admin_set_journey_access(uuid, boolean) to authenticated;

create table if not exists public.field_journeys (
  id              bigint generated always as identity primary key,
  user_id         uuid not null references public.profiles(id) on delete cascade,
  journey_date    date not null,
  from_site_id    bigint references public.sites(id) on delete set null,
  from_site_name  text not null,
  to_site_id      bigint references public.sites(id) on delete set null,
  to_site_name    text not null,
  client          text not null check (length(trim(client)) > 0),
  purpose         text not null check (length(trim(purpose)) > 0),
  start_at        timestamptz not null default clock_timestamp(),
  start_lat       double precision not null,
  start_lng       double precision not null,
  start_acc_m     integer,
  end_at          timestamptz,
  end_lat         double precision,
  end_lng         double precision,
  end_acc_m       integer,
  status          text not null default 'In Progress' check (status in ('In Progress', 'Completed')),
  travel_km       numeric(8,1),
  travel_source   text check (travel_source in ('gps', 'straight')),
  gps_points      integer,
  gps_gap_min     integer,                  -- longest stretch without a GPS point (minutes), null when unknown
  dest_dist_m     integer,                  -- metres from the centre of the destination site at arrival
  dest_inside     boolean,
  verified        boolean,
  verify_note     text,
  start_key       text,
  end_key         text,
  created_at      timestamptz not null default now(),
  check (end_at is null or end_at >= start_at)
);
create index if not exists field_journeys_user_date_idx on public.field_journeys (user_id, journey_date desc, id);
create index if not exists field_journeys_date_idx on public.field_journeys (journey_date desc);
create unique index if not exists field_journeys_one_open_idx on public.field_journeys (user_id) where end_at is null;
create unique index if not exists field_journeys_start_key_idx on public.field_journeys (user_id, start_key) where start_key is not null;

alter table public.field_journeys enable row level security;
drop policy if exists field_journeys_read on public.field_journeys;
create policy field_journeys_read on public.field_journeys for select to authenticated
  using (user_id = auth.uid() or private.is_staff_admin());
revoke all on public.field_journeys from anon;
grant select on public.field_journeys to authenticated;

do $$
begin
  if not exists (select 1 from pg_publication_tables
                  where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'field_journeys') then
    alter publication supabase_realtime add table public.field_journeys;
  end if;
end $$;

-- live location and the GPS trail also run while a journey is open
alter table public.live_locations drop constraint if exists live_locations_kind_check;
alter table public.live_locations add constraint live_locations_kind_check check (kind in ('visit', 'travel', 'journey'));

create or replace function public._tracking_kind(p_user uuid) returns text
language sql stable security definer set search_path = public as $$
  select case
    when exists (select 1 from public.field_journeys j where j.user_id = p_user and j.end_at is null) then 'journey'
    when exists (select 1 from public.visits v where v.user_id = p_user and v.end_at is null) then 'visit'
    when exists (select 1 from public.attendance_legs l where l.user_id = p_user and l.out_at is null
                   and l.work_date = public.ist_today()) then 'travel'
    when exists (select 1 from public.attendance a
                  where a.user_id = p_user and a.work_date = public.ist_today() and not a.travel_done
                    and exists (select 1 from public.attendance_legs l where l.attendance_id = a.id)) then 'travel'
    else null end
$$;
revoke execute on function public._tracking_kind(uuid) from public, anon, authenticated;

-- the position disappears when the journey is closed
create or replace function public._clear_live_location_j() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public._tracking_kind(new.user_id) is null then delete from public.live_locations where user_id = new.user_id; end if;
  return new;
end $$;
drop trigger if exists field_journeys_clear_live on public.field_journeys;
create trigger field_journeys_clear_live after update on public.field_journeys
  for each row execute function public._clear_live_location_j();
revoke execute on function public._clear_live_location_j() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Start Journey. p_from_site null = the previous destination of today (or the office if there is none yet).
-- ---------------------------------------------------------------------
create or replace function public.start_journey(
  p_from_site bigint, p_to_site bigint, p_client text, p_purpose text,
  p_lat double precision, p_lng double precision, p_accuracy integer default null, p_key text default null
) returns public.field_journeys
language plpgsql security definer set search_path = public as $$
declare
  me   public.profiles := public._require_journey_access();
  d    date := public.ist_today();
  prev public.field_journeys;
  fs   public.sites;
  ts   public.sites;
  r    public.field_journeys;
begin
  -- a repeated tap (same key) returns the journey that already exists
  if p_key is not null then
    select * into r from public.field_journeys where user_id = me.id and start_key = p_key;
    if r.id is not null then return r; end if;
  end if;
  if exists (select 1 from public.field_journeys where user_id = me.id and end_at is null) then
    raise exception 'You already have a journey in progress. Press Reached Site first';
  end if;
  if p_lat is null or p_lng is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 then
    raise exception 'Location is required to start a journey. Turn on GPS and try again';
  end if;
  if nullif(trim(p_client), '') is null then raise exception 'Enter the client / project'; end if;
  if nullif(trim(p_purpose), '') is null then raise exception 'Enter the visit purpose'; end if;
  if p_to_site is null then raise exception 'Choose the site you are going to'; end if;

  select * into prev from public.field_journeys where user_id = me.id and journey_date = d and status = 'Completed'
   order by end_at desc limit 1;
  if prev.id is not null then
    p_from_site := prev.to_site_id;                       -- the next journey starts where the last one ended
    if p_from_site is null then
      select * into fs from public.sites where false;
    end if;
  end if;
  if p_from_site is null and prev.id is null then
    select * into fs from public.sites where active and is_office order by id limit 1;
    p_from_site := fs.id;
  end if;
  if p_from_site is not null then select * into fs from public.sites where id = p_from_site; end if;
  select * into ts from public.sites where id = p_to_site and active;
  if ts.id is null then raise exception 'Choose an active work site as the destination'; end if;
  if fs.id is null and prev.id is null then raise exception 'Choose the site you start from'; end if;
  if fs.id is not null and fs.id = ts.id then raise exception 'The destination must be different from the starting site'; end if;

  insert into public.field_journeys (user_id, journey_date, from_site_id, from_site_name, to_site_id, to_site_name,
                                     client, purpose, start_lat, start_lng, start_acc_m, start_key)
  values (me.id, d, fs.id, coalesce(fs.name, prev.to_site_name), ts.id, ts.name,
          trim(p_client), trim(p_purpose), p_lat, p_lng, p_accuracy, p_key)
  returning * into r;
  perform public._audit('JOURNEY_START', me.username || ': ' || r.from_site_name || ' > ' || r.to_site_name);
  return r;
end $$;

-- ---------------------------------------------------------------------
-- Reached Site: arrival, geofence check, duration and GPS distance.
-- ---------------------------------------------------------------------
create or replace function public.reach_site(
  p_lat double precision, p_lng double precision, p_accuracy integer default null, p_key text default null
) returns public.field_journeys
language plpgsql security definer set search_path = public as $$
declare
  me     public.profiles := public._require_journey_access();
  j      public.field_journeys;
  ts     public.sites;
  rk     record;
  d      double precision;
  v_end  timestamptz := clock_timestamp();
  v_pts  integer; v_gap integer; v_notes text[] := '{}'; v_inside boolean := null; v_dist integer := null;
begin
  if p_key is not null then
    select * into j from public.field_journeys where user_id = me.id and end_key = p_key;
    if j.id is not null then return j; end if;                     -- repeated tap: same answer
  end if;
  select * into j from public.field_journeys where user_id = me.id and end_at is null for update;
  if j.id is null then raise exception 'You have no journey in progress'; end if;
  if p_lat is null or p_lng is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 then
    raise exception 'Location is required to confirm arrival. Turn on GPS and try again';
  end if;

  -- GPS route: real points sent between the start and now (never invented)
  select count(*)::int into v_pts from public.travel_track t
   where t.user_id = me.id and t.recorded_at > j.start_at and t.recorded_at < v_end and coalesce(t.accuracy_m, 0) <= 100;
  select coalesce(max(extract(epoch from (b - a)) / 60)::int, null) into v_gap
    from (select t.recorded_at as a, lead(t.recorded_at) over (order by t.recorded_at) as b
            from (select recorded_at from public.travel_track where user_id = me.id and recorded_at > j.start_at and recorded_at < v_end
                  union all select j.start_at union all select v_end) t) g
   where b is not null;
  select * into rk from public._route_km(me.id, j.start_at, v_end, j.start_lat, j.start_lng, p_lat, p_lng);

  -- destination geofence
  select * into ts from public.sites where id = j.to_site_id;
  if ts.id is not null then
    d := public._distance_m(p_lat, p_lng, ts.lat, ts.lng);
    v_dist := round(d)::int; v_inside := d <= ts.radius_m;
    if not v_inside then v_notes := v_notes || ('Arrived ' || v_dist || ' m outside the site area'); end if;
  else
    v_notes := v_notes || 'Destination site was removed: arrival could not be checked';
  end if;
  if rk.source = 'straight' then v_notes := v_notes || 'No GPS route was recorded: distance is a straight line, not a route'; end if;
  if rk.source = 'gps' and v_gap is not null and v_gap >= 5 then v_notes := v_notes || ('GPS lost for up to ' || v_gap || ' min (the gap is not filled in)'); end if;
  if p_accuracy is not null and p_accuracy > 100 then v_notes := v_notes || ('Weak GPS at arrival (+/-' || p_accuracy || ' m)'); end if;

  update public.field_journeys set
      end_at = v_end, end_lat = p_lat, end_lng = p_lng, end_acc_m = p_accuracy, status = 'Completed',
      travel_km = rk.km, travel_source = rk.source, gps_points = v_pts, gps_gap_min = v_gap,
      dest_dist_m = v_dist, dest_inside = v_inside,
      verified = (coalesce(v_inside, false) and rk.source = 'gps' and coalesce(v_gap, 0) < 5 and coalesce(p_accuracy, 0) <= 100),
      verify_note = nullif(array_to_string(v_notes, '; '), ''), end_key = p_key
    where id = j.id returning * into j;
  perform public._audit('JOURNEY_REACHED', me.username || ': ' || j.from_site_name || ' > ' || j.to_site_name
    || ' (' || coalesce(j.travel_km::text, '?') || ' km, ' || case when j.verified then 'verified' else 'unverified' end || ')');
  return j;
end $$;

revoke execute on function public.start_journey(bigint, bigint, text, text, double precision, double precision, integer, text) from public, anon;
revoke execute on function public.reach_site(double precision, double precision, integer, text) from public, anon;
grant  execute on function public.start_journey(bigint, bigint, text, text, double precision, double precision, integer, text) to authenticated;
grant  execute on function public.reach_site(double precision, double precision, integer, text) to authenticated;

notify pgrst, 'reload schema';


-- #####################################################################
-- PART J - LEAVE ELIGIBILITY (6 MONTHS), MONTHLY PAID LEAVE AND SALARY DEDUCTION
-- (from leave_eligibility.sql; it replaces the payroll calculation of PART D, so it must stay AFTER part D)
-- #####################################################################
-- =====================================================================
-- LEAVE ELIGIBILITY AND SALARY DEDUCTION (from the joining date, fully automatic)
--   * Eligible from = joining date + 6 months (the day the 6 months are completed). Nothing is switched on by hand.
--   * BEFORE that day: every leave day is UNPAID. The employee may still apply (the leave balance is not checked), the leave days are
--     not taken from the leave balance, and the salary of those days is deducted in payroll.
--   * FROM that day: normal leave rules. Up to `paid_leaves_per_month` (2) approved leave days a month are paid; leave beyond that and
--     Loss of Pay stay unpaid. Paid leave is taken from the leave balance of the year, counted from the eligibility day.
--   * Leave balances, the leave screens, payroll, the salary sheet and the salary slips (which use payroll) all follow these rules by themselves.
--   * An employee without a joining date is treated as eligible (nothing can be calculated without the date): enter the joining date in Employees.
-- Run in Supabase Dashboard -> SQL Editor -> New query -> Run.  Safe to run again.  Run it AFTER cvp_attendance_schema.sql and salary_management.sql.
-- To change the rule later: update public.payroll_settings set paid_leaves_per_month = 2 where id = 1;  (the 6 months are in _leave_eligible_from below)
-- =====================================================================

-- The leave type that uses the monthly paid allowance (2 paid days a month, after 6 months of service)
insert into public.leave_types (name, annual_quota, counts_balance, sort_order, active)
values ('Monthly Paid Leave', 24, true, 5, true)
on conflict (name) do nothing;

-- The day an employee becomes eligible for paid leave (null = no joining date)
create or replace function public._leave_eligible_from(p_user uuid) returns date
language sql stable security definer set search_path = public as $$
  select (p.joining_date + interval '6 months')::date from public.profiles p where p.id = p_user
$$;
revoke execute on function public._leave_eligible_from(uuid) from public, anon, authenticated;

-- Leave days of one person between two dates: (counted leave types, Loss of Pay). Empty range = zeros.
create or replace function public._leave_days_split(p_user uuid, p_from date, p_to date)
returns table (counted int, lop int)
language sql stable security definer set search_path = public as $$
  select coalesce(sum(u.days) filter (where lt.counts_balance), 0)::int,
         coalesce(sum(u.days) filter (where not lt.counts_balance), 0)::int
    from public._leave_usage(p_user, p_from, p_to, array['Approved']) u
    join public.leave_types lt on lt.name = u.leave_type
$$;
revoke execute on function public._leave_days_split(uuid, date, date) from public, anon, authenticated;

-- Leave balance: leave taken before the eligibility day does not use the balance (it is unpaid)
create or replace function public._leave_balance(p_user uuid, p_year int)
returns table (leave_type text, granted int, used int, balance int, counts_balance boolean)
language sql stable security definer set search_path = public as $$
  select t.name,
         g.q,
         coalesce(u.days, 0)::int,
         (g.q - coalesce(u.days, 0))::int,
         t.counts_balance
  from public.leave_types t
  cross join lateral (
    select coalesce((select q.quota from public.employee_leave_quota q
                      where q.user_id = p_user and q.year = p_year and q.leave_type = t.name),
                    t.annual_quota)::int as q) g
  left join public._leave_usage(p_user,
              greatest(make_date(p_year, 1, 1), coalesce(public._leave_eligible_from(p_user), date '1900-01-01')),
              make_date(p_year, 12, 31)) u on u.leave_type = t.name
  where t.active
    -- Monthly Paid Leave exists only for an employee who has completed 6 months of service (joining date known)
    and (t.name <> 'Monthly Paid Leave'
         or (public._leave_eligible_from(p_user) is not null and public._leave_eligible_from(p_user) <= public.ist_today()))
  order by t.sort_order, t.name
$$;
revoke execute on function public._leave_balance(uuid, int) from public, anon, authenticated;

-- Apply for leave: before the eligibility day the leave is allowed but unpaid, so the balance is not checked
create or replace function public.apply_leave(p_leave_type text, p_from date, p_to date, p_reason text)
returns public.leaves
language plpgsql security definer set search_path = public as $$
declare
  me     public.profiles := public._require_active();
  t      public.leave_types;
  v_days int;
  v_bal  int;
  v_elig date := public._leave_eligible_from(auth.uid());
  r      public.leaves;
begin
  select * into t from public.leave_types where name = p_leave_type and active;
  if t.name is null then raise exception 'Unknown leave type'; end if;
  if p_to < p_from then raise exception 'End date cannot be before start date'; end if;
  if p_from < public.ist_today() + 2 then
    raise exception 'Leave must be applied at least 2 days in advance. The earliest start date is %', to_char(public.ist_today() + 2, 'DD-MM-YYYY');
  end if;
  if nullif(trim(p_reason),'') is null then raise exception 'Enter a reason'; end if;
  if extract(year from p_from) <> extract(year from p_to) then
    raise exception 'Submit one calendar year per request';
  end if;
  select coalesce(sum(u.days), 0)::int into v_days
    from public._leave_usage(me.id, p_from - 10, p_to + 10, array['Approved','Pending'], p_from, p_to, null) u
   where u.leave_type = 'NEW';
  if v_days = 0 then raise exception 'No working days in the selected period (weekly off / holiday only)'; end if;

  if exists (select 1 from public.leaves
              where user_id = me.id and status in ('Pending','Approved')
                and from_day <= p_to and to_day >= p_from) then
    raise exception 'These dates overlap with another leave request';
  end if;

  -- Monthly Paid Leave: only after 6 months of service, only inside one month, at most paid_leaves_per_month days a month
  if t.name = 'Monthly Paid Leave' then
    declare v_per int := (select s.paid_leaves_per_month from public.payroll_settings s where s.id = 1); v_used int;
    begin
      if v_elig is null then
        raise exception 'Monthly Paid Leave needs the joining date. Ask HR / Admin to enter it in Employees';
      end if;
      if p_from < v_elig then
        raise exception 'Monthly Paid Leave starts after 6 months of service (from %). Choose another leave type, it will be unpaid', to_char(v_elig, 'DD-MM-YYYY');
      end if;
      if date_trunc('month', p_from::timestamp) <> date_trunc('month', p_to::timestamp) then
        raise exception 'Monthly Paid Leave must be within one month. Submit one request for each month';
      end if;
      select coalesce(sum(l.days), 0)::int into v_used from public.leaves l
       where l.user_id = me.id and l.leave_type = 'Monthly Paid Leave' and l.status in ('Pending', 'Approved')
         and date_trunc('month', l.from_day::timestamp) = date_trunc('month', p_from::timestamp);
      if v_used + v_days > v_per then
        raise exception 'Only % Monthly Paid Leave day(s) a month. You have % left in this month', v_per, greatest(v_per - v_used, 0);
      end if;
    end;
  end if;

  -- paid leave needs a balance; leave before the 6 months are completed is unpaid and needs none
  if t.counts_balance and (v_elig is null or p_from >= v_elig) then
    select b.balance into v_bal from public._leave_balance(me.id, extract(year from p_from)::int) b
     where b.leave_type = t.name;
    if v_days > coalesce(v_bal, 0) then
      raise exception 'Insufficient leave balance (% day(s) available)', coalesce(v_bal,0);
    end if;
  end if;

  insert into public.leaves (user_id, leave_type, from_day, to_day, days, reason)
  values (me.id, t.name, p_from, p_to, v_days, trim(p_reason))
  returning * into r;
  perform public._audit('LEAVE_REQUEST', t.name || ' ' || p_from || ' to ' || p_to
    || case when v_elig is not null and p_from < v_elig then ' (unpaid: before 6 months of service)' else '' end);
  return r;
end $$;

-- Approve / reject: the same eligibility rule for the balance check
create or replace function public.review_leave(p_id bigint, p_approve boolean, p_note text default null)
returns public.leaves
language plpgsql security definer set search_path = public as $$
declare
  me    public.profiles := public._require_admin();
  r     public.leaves;
  t     public.leave_types;
  v_bal int;
  v_elig date;
begin
  select * into r from public.leaves where id = p_id for update;
  if r.id is null then raise exception 'Leave request not found'; end if;
  if r.status <> 'Pending' then raise exception 'This request is already %', lower(r.status); end if;
  v_elig := public._leave_eligible_from(r.user_id);

  if p_approve then
    select coalesce(sum(u.days), 0)::int into r.days
      from public._leave_usage(r.user_id, r.from_day - 10, r.to_day + 10, array['Approved'], r.from_day, r.to_day, r.id) u
     where u.leave_type = 'NEW';
    if r.days = 0 then raise exception 'This request has no working days (weekly off / holiday only)'; end if;
    update public.leaves set days = r.days where id = r.id;
    select * into t from public.leave_types where name = r.leave_type;
    if t.counts_balance and (v_elig is null or r.from_day >= v_elig) then
      select b.balance into v_bal from public._leave_balance(r.user_id, extract(year from r.from_day)::int) b
       where b.leave_type = r.leave_type;
      if r.days > coalesce(v_bal, 0) then
        raise exception 'Insufficient balance: cannot approve (% day(s) available)', coalesce(v_bal,0);
      end if;
    end if;
  end if;

  update public.leaves
     set status = case when p_approve then 'Approved' else 'Rejected' end,
         reviewed_by = me.id, reviewed_at = now(), review_note = nullif(trim(p_note),'')
   where id = p_id
  returning * into r;
  perform public._audit(case when p_approve then 'APPROVE_LEAVE' else 'REJECT_LEAVE' end, p_id::text);
  return r;
end $$;

-- Salary sheet: leave before the eligibility day is unpaid; from that day 2 paid leave days a month
drop function if exists public.admin_payroll(int, int);
create or replace function public.admin_payroll(p_year int, p_month int)
returns table (
  user_id uuid, username text, full_name text, department text,
  monthly_salary numeric, days_in_month int, present int, absent int,
  leave_days int, paid_leave int, unpaid_leave int, not_joined int, unpaid_days int, payable_days int,
  overtime_hours numeric, overtime_pay numeric, deduction numeric, net_salary numeric, left_on date
)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare
  st      public.payroll_settings;
  m0      date := make_date(p_year, p_month, 1);
  m1      date := (make_date(p_year, p_month, 1) + interval '1 month - 1 day')::date;
  v_dim   int  := extract(day from (make_date(p_year, p_month, 1) + interval '1 month - 1 day'))::int;
  rec     record;
  v_left  date;
  v_elig  date; v_pre_end date; v_pre int; v_pre_l int; v_pre_lop int;
  v_sal   numeric; v_pres int; v_abs int; v_l int; v_lop int; v_paid int; v_unpaid int; v_nj int; v_after int;
  v_unpd  int; v_work int; v_ot int; v_hr numeric; v_otpay numeric; v_ded numeric; v_shift_h numeric;
begin
  perform public._require_full_admin();
  select * into st from public.payroll_settings where id = 1;
  for rec in
    select p.*, coalesce(d.resign_date, p.left_on) as left_d
      from public.profiles p left join public.employee_details d on d.user_id = p.id
     where p.active or coalesce(d.resign_date, p.left_on) is not null
     order by p.full_name
  loop
    v_left := rec.left_d;

    if v_left is not null and date_trunc('month', v_left::timestamp) < date_trunc('month', m0::timestamp) then
      return query select rec.id, rec.username, rec.full_name, rec.department, 0::numeric, v_dim, 0, 0,
                          0, 0, 0, 0, v_dim, 0, 0::numeric, 0::numeric, 0::numeric, 0::numeric, v_left;
      continue;
    end if;

    select coalesce(avg(public._salary_on(rec.id, g::date)), 0) into v_sal
      from generate_series(m0::timestamp, m1::timestamp, interval '1 day') g;
    v_sal := round(v_sal, 2);

    select count(*) filter (where m.status in ('Present','Checked In')),
           count(*) filter (where m.status = 'Absent' and m.day < public.ist_today()
                                      and m.day >= coalesce(rec.joining_date, date '1900-01-01')
                                      and (v_left is null or m.day <= v_left))
      into v_pres, v_abs
      from public._month_attendance(rec.id, p_year, p_month) m;

    -- leave: the part of the month BEFORE the 6 months are completed is unpaid, the rest follows the 2-paid-leaves rule
    v_elig := public._leave_eligible_from(rec.id);
    v_pre_end := case when v_elig is null or v_elig <= m0 then m0 - 1
                      when v_elig > m1 then m1
                      else v_elig - 1 end;
    select s.counted, s.lop into v_pre_l, v_pre_lop from public._leave_days_split(rec.id, m0, v_pre_end) s;
    v_pre := v_pre_l + v_pre_lop;
    select s.counted, s.lop into v_l, v_lop from public._leave_days_split(rec.id, v_pre_end + 1, m1) s;

    v_paid   := least(v_l, st.paid_leaves_per_month);
    v_unpaid := v_pre + (v_l - v_paid) + v_lop;
    v_nj     := case when rec.joining_date is null or rec.joining_date <= m0 then 0
                     else (least(rec.joining_date, m1 + 1) - m0) end;
    v_after  := case when v_left is not null and v_left < m1 then (m1 - v_left) else 0 end;
    v_unpd   := least(v_dim, v_abs + v_unpaid + v_nj + v_after);

    select count(*) into v_work
      from generate_series(m0::timestamp, m1::timestamp, interval '1 day') g
     where public._is_workday(rec.id, g::date);
    v_shift_h := extract(epoch from (rec.shift_end - rec.shift_start)) / 3600;
    select coalesce(sum(o.ot_minutes), 0) into v_ot from public._month_overtime(rec.id, p_year, p_month) o;

    v_hr    := case when v_work > 0 and v_shift_h > 0 then v_sal / (v_work * v_shift_h) else 0 end;
    v_otpay := round(v_ot / 60.0 * v_hr * st.overtime_multiplier, 2);
    v_ded   := round(v_sal / v_dim * v_unpd, 2);

    return query select rec.id, rec.username, rec.full_name, rec.department, v_sal, v_dim, v_pres, v_abs,
                        v_pre + v_l + v_lop, v_paid, v_unpaid, v_nj, v_unpd, v_dim - v_unpd,
                        round(v_ot / 60.0, 2), v_otpay, v_ded, round(v_sal - v_ded + v_otpay, 2), v_left;
  end loop;
end $$;

-- The employee's own eligibility and this month's paid leaves (for the Leave screen)
drop function if exists public.my_leave_eligibility();
create or replace function public.my_leave_eligibility()
returns table (joining_date date, eligible_from date, eligible boolean, days_left int, paid_per_month int, paid_used int, paid_left int)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare
  me      public.profiles := public._require_active();
  v_from  date := public._leave_eligible_from(auth.uid());
  v_ok    boolean := (v_from is null or v_from <= public.ist_today());
  v_m0    date := date_trunc('month', public.ist_today()::timestamp)::date;
  v_m1    date := (date_trunc('month', public.ist_today()::timestamp) + interval '1 month - 1 day')::date;
  v_per   int := (select s.paid_leaves_per_month from public.payroll_settings s where s.id = 1);
  v_used  int := 0;
begin
  if v_ok then
    select s.counted into v_used from public._leave_days_split(auth.uid(), greatest(v_m0, coalesce(v_from, v_m0)), v_m1) s;
  end if;
  return query
  select me.joining_date, v_from, v_ok,
         case when v_ok then 0 else (v_from - public.ist_today())::int end,
         v_per, least(coalesce(v_used, 0), v_per), greatest(v_per - coalesce(v_used, 0), 0);
end $$;
revoke execute on function public.apply_leave(text, date, date, text) from public, anon;
revoke execute on function public.review_leave(bigint, boolean, text) from public, anon;
revoke execute on function public.admin_payroll(int, int) from public, anon;
revoke execute on function public.my_leave_eligibility() from public, anon;
grant  execute on function public.apply_leave(text, date, date, text) to authenticated;
grant  execute on function public.review_leave(bigint, boolean, text) to authenticated;
grant  execute on function public.admin_payroll(int, int) to authenticated;
grant  execute on function public.my_leave_eligibility() to authenticated;

notify pgrst, 'reload schema';


-- #####################################################################
-- PART H - FUNCTION PERMISSIONS (run last: gives the signed-in app its function rights back)
-- (from fix_function_permissions.sql)
-- #####################################################################
-- =====================================================================
-- FIX: "permission denied for function admin_dashboard_stats" (or any other function) after signing in
--
-- Cause: the signed-in role ("authenticated") lost the right to EXECUTE the app functions. The main schema file contains
--        "revoke execute on all functions ... " and gives back only some of them; running it again (or a similar script)
--        leaves functions without access.
--
-- This gives the right back to signed-in users for every app function. It is safe because every admin function checks the
-- role inside itself (_require_admin / _require_full_admin) - exactly as before.
-- NOT granted (kept private on purpose):
--   * internal helpers whose name starts with "_" (except the three _require_* checks)
--   * trigger functions
--   * admin_set_salary    (salary changes go through admin_increment_salary: Admin only)
--   * submit_registration (old self-registration route, replaced by the verified registration)
-- Nothing is deleted or changed in the data. Safe to run again.
-- =====================================================================
do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.prokind = 'f'
       and p.prorettype <> 'trigger'::regtype
       and (p.proname !~ '^_' or p.proname in ('_require_active', '_require_admin', '_require_full_admin'))
       and p.proname not in ('admin_set_salary', 'submit_registration', 'request_login', 'register_with_mobile', 'review_login_request')
  loop
    execute format('grant execute on function %s to authenticated', r.sig);
  end loop;
end $$;

-- the sign-in / registration screens run before login: only these may be called by people who are not signed in
do $$
declare f text;
begin
  foreach f in array array[
    'public.login_email(text)',
    'private.login_email(text)',
    'public.check_registration_details(text, text, text)'
  ] loop
    if to_regprocedure(f) is not null then
      execute format('grant execute on function %s to anon, authenticated', f);
    end if;
  end loop;
end $$;

-- keep the two switched-off routes switched off
do $$
declare f text;
begin
  foreach f in array array['public.admin_set_salary(uuid, numeric)', 'public.submit_registration(text, text, text, text, text, text)'] loop
    if to_regprocedure(f) is not null then
      execute format('revoke execute on function %s from public, anon, authenticated', f);
    end if;
  end loop;
end $$;

-- tables: signed-in users can read (row level security still decides which rows)
grant usage on schema public to authenticated;
grant select on all tables in schema public to authenticated;

notify pgrst, 'reload schema';
