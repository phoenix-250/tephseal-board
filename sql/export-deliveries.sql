-- Deliveries, last 90 days, one row per car (Results > Export > CSV)
with st as (
  select s->>'id' id, s->>'name' name
  from config c, jsonb_array_elements(c.data->'stores') s where c.id = 'settings'
), t as (
  select j.data d from jobs j
)
select
  coalesce(st.name, d->>'store')                                         as store,
  d->>'stock'                                                            as stock,
  concat_ws(' ', d->>'year', d->>'make', d->>'model')                    as vehicle,
  d->>'color'                                                            as color,
  d->>'salesperson'                                                      as salesperson,
  d->>'status'                                                           as status,
  array_to_string(array(select jsonb_array_elements_text(coalesce(d->'products','[]'))), ', ') as products,
  to_char(to_timestamp((d->>'createdAt')::bigint/1000) at time zone 'America/Denver', 'YYYY-MM-DD HH12:MI AM')   as sent_to_shop,
  to_char(to_timestamp((d->>'dueAt')::bigint/1000) at time zone 'America/Denver', 'YYYY-MM-DD HH12:MI AM')       as ready_by,
  to_char(to_timestamp((d->>'readyAt')::bigint/1000) at time zone 'America/Denver', 'YYYY-MM-DD HH12:MI AM')     as ready_at,
  to_char(to_timestamp((d->>'deliveredAt')::bigint/1000) at time zone 'America/Denver', 'YYYY-MM-DD HH12:MI AM') as delivered_at,
  round(((d->>'readyAt')::bigint - (d->>'createdAt')::bigint) / 60000.0) as turn_minutes,
  case when d->>'readyAt' is null then null
       when (d->>'readyAt')::bigint <= (d->>'dueAt')::bigint + 60000 then 'Yes' else 'No' end as on_time
from t left join st on st.id = d->>'store'
where (d->>'createdAt')::bigint > (extract(epoch from now() - interval '90 days') * 1000)
order by (d->>'createdAt')::bigint desc;
