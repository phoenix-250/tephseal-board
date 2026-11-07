-- Undo loaner-email-label.sql: late emails go back to saying USED for every used car.

do $patch$
declare
  src text;
  old_lbl text := $q$' <span style="color:#888">USED</span></td>'$q$;
  new_lbl text := $q$' <span style="color:#888">' || case when u.data->>'loaner' = 'true' then 'LOANER' else 'USED' end || '</span></td>'$q$;
begin
  src := pg_get_functiondef('public.ts_run_late_alerts()'::regprocedure);
  if position(new_lbl in src) = 0 then
    raise notice 'Nothing to undo.';
    return;
  end if;
  execute replace(src, new_lbl, old_lbl);
  raise notice 'Undone: late emails say USED again.';
end
$patch$;
