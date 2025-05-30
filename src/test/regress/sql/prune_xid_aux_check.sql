
select pg_stat_force_next_flush();
analyze :tt; select relpages as tt_relpages from pg_class where relname=:'tt' \gset

select pg_stat_get_prune_xid_freqs(:'tt'::regclass)::text::text[];

with estimate as (
  select bounds, sum(freqs::int) over (order by bounds::int) estimated_cumsum
  from
    unnest( pg_stat_get_prune_xid_bounds(:'tt'::regclass)::text::text[])
      with ordinality as t1(bounds,ord)
  natural join
    unnest( pg_stat_get_prune_xid_freqs(:'tt'::regclass)::text::text[])
      with ordinality as t2(freqs,ord)
  order by bounds)
, pageinspect_vals as (
  select prune_xid
  from generate_series(1,:tt_relpages) as t(n),
       page_header(get_raw_page(:'tt', n-1))
  where prune_xid::text!='0')

select bounds,
       estimated_cumsum,
       (select count(*) from pageinspect_vals where prune_xid::text::int<=bounds::int)
from estimate
order by bounds::int;


