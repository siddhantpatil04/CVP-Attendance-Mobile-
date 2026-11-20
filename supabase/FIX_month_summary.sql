-- =====================================================================
-- FIX for: "cannot change return type of existing function ... Use DROP FUNCTION admin_month_summary(integer,integer) first"
-- Run this ONE small file in a NEW empty SQL Editor query (nothing else in the box). Safe to run again.
-- It removes the old admin_month_summary (public and private copy) and creates the current one (with the "left_on" column).
-- =====================================================================
drop function if exists public.admin_month_summary(integer, integer) cascade;
drop function if exists private.admin_month_summary(integer, integer) cascade;

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
notify pgrst, 'reload schema';