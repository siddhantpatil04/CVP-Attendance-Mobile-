-- FIX: register page says "These details do not match an employee record waiting for a login".
-- Run this WHOLE file once (copy all the text first, then Run). It changes only the two matching functions, no data.
-- The last result table tells you exactly why a number does or does not match. Change the number in the last query if needed.

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

drop function if exists public.check_registration_details(text, text);
create or replace function public.check_registration_details(p_channel text, p_contact text, p_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select public._registration_match2(lower(trim(coalesce(p_channel, ''))), p_contact, p_name) is not null
$$;
revoke execute on function public.check_registration_details(text, text, text) from public;
grant  execute on function public.check_registration_details(text, text, text) to anon, authenticated;
notify pgrst, 'reload schema';

-- RESULT: who has this number?  (matches = how many employees have it; it must be exactly 1)
select count(*) filter (where p.role = 'Employee' and p.active) as matches,
       string_agg(p.username || ' (' || p.role || case when p.active then '' else ', INACTIVE' end || ')', ', ') as people,
       public.check_registration_details('mobile', '7385349570', '') as register_page_will_accept
  from public.profiles p left join public.employee_details d on d.user_id = p.id
 where right(regexp_replace(coalesce(p.phone, ''), '\D', '', 'g'), 10) = '7385349570'
    or right(regexp_replace(coalesce(d.cell_no, ''), '\D', '', 'g'), 10) = '7385349570';
