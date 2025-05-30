-- test UPDATE
create table t1(a int) with (autovacuum_enabled='off');
select pg_stat_get_prune_xid_freqs('t1'::regclass);

insert into t1 (select generate_series(1,10000));
select pg_stat_get_prune_xid_freqs('t1'::regclass);

update t1 set a=a+1 where a % 3 = 0;select pg_stat_force_next_flush();
update t1 set a=a+1 where a % 1 = 0;select pg_stat_force_next_flush();
update t1 set a=a+1 where a % 7 = 0;select pg_stat_force_next_flush();
update t1 set a=a+1 where a % 9 = 0;select pg_stat_force_next_flush();
select pg_stat_get_prune_xid_freqs('t1'::regclass);
update t1 set a=a+1 where a % 3 = 0;select pg_stat_force_next_flush();
update t1 set a=a+1 where a % 1 = 0;select pg_stat_force_next_flush();
update t1 set a=a+1 where a % 7 = 0;select pg_stat_force_next_flush();
update t1 set a=a+1 where a % 9 = 0;select pg_stat_force_next_flush();
select pg_stat_get_prune_xid_freqs('t1'::regclass);


\set tt t1
\ir prune_xid_aux_check.sql


-- test DELETE
create table t2(a int) with (autovacuum_enabled='off');
select pg_stat_get_prune_xid_freqs('t2'::regclass);

insert into t2 (select generate_series(1,10000));
select pg_stat_get_prune_xid_freqs('t2'::regclass);

delete from t2 where a%2=1;select pg_stat_force_next_flush();
select pg_stat_get_prune_xid_freqs('t2'::regclass);

\set tt t2
\ir prune_xid_aux_check.sql

delete from t2 where a%2=0;select pg_stat_force_next_flush();
select pg_stat_get_prune_xid_freqs('t2'::regclass);

insert into t2 (select generate_series(1,10000));
delete from t2; select pg_stat_force_next_flush();
select pg_stat_get_prune_xid_freqs('t2'::regclass);


\set tt t2
\ir prune_xid_aux_check.sql



-- test VACUUM
vacuum t1;
\set tt t1
\ir prune_xid_aux_check.sql

vacuum t2;
\set tt t2
\ir prune_xid_aux_check.sql



drop table t1;
drop table t2;
