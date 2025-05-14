create or replace function to_signed_int(bigint) returns int language sql return  case when $1<2^31 then $1 else (($1 % (2^31-1)::bigint)::int - 2^31 -1) end;

create or replace function xid_freqs(oid) returns int[] language sql begin atomic;  select array_agg(to_signed_int(unnest)) from unnest(pg_stat_get_dead_tuples_xid_freqs($1)::text::bigint[]); end;

\set tt test_add_dead_tuples

create table :tt(a int);

insert into :tt values(1);
update :tt set a=a; select pg_stat_force_next_flush();
update :tt set a=a; select pg_stat_force_next_flush();
update :tt set a=a; select pg_stat_force_next_flush();
update :tt set a=a; select pg_stat_force_next_flush();

select pg_stat_get_dead_tuples_xid_freqs(:'tt'::regclass);

-- on fifth update, should merge one bin
update :tt set a=a; select pg_stat_force_next_flush();


select xid_freqs(:'tt'::regclass);

--select pg_stat_get_dead_tuples_xid_freqs(:'tt'::regclass),
--       pg_stat_get_dead_tuples_xid_bounds(:'tt'::regclass),
--       pg_stat_get_dead_tuples(:'tt'::regclass);

drop table :tt;

\set tt test_add_and_prune_dead_tuples

create table :tt(a int);

insert into :tt select generate_series(1,200);
update :tt set a=a; select pg_stat_force_next_flush();
update :tt set a=a; select pg_stat_force_next_flush();
update :tt set a=a; select pg_stat_force_next_flush();
update :tt set a=a; select pg_stat_force_next_flush();

select xid_freqs(:'tt'::regclass),
       pg_stat_get_dead_tuples(:'tt'::regclass);

--drop table :tt;
--drop function to_signed_int;
--drop function xid_freqs;
