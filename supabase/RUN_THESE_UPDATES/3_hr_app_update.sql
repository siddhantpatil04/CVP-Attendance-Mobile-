-- =====================================================================
-- HR CAN PUBLISH APP UPDATES (same as Admin)
-- Run in Supabase Dashboard -> SQL Editor -> New query -> Run.  Safe to run again.
-- Run ONLY this file. Do NOT run the whole cvp_attendance_schema.sql again.
-- =====================================================================
create or replace function public.admin_publish_update(p_note text default null)
returns public.app_release
language plpgsql security definer set search_path = public as $$
declare me public.profiles := public._require_admin(); r public.app_release;
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

notify pgrst, 'reload schema';
