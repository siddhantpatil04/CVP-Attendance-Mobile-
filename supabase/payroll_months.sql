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
