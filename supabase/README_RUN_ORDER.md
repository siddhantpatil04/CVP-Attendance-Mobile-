# Supabase SQL - run order notes

**Do not re-create `attendance_travel_guard`. Never run `cvp_attendance_schema.sql` on the live database.**

`cvp_attendance_schema.sql` (sections 23 and 25, and the `_backup` copies of it) creates the trigger `attendance_travel_guard`
that refuses the plain check-in / check-out of an employee with Travel Access ("Travel employees must use the travel check-in").
The travel check-in screen was removed from the app, so that trigger only blocks people. Running that file again brings it back.

If it ever comes back, run `9_working_hours_backend/00_remove_travel_checkin_block.sql` again (safe to repeat) and check:

```sql
select tgname from pg_trigger where tgname = 'attendance_travel_guard';   -- must return no rows
```

## Short order for the files that matter for check-in / check-out

1. `checkin_places_500m.sql`            (places within 500 m, hours rule)
2. `site_selfie_daily_report_checkout.sql`  (Daily Report before check-out; its travel-guard part is commented out: removed)
3. `foreign_checkin_checkout.sql`       (latest `check_in` / `check_out`)
4. `9_working_hours_backend/00_remove_travel_checkin_block.sql`   (last: removes the old block for good)

Everything else (leave, payroll, documents, profile photo ...) keeps its own file and order as before.
