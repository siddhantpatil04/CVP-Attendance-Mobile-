-- =====================================================================
-- SALARY FORMULAS (simple): the formulas of Basic, HRA, Other, PF, ESIC, PT (+ added rows) are typed text and apply FROM a month.
--
-- ONE table  salary_formulas ( apply_from date = the 1st of a month, formulas jsonb ).
-- A salary month uses the row with the latest apply_from on or before it. A row can never start in a finalized month, so a finalized
-- (or any earlier) month never changes. The first row (apply_from 2000-01-01) = today's formulas of wages.ts.
--
-- This file:
--   0. removes the objects of the earlier, more complicated design (salary_formula_sets and its functions) if they exist
--   1. creates   salary_formulas
--   2. creates   formulas_for_month(month)       -> the formulas valid for that month (any signed-in user)
--   3. creates   save_salary_formulas(apply_from, formulas)   -> Admin only, checked, Audit Trail 'SALARY_FORMULAS_SAVE'
--   4. RLS       Admin / HR read; nobody writes directly
-- It does NOT touch attendance, check-in / check-out, leave, paid / unpaid days, the Finalize lock or any existing row.
-- The formula TEXT is checked again by the app's safe calculator (no eval, no SQL): only the words, numbers and functions it allows.
-- Needs payroll_months.sql first.
--
-- BACK UP FIRST.   Supabase -> SQL Editor -> paste the WHOLE file -> Run.   Safe to run again.   Undo: see the UNDO block at the end of this file
-- =====================================================================

-- 0. the earlier design (if it was ever run)
drop function if exists public.cancel_salary_formulas(bigint);
drop function if exists public.save_salary_formulas(date, jsonb, text);
drop function if exists public._salary_formulas_diff(jsonb, jsonb);
drop table if exists public.salary_formula_sets;

-- 1. the table -------------------------------------------------------------
create table if not exists public.salary_formulas (
  id          bigint generated always as identity primary key,
  apply_from  date  not null unique check (extract(day from apply_from) = 1),   -- always the 1st of a month
  formulas    jsonb not null,                                                    -- { "items": [ {code, name, type: builtin|earning|deduction, formula} ] }
  created_by  uuid  references public.profiles(id) on delete set null,
  created_at  timestamptz not null default now()
);

alter table public.salary_formulas enable row level security;
drop policy if exists salary_formulas_read on public.salary_formulas;
create policy salary_formulas_read on public.salary_formulas for select to authenticated using (public.is_full_admin());
revoke all on public.salary_formulas from anon, authenticated;
grant select on public.salary_formulas to authenticated;

-- Starting formulas = today's wages.ts (the same numbers for April - November 2026)
insert into public.salary_formulas (apply_from, formulas)
select date '2000-01-01', jsonb_build_object('items', jsonb_build_array(
  jsonb_build_object('code', 'BASIC', 'name', 'Basic',            'type', 'builtin', 'formula', 'ROUND(EARNED * 50%)'),
  jsonb_build_object('code', 'HRA',   'name', 'HRA',              'type', 'builtin', 'formula', 'ROUND(BASIC * 40%)'),
  jsonb_build_object('code', 'OTHER', 'name', 'Other allowances', 'type', 'builtin', 'formula', 'ROUND(BASIC * 60%)'),
  jsonb_build_object('code', 'PF',    'name', 'PF',               'type', 'builtin', 'formula', 'IF(SALARY > 0, ROUND(MIN(MAX(BASIC, ROUND(GROSS / 2)), 25000) * 12%), 0)'),
  jsonb_build_object('code', 'ESIC',  'name', 'ESIC',             'type', 'builtin', 'formula', 'IF(SALARY > 0, IF(SALARY <= 21000, IF(GROSS > 0, ROUNDUP(GROSS * 0.75%), 0), 0), 0)'),
  jsonb_build_object('code', 'PT',    'name', 'Professional Tax', 'type', 'builtin', 'formula', 'IF(GROSS <= 0, 0, IF(GENDER_F = 1, IF(GROSS <= 25000, 0, IF(MONTH = 2, 300, 200)), IF(GROSS <= 7500, 0, IF(GROSS <= 10000, 175, IF(MONTH = 2, 300, 200)))))')))
where not exists (select 1 from public.salary_formulas);

-- 2. the formulas of a month ---------------------------------------------------
create or replace function public.formulas_for_month(p_month date)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare s public.salary_formulas;
begin
  perform public._require_active();
  select * into s from public.salary_formulas
   where apply_from <= date_trunc('month', p_month::timestamp)::date
   order by apply_from desc limit 1;
  if s.id is null then return null; end if;
  return jsonb_build_object('apply_from', s.apply_from, 'formulas', s.formulas);
end $$;
revoke all on function public.formulas_for_month(date) from public, anon;
grant execute on function public.formulas_for_month(date) to authenticated;

