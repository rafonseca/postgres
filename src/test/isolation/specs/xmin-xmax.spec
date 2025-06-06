setup
{
    create table t1 (a int primary key);
    create table t2 (counter int);
    insert into t2 (values (0));
}

teardown
{
    drop table t1;
}

session s1
step begin_s1 {begin;}
step insert_and_delete
{
    insert into t1 (values (1));
    delete from t1;
}
step commit_s1 {commit;}

session s2
step insert_when_possible
{
    insert into t1 (values (1));
    select counter from t2;
}

session timer
step increase_counter {update t2 set counter = counter + 1;}

# if s1 blocks s2, insert_when_possible returns counter=1, otherwise
# it returns counter=0
permutation begin_s1 insert_and_delete insert_when_possible increase_counter commit_s1
