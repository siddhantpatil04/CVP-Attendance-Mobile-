-- #####################################################################
-- SAFETY LOCK - read before you run
-- OLD patch, replaced by PART D / PART A of the main file. It puts back an older version of the increment function.
-- This script is NOT part of normal setup. To run it on purpose, DELETE the 'do $$ ... $$;' block below (the 3 lines after this comment).
-- #####################################################################
do $$ begin raise exception 'SAFETY LOCK: hr_can_increment.sql is a one-time script. Read it, then delete this lock block to run it.'; end $$;

-- HR CAN ADD SALARY INCREMENTS (same as Admin). Run this one small file in the Supabase SQL Editor (copy all, then Run). Safe to run again.
-- Needs salary_management.sql to have been run before.

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

notify pgrst, 'reload schema';
