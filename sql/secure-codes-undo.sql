-- ============================================================================
-- UNDO for secure-codes.sql: puts the store codes and PIN back into the public
-- settings and reopens the tables the way the board used before.
-- Run in Supabase: SQL Editor > New query > paste > Run. Then refresh the board.
-- The private tables are left in place (harmless); the board just stops using them.
-- ============================================================================
begin;

update public.config c
set data = (c.data - 'secure' - 'hasPin') || jsonb_build_object(
  'masterPin', s.master_pin,
  'stores', coalesce((
    select jsonb_agg((st - 'hasCode') || jsonb_build_object(
             'code', coalesce(s.codes->>(st->>'id'), ''),
             'mcode', coalesce(s.mcodes->>(st->>'id'), '')) order by ord)
    from jsonb_array_elements(coalesce(c.data->'stores', '[]'::jsonb)) with ordinality as t(st, ord)
  ), '[]'::jsonb))
from public.board_secrets s
where c.id = 'settings' and s.id = 'settings';

do $$ declare p record; begin
  for p in select policyname, tablename from pg_policies
           where schemaname = 'public' and tablename in ('config', 'feature_flags', 'delivery_reviews') loop
    execute format('drop policy %I on public.%I', p.policyname, p.tablename);
  end loop;
end $$;
create policy "board open" on public.config for all to anon, authenticated using (true) with check (true);
create policy "board open" on public.feature_flags for all to anon, authenticated using (true) with check (true);
create policy "board open" on public.delivery_reviews for all to anon, authenticated using (true) with check (true);

commit;

select data from public.config where id = 'settings';
