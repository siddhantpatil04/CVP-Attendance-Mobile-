-- =====================================================================
-- ESIC IP number of an employee (Employee > Joining > "ESIC IP no.", next to UAN): used by the ESIC Report in Company Reports.
-- Adds ONE nullable column and ONE small Admin / HR function. No existing row is changed.
-- BACK UP FIRST.   Supabase -> SQL Editor -> paste the WHOLE file -> Run.   Safe to run again.
-- Undo (copy without the leading "-- "):
--   drop function if exists public.admin_set_esic_no(uuid, text);
--   alter table public.employee_details drop column if exists esic_no;
-- =====================================================================
alter table public.employee_details add column if not exists esic_no text;

create or replace function public.admin_set_esic_no(p_user uuid, p_no text)
returns void
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._require_admin();
begin
  if coalesce(trim(p_no), '') <> '' and trim(p_no) !~ '^[0-9]{10,17}$' then raise exception 'The ESIC IP number must be 10 to 17 digits'; end if;
  update public.employee_details set esic_no = nullif(trim(coalesce(p_no, '')), '') where user_id = p_user;
  perform public._audit('ESIC_NO', p_user::text || ' ESIC IP no. ' || coalesce(nullif(trim(coalesce(p_no, '')), ''), 'cleared'));
end $$;
revoke all on function public.admin_set_esic_no(uuid, text) from public, anon;
grant execute on function public.admin_set_esic_no(uuid, text) to authenticated;
notify pgrst, 'reload schema';
