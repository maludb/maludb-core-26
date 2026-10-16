\if :{?role}
\else
    \echo 'usage: psql -d DB -v role=ROLE [-v access=read|write|admin] -f sql/grant-memory-access.sql'
    \quit 1
\endif

\if :{?access}
\else
    \set access write
\endif

\echo Granting MaluDB :access access to role :role
SELECT maludb_core.grant_memory_access(:'role'::name, :'access') AS granted_role;