-- 3. save (Admin only) ----------------------------------------------------------
-- Saving the SAME month again replaces that (not yet finalized) row. A month in the past that is finalized is refused.
create or replace function public.save_salary_formulas(p_apply_from date, p_formulas jsonb)
returns public.salary_formulas
language plpgsql security definer set search_path = public as $$
declare
  me       public.profiles := public._require_active();
  last_fin date;
  newrow   public.salary_formulas;
  it       jsonb;
  c        text;
  codes    text[] := '{}';
  builtin  constant text[] := array['BASIC', 'HRA', 'OTHER', 'PF', 'ESIC', 'PT'];
  reserved constant text[] := array['SALARY', 'EARNED', 'PAID_DAYS', 'MONTH_DAYS', 'MONTH', 'GENDER_F', 'UNPAID_DAYS', 'PRESENT_DAYS', 'OT_HOURS',
    'YEARS_OF_SERVICE', 'SITE_EMPLOYEE', 'PF_MEMBER', 'BASIC', 'HRA', 'OTHER', 'GROSS', 'PF', 'ESIC', 'PT', 'NET', 'ADVANCE', 'TRUE', 'FALSE',
    'IF', 'MIN', 'MAX', 'ROUND', 'ROUNDUP', 'ROUNDDOWN', 'AND', 'OR', 'NOT'];
  old_txt  text;
begin
  if me.role <> 'Admin' then raise exception 'Only an Admin can change the salary formulas' using errcode = '42501'; end if;
  if p_apply_from is null or extract(day from p_apply_from) <> 1 then raise exception 'Apply from must be the 1st of a month'; end if;
  if p_apply_from <= date '2000-01-01' then raise exception 'Choose a real month'; end if;

  select max(make_date(year, month, 1)) into last_fin from public.payroll_months;
  if last_fin is not null and p_apply_from <= last_fin then
    raise exception '% is finalized - choose % or later', to_char(last_fin, 'FMMonth YYYY'), to_char(last_fin + interval '1 month', 'FMMonth YYYY');
  end if;

  if p_formulas is null or jsonb_typeof(p_formulas -> 'items') <> 'array' then raise exception 'The formulas are missing'; end if;
  for it in select value from jsonb_array_elements(p_formulas -> 'items') loop
    c := it ->> 'code';
    if c is null or c !~ '^[A-Z0-9_]{2,20}$' then raise exception 'Formula code "%" must be 2-20 characters: A-Z, 0-9 or _', coalesce(c, ''); end if;
    if c = any (codes) then raise exception 'Formula code % is used twice', c; end if;
    codes := codes || c;
    if coalesce(trim(it ->> 'formula'), '') = '' then raise exception 'The formula of % is empty', c; end if;
    if length(it ->> 'formula') > 500 then raise exception 'The formula of % is longer than 500 characters', c; end if;
    if (it ->> 'type') = 'builtin' then
      if not (c = any (builtin)) then raise exception '% is not a built-in row', c; end if;
    else
      if (it ->> 'type') not in ('earning', 'deduction') then raise exception 'Row %: type must be earning or deduction', c; end if;
      if c = any (reserved) then raise exception '% is a reserved name', c; end if;
      if coalesce(it ->> 'name', '') = '' then raise exception 'Row %: enter a name', c; end if;
    end if;
  end loop;
  foreach c in array builtin loop
    if not (c = any (codes)) then raise exception 'The row % cannot be removed', c; end if;
  end loop;

  select (formulas ->> 'items') into old_txt from public.salary_formulas where apply_from <= p_apply_from order by apply_from desc limit 1;

  insert into public.salary_formulas (apply_from, formulas, created_by) values (p_apply_from, p_formulas, me.id)
  on conflict (apply_from) do update set formulas = excluded.formulas, created_by = excluded.created_by, created_at = now()
  returning * into newrow;

  perform public._audit('SALARY_FORMULAS_SAVE', 'Applies from ' || to_char(p_apply_from, 'FMMonth YYYY')
    || case when old_txt is distinct from (p_formulas ->> 'items') then ': formulas changed' else ': no change' end
    || ' | ' || left(p_formulas ->> 'items', 1500));
  return newrow;
end $$;
revoke all on function public.save_salary_formulas(date, jsonb) from public, anon;
grant execute on function public.save_salary_formulas(date, jsonb) to authenticated;

notify pgrst, 'reload schema';

-- CHECK after running:
--   select apply_from, jsonb_array_length(formulas -> 'items') from public.salary_formulas;   -- 2000-01-01, 6
--   select public.formulas_for_month(date '2026-11-01') ->> 'apply_from';                      -- 2000-01-01

-- =====================================================================
-- UNDO (rollback): this part is commented out so it does NOT run with the file. To remove the feature, select the lines below
-- (without the leading "-- "), paste them in the SQL Editor on their own and Run. All saved formula changes are lost.
-- Attendance, leave, salary history and finalized months are NOT touched. Old Audit Trail lines stay.
-- =====================================================================
-- drop function if exists public.save_salary_formulas(date, jsonb);
-- drop function if exists public.formulas_for_month(date);
-- drop table if exists public.salary_formulas;
-- notify pgrst, 'reload schema';
