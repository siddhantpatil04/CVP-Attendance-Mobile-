-- Deletes EVERY leave request that was approved by ghanshyamjangle25 (the "Demo: personal work" leaves on Approvals > Approved).
-- Run in the Supabase SQL editor. STEP 1 is a preview that changes nothing; STEP 2 deletes. It cannot be undone, so take a backup first
-- (Supabase > Database > Backups) if there is any doubt.
--
-- What goes with a deleted leave:
--   * its days in leave_day_alloc (cascade)  -> the days stop counting against the balance
--   * its rows in leave_ledger               -> deleted here too; otherwise the ledger would keep showing the days as used
--   * the Leave status in attendance / reports for those dates (they will show as Absent unless the employee punched in)

-- ---------- STEP 1: PREVIEW (run this first and check the list) ----------
select l.id, p.full_name, l.leave_type, l.from_day, l.to_day, l.status, l.reason
from public.leaves l
join public.profiles p on p.id = l.user_id
where l.reviewed_by = (select id from public.profiles where username = 'ghanshyamjangle25')
order by l.from_day;

-- ---------- STEP 2: DELETE (run only after the preview looks right) ----------
begin;

delete from public.leave_ledger
where leave_id in (select l.id from public.leaves l
                   where l.reviewed_by = (select id from public.profiles where username = 'ghanshyamjangle25'));

delete from public.leaves
where reviewed_by = (select id from public.profiles where username = 'ghanshyamjangle25');

-- check the number of deleted rows in the message, then:
commit;      -- or run  rollback;  instead to undo everything above
