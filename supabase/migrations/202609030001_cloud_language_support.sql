-- Keep cloud language validation aligned with the Android app.
-- The original sync schema accepted English and Telugu only, which caused
-- Hindi business updates to be rejected during offline synchronization.
alter table public.businesses
  drop constraint if exists businesses_preferred_language_check;

alter table public.businesses
  add constraint businesses_preferred_language_check
  check (preferred_language in ('en', 'hi', 'te'));
