-- Undo damage-photos-everyone.sql: only the area manager can see damage photos again. No photos are deleted.
begin;
drop function if exists public.ts_damage_store_list(text, timestamptz);
drop function if exists public.ts_damage_store_img(text, uuid);
commit;
