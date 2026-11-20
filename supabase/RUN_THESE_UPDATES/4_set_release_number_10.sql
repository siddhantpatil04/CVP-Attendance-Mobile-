-- Sets the "Current release" number on App Updates to 10 (it shows #33 now).
-- FOR REVIEW: nothing has been run. Run it yourself in Supabase -> SQL Editor only if you agree.
--
-- NOTE: phones and desktops remember the highest release number they have seen (33). A phone signs out and
-- reloads only when the published number is HIGHER than the one it remembers. After this change the next
-- "Publish Update" will be #11, which is lower than 33, so devices that already saw 33 will NOT sign out
-- until the number passes 33 again. If you want every device to follow the new numbering, ask me to change
-- the app so that it signs out when the number is DIFFERENT (not only higher) before you run this.

update public.app_release
   set release = 10
 where id = 1;

select release, note, published_at from public.app_release where id = 1;
