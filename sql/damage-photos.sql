-- ============================================================================
-- Teph Seal delivery board: DAMAGE PHOTOS
--
-- Run once in Supabase: SQL Editor > New query > paste all of this > Run.
-- (If it warns about destructive operations, click "Run this query".)
-- Safe to run again. To remove it all, run damage-photos-undo.sql.
-- Needs secure-codes.sql to have been run first (it uses the area manager pass).
--
-- What it does:
--   * Detailers can add photos of damage they find on a delivery or used car.
--   * Phones can ADD photos but can never look at them.
--   * Only the area manager (with the PIN) can see them.
--   * Photos are deleted automatically after 90 days.
--   * Turned on per store in Setup > Damage photos. Off = board works as today.
--   * Never changes a car, a setting or another switch.
-- ============================================================================
begin;

create extension if not exists pg_cron;

create table if not exists public.damage_photos (
  id uuid primary key default gen_random_uuid(),
  item_id text not null,                 -- the delivery or used car id
  kind text not null,                    -- 'job' = delivery, 'used' = used car
  store text not null,
  label text not null default '',        -- e.g. "#A123 2026 Chevrolet Tahoe" (so the list works after the car is gone)
  note text not null default '',
  taken_by text not null default '',
  img text not null,                     -- small JPEG (made on the phone before upload)
  created_at timestamptz not null default now(),
  constraint damage_kind check (kind in ('job', 'used')),
  constraint damage_img check (img like 'data:image/jpeg;base64,%' and length(img) <= 900000),
  constraint damage_text check (length(note) <= 300 and length(label) <= 120 and length(taken_by) <= 60 and length(item_id) <= 80 and length(store) <= 80)
);
create index if not exists damage_photos_item on public.damage_photos (item_id);
create index if not exists damage_photos_store_at on public.damage_photos (store, created_at desc);

alter table public.damage_photos enable row level security;
revoke all on public.damage_photos from anon, authenticated;
grant insert on public.damage_photos to anon, authenticated;
drop policy if exists "board add damage photo" on public.damage_photos;
create policy "board add damage photo" on public.damage_photos for insert to anon, authenticated
  with check (store <> '' and item_id <> '' and created_at > now() - interval '5 minutes');

-- ---------- for phones: how many photos each car has (no pictures) ----------
create or replace function public.ts_damage_counts(st text)
returns jsonb language sql security definer stable set search_path = public as $$
  select coalesce(jsonb_object_agg(item_id, n), '{}'::jsonb) from (
    select item_id, count(*) n from damage_photos
    where store = st and created_at > now() - interval '95 days' group by item_id) q;
$$;

-- ---------- area manager only ----------
-- The list (no pictures, so it's fast).
create or replace function public.ts_damage_list(tok text, since timestamptz)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform ts_need_area(tok);
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'item_id', item_id, 'kind', kind, 'store', store,
      'label', label, 'note', note, 'taken_by', taken_by, 'created_at', created_at) order by created_at desc)
    from (select * from damage_photos where created_at >= since order by created_at desc limit 3000) d), '[]'::jsonb);
end $$;

-- One picture.
create or replace function public.ts_damage_img(tok text, pid uuid)
returns text language plpgsql security definer set search_path = public as $$
begin
  perform ts_need_area(tok);
  return (select img from damage_photos where id = pid);
end $$;

-- Remove one picture (added by mistake).
create or replace function public.ts_damage_del(tok text, pid uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform ts_need_area(tok);
  delete from damage_photos where id = pid;
end $$;

grant execute on function public.ts_damage_counts(text), public.ts_damage_list(text, timestamptz),
  public.ts_damage_img(text, uuid), public.ts_damage_del(text, uuid) to anon, authenticated;

commit;

-- ---------- delete photos older than 90 days, every night at 3am Utah time ----------
select cron.schedule('ts-damage-cleanup', '0 9 * * *', $$delete from public.damage_photos where created_at < now() - interval '90 days'$$);
