-- =====================================================================
-- DAILY REPORT TRANSLATION (Marathi / Hindi -> English, for Admin)
--
-- daily_report_sites.translations (jsonb): for each translated field it keeps
--            { "<field>": { "lang": "mr", "en": "<automatic English>", "src": "<original text that was translated>",
--                           "corrected_en": "<Admin's correction>", "corrected_by": "<name>", "corrected_at": "<time>" } }
--         The text the employee typed stays in the normal column (sub_work, work_going_on, ...): it is NEVER overwritten.
--         The English is written by the Edge Function "translate-report" (service role); Admin / HR correct it with admin_correct_translation().
--
-- ONE small, additive file.  Safe to run again.  No safety lock.  No table is dropped and no data is deleted.
-- Do NOT edit or run cvp_attendance_schema.sql for this.   BACK UP THE DATABASE FIRST.
-- Supabase -> SQL Editor -> paste the WHOLE file -> Run.
-- Then deploy the function:  supabase functions deploy translate-report
--                            supabase secrets set GOOGLE_TRANSLATE_API_KEY=<your key>     (the key lives ONLY there)
-- =====================================================================

-- Translation columns ---------------------------------------------------------------------------------------------------------
alter table public.daily_report_sites add column if not exists translations jsonb not null default '{}'::jsonb;

-- calls of the translation function (a simple rate limit: at most 30 calls per user per minute)
create table if not exists public.translate_usage (
  id      bigint generated always as identity primary key,
  user_id uuid not null,
  at      timestamptz not null default now()
);
create index if not exists translate_usage_idx on public.translate_usage (user_id, at desc);
alter table public.translate_usage enable row level security;      -- no policy: only the service role (the function) can use it
revoke all on public.translate_usage from anon, authenticated;

-- Admin / HR: save a corrected English text for one field of one site entry (the original and the automatic English stay)
create or replace function public.admin_correct_translation(p_site_row bigint, p_field text, p_text text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me  public.profiles := public._require_admin();
  cur jsonb;
  v_text text := nullif(trim(coalesce(p_text, '')), '');
begin
  if p_field is null or p_field not in ('sub_work', 'work_going_on', 'work_description', 'comment_1', 'comment_2', 'comment_3', 'remarks') then
    raise exception 'This field cannot be translated';
  end if;
  if v_text is null then raise exception 'Write the corrected English text'; end if;
  select translations into cur from public.daily_report_sites where id = p_site_row for update;
  if cur is null then raise exception 'Report entry not found'; end if;
  if not (cur ? p_field) then raise exception 'There is no automatic translation for this field'; end if;
  cur := jsonb_set(cur, array[p_field],
           (cur -> p_field) || jsonb_build_object('corrected_en', v_text, 'corrected_by', me.full_name, 'corrected_at', now()));
  update public.daily_report_sites set translations = cur where id = p_site_row;
  perform public._audit('DAILY_REPORT_TRANSLATION_CORRECTED', 'entry ' || p_site_row || ', ' || p_field || ' corrected by ' || me.full_name);
  return cur -> p_field;
end $$;
revoke all on function public.admin_correct_translation(bigint, text, text) from public, anon;
grant execute on function public.admin_correct_translation(bigint, text, text) to authenticated;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------
-- UNDO (only if needed; no data is deleted):
--   revoke execute on function public.admin_correct_translation(bigint, text, text) from authenticated;
-- ---------------------------------------------------------------------
