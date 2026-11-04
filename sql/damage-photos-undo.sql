-- Removes damage photos completely (all saved photos are deleted). The board itself is not touched.
-- To just stop them at a store, use Setup > Damage photos > Turn off instead.
select cron.unschedule('ts-damage-cleanup') where exists (select 1 from cron.job where jobname = 'ts-damage-cleanup');

begin;
drop function if exists public.ts_damage_counts(text);
drop function if exists public.ts_damage_list(text, timestamptz);
drop function if exists public.ts_damage_img(text, uuid);
drop function if exists public.ts_damage_del(text, uuid);
drop table if exists public.damage_photos;
commit;
