-- Damage photos: everyone at the store can SEE them (shop, sales, finance), not just the area manager.
-- Only the area manager can still delete. Only works at stores where Setup > Damage photos is ON.
-- Adds two read-only functions; changes no data and no other functions. Safe to run again.
-- Undo: sql/damage-photos-everyone-undo.sql (phones go back to "only the area manager can see these").

begin;

-- List of a store's photos (no pictures, so it's fast).
create or replace function public.ts_damage_store_list(st text, since timestamptz)
returns jsonb language sql security definer stable set search_path = public as $$
  select coalesce((select jsonb_agg(jsonb_build_object('id', id, 'item_id', item_id, 'kind', kind, 'store', store,
      'label', label, 'note', note, 'taken_by', taken_by, 'created_at', created_at) order by created_at desc)
    from (select * from damage_photos
          where store = st and created_at >= since
            and exists (select 1 from feature_flags f where f.key = 'photos:' || st and f.enabled)
          order by created_at desc limit 1000) d), '[]'::jsonb);
$$;

-- One picture, only from that store.
create or replace function public.ts_damage_store_img(st text, pid uuid)
returns text language sql security definer stable set search_path = public as $$
  select img from damage_photos
  where id = pid and store = st
    and exists (select 1 from feature_flags f where f.key = 'photos:' || st and f.enabled);
$$;

grant execute on function public.ts_damage_store_list(text, timestamptz), public.ts_damage_store_img(text, uuid) to anon, authenticated;

commit;
