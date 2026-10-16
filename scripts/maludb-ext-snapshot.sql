-- maludb-ext-snapshot.sql — catalog snapshot of maludb_core extension members.
--
-- Purpose: release-gate equivalence check between a FRESH install of the
-- cumulative bundle (CREATE EXTENSION maludb_core) and an UPGRADED database
-- (CREATE EXTENSION ... VERSION '0.1.0' + ALTER EXTENSION ... UPDATE).
-- pg_dump --schema-only excludes extension member objects, so this snapshot
-- is catalog-based. Run identically against both databases and diff:
--
--   psql -X -q -d <fresh_db>    -f scripts/maludb-ext-snapshot.sql > /tmp/snap-fresh.txt
--   psql -X -q -d <upgraded_db> -f scripts/maludb-ext-snapshot.sql > /tmp/snap-upg.txt
--   diff -u /tmp/snap-fresh.txt /tmp/snap-upg.txt
--
-- Acceptance: empty diff above the INFORMATIONAL section. Notes:
--   * no raw OIDs anywhere (regclass/regrole/regprocedure/pg_describe_object);
--   * sequences exclude last_value; content hashes exclude timestamp columns;
--   * constraints are ordered by table+definition because auto-generated
--     names may differ benignly between bundle and chain;
--   * physical column order (upgrade-appended columns) is reported in the
--     final INFORMATIONAL section only.
\set ON_ERROR_STOP on
\pset pager off
\pset format unaligned
\pset tuples_only on
SET search_path = '';

CREATE TEMP TABLE ext_member AS
SELECT d.classid, d.objid, d.classid::pg_catalog.regclass::pg_catalog.text AS catalog
FROM pg_catalog.pg_depend d
JOIN pg_catalog.pg_extension e ON e.oid = d.refobjid
WHERE d.refclassid = 'pg_catalog.pg_extension'::pg_catalog.regclass
  AND e.extname = 'maludb_core' AND d.deptype = 'e';

SELECT '=== extension ===';
SELECT e.extname, e.extversion, n.nspname
FROM pg_catalog.pg_extension e JOIN pg_catalog.pg_namespace n ON n.oid = e.extnamespace
WHERE e.extname = 'maludb_core';

SELECT '=== member counts by catalog ===';
SELECT catalog, pg_catalog.count(*) FROM ext_member GROUP BY catalog ORDER BY catalog COLLATE "C";

SELECT '=== all members (OID-free identities; catches operators/casts/opclasses/types) ===';
SELECT pg_catalog.pg_describe_object(classid, objid, 0) FROM ext_member
ORDER BY pg_catalog.pg_describe_object(classid, objid, 0) COLLATE "C";

SELECT '=== relations (kind, RLS, ACL) ===';
SELECT n.nspname || '.' || c.relname, c.relkind, c.relpersistence,
       c.relrowsecurity, c.relforcerowsecurity,
       pg_catalog.array_to_string(c.reloptions, ','),
       (SELECT pg_catalog.string_agg(
                 CASE WHEN a.grantee = 0 THEN 'PUBLIC'
                      ELSE a.grantee::pg_catalog.regrole::pg_catalog.text END
                 || '=' || a.privilege_type
                 || CASE WHEN a.is_grantable THEN '*' ELSE '' END, ','
                 ORDER BY CASE WHEN a.grantee = 0 THEN 'PUBLIC'
                               ELSE a.grantee::pg_catalog.regrole::pg_catalog.text END,
                          a.privilege_type)
          FROM pg_catalog.aclexplode(c.relacl) a)
FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
WHERE c.oid IN (SELECT objid FROM ext_member WHERE catalog = 'pg_class')
ORDER BY (n.nspname || '.' || c.relname) COLLATE "C";

SELECT '=== columns (sorted by name; physical order reported separately at end) ===';
SELECT n.nspname || '.' || c.relname, a.attname,
       pg_catalog.format_type(a.atttypid, a.atttypmod), a.attnotnull,
       COALESCE(pg_catalog.pg_get_expr(ad.adbin, ad.adrelid), ''),
       a.attidentity, a.attgenerated
FROM pg_catalog.pg_attribute a
JOIN pg_catalog.pg_class c ON c.oid = a.attrelid
JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
LEFT JOIN pg_catalog.pg_attrdef ad ON ad.adrelid = a.attrelid AND ad.adnum = a.attnum
WHERE (c.oid IN (SELECT objid FROM ext_member WHERE catalog = 'pg_class')
       OR c.reltype IN (SELECT objid FROM ext_member WHERE catalog = 'pg_type'))
  AND a.attnum > 0 AND NOT a.attisdropped
ORDER BY (n.nspname || '.' || c.relname) COLLATE "C", a.attname COLLATE "C";

SELECT '=== indexes ===';
SELECT pg_catalog.pg_get_indexdef(i.indexrelid)
FROM pg_catalog.pg_index i
WHERE i.indrelid IN (SELECT objid FROM ext_member WHERE catalog = 'pg_class')
ORDER BY pg_catalog.pg_get_indexdef(i.indexrelid) COLLATE "C";

SELECT '=== constraints (ordered by table+definition: auto-generated names may differ) ===';
SELECT con.conrelid::pg_catalog.regclass::pg_catalog.text,
       pg_catalog.pg_get_constraintdef(con.oid), con.conname
FROM pg_catalog.pg_constraint con
WHERE con.conrelid IN (SELECT objid FROM ext_member WHERE catalog = 'pg_class')
ORDER BY con.conrelid::pg_catalog.regclass::pg_catalog.text COLLATE "C",
         pg_catalog.pg_get_constraintdef(con.oid) COLLATE "C";

SELECT '=== triggers ===';
SELECT t.tgrelid::pg_catalog.regclass::pg_catalog.text, t.tgname,
       pg_catalog.pg_get_triggerdef(t.oid)
FROM pg_catalog.pg_trigger t
WHERE NOT t.tgisinternal
  AND t.tgrelid IN (SELECT objid FROM ext_member WHERE catalog = 'pg_class')
ORDER BY t.tgrelid::pg_catalog.regclass::pg_catalog.text COLLATE "C",
         t.tgname COLLATE "C";

SELECT '=== policies ===';
SELECT pol.polrelid::pg_catalog.regclass::pg_catalog.text, pol.polname, pol.polcmd,
       pol.polpermissive,
       (SELECT pg_catalog.string_agg(
                 CASE WHEN r = 0 THEN 'PUBLIC' ELSE r::pg_catalog.regrole::pg_catalog.text END,
                 ',' ORDER BY CASE WHEN r = 0 THEN 'PUBLIC' ELSE r::pg_catalog.regrole::pg_catalog.text END)
          FROM pg_catalog.unnest(pol.polroles) r),
       COALESCE(pg_catalog.pg_get_expr(pol.polqual, pol.polrelid), ''),
       COALESCE(pg_catalog.pg_get_expr(pol.polwithcheck, pol.polrelid), '')
FROM pg_catalog.pg_policy pol
WHERE pol.polrelid IN (SELECT objid FROM ext_member WHERE catalog = 'pg_class')
ORDER BY pol.polrelid::pg_catalog.regclass::pg_catalog.text COLLATE "C",
         pol.polname COLLATE "C";

SELECT '=== function properties + ACLs ===';
SELECT p.oid::pg_catalog.regprocedure::pg_catalog.text, p.prokind, p.prosecdef,
       p.provolatile, p.proparallel, p.proleakproof, p.proisstrict,
       pg_catalog.array_to_string(p.proconfig, ','),
       (SELECT pg_catalog.string_agg(
                 CASE WHEN a.grantee = 0 THEN 'PUBLIC'
                      ELSE a.grantee::pg_catalog.regrole::pg_catalog.text END
                 || '=' || a.privilege_type, ','
                 ORDER BY CASE WHEN a.grantee = 0 THEN 'PUBLIC'
                               ELSE a.grantee::pg_catalog.regrole::pg_catalog.text END)
          FROM pg_catalog.aclexplode(p.proacl) a)
FROM pg_catalog.pg_proc p
WHERE p.oid IN (SELECT objid FROM ext_member WHERE catalog = 'pg_proc')
ORDER BY p.oid::pg_catalog.regprocedure::pg_catalog.text COLLATE "C";

SELECT '=== function bodies (aggregates excluded: pg_get_functiondef cannot render them) ===';
SELECT pg_catalog.pg_get_functiondef(p.oid)
FROM pg_catalog.pg_proc p
WHERE p.oid IN (SELECT objid FROM ext_member WHERE catalog = 'pg_proc') AND p.prokind <> 'a'
ORDER BY p.oid::pg_catalog.regprocedure::pg_catalog.text COLLATE "C";

SELECT '=== views ===';
SELECT n.nspname || '.' || c.relname, pg_catalog.pg_get_viewdef(c.oid)
FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('v','m')
  AND c.oid IN (SELECT objid FROM ext_member WHERE catalog = 'pg_class')
ORDER BY (n.nspname || '.' || c.relname) COLLATE "C";

SELECT '=== sequences (last_value deliberately excluded) ===';
SELECT s.schemaname || '.' || s.sequencename, s.data_type::pg_catalog.text,
       s.start_value, s.min_value, s.max_value, s.increment_by, s.cycle, s.cache_size
FROM pg_catalog.pg_sequences s
JOIN pg_catalog.pg_class c ON c.relname = s.sequencename
JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace AND n.nspname = s.schemaname
WHERE c.oid IN (SELECT objid FROM ext_member WHERE catalog = 'pg_class')
ORDER BY (s.schemaname || '.' || s.sequencename) COLLATE "C";

SELECT '=== comments ===';
SELECT pg_catalog.pg_describe_object(m.classid, m.objid, 0), ds.description
FROM ext_member m
JOIN pg_catalog.pg_description ds
  ON ds.classoid = m.classid AND ds.objoid = m.objid AND ds.objsubid = 0
ORDER BY pg_catalog.pg_describe_object(m.classid, m.objid, 0) COLLATE "C";

SELECT '=== seed-data row counts per extension table ===';
CREATE TEMP TABLE rowcounts(rel pg_catalog.text, n pg_catalog.int8);
DO $do$
DECLARE r record;
BEGIN
  FOR r IN SELECT c.oid::pg_catalog.regclass AS rel FROM pg_catalog.pg_class c
            WHERE c.relkind = 'r'
              AND c.oid IN (SELECT objid FROM ext_member WHERE catalog = 'pg_class')
  LOOP
    EXECUTE pg_catalog.format('INSERT INTO rowcounts SELECT %L, pg_catalog.count(*) FROM %s',
                              r.rel::pg_catalog.text, r.rel);
  END LOOP;
END $do$;
SELECT rel, n FROM rowcounts ORDER BY rel COLLATE "C";

SELECT '=== seed-data content hashes (timestamp/tz columns excluded; install-time crypto material excluded) ===';
CREATE TEMP TABLE content_hash(rel pg_catalog.text, hash pg_catalog.text);
DO $do$
DECLARE r record; collist pg_catalog.text;
BEGIN
  FOR r IN SELECT c.oid, c.oid::pg_catalog.regclass::pg_catalog.text AS rel
             FROM pg_catalog.pg_class c
            WHERE c.relkind = 'r'
              AND c.oid IN (SELECT objid FROM ext_member WHERE catalog = 'pg_class')
              -- random key material generated at install time differs between
              -- any two databases by design; row counts still compare above
              AND c.relname NOT IN ('malu$auth_pepper', 'malu$secret_master_key')
  LOOP
    SELECT pg_catalog.string_agg(pg_catalog.quote_ident(a.attname), ',' ORDER BY a.attname)
      INTO collist
      FROM pg_catalog.pg_attribute a
     WHERE a.attrelid = r.oid AND a.attnum > 0 AND NOT a.attisdropped
       AND a.atttypid NOT IN ('pg_catalog.timestamptz'::pg_catalog.regtype,
                              'pg_catalog.timestamp'::pg_catalog.regtype);
    CONTINUE WHEN collist IS NULL;
    EXECUTE pg_catalog.format(
      'INSERT INTO content_hash
         SELECT %L, pg_catalog.md5(COALESCE(pg_catalog.string_agg(t::pg_catalog.text, E''\n'' ORDER BY t::pg_catalog.text), ''''))
           FROM (SELECT ROW(%s) FROM %I.%I) AS s(t)',
      r.rel, collist,
      (SELECT n.nspname FROM pg_catalog.pg_namespace n
        JOIN pg_catalog.pg_class c2 ON c2.relnamespace = n.oid WHERE c2.oid = r.oid),
      (SELECT c2.relname FROM pg_catalog.pg_class c2 WHERE c2.oid = r.oid));
  END LOOP;
END $do$;
SELECT rel, hash FROM content_hash ORDER BY rel COLLATE "C";

SELECT '=== key registries by natural key (sequence-id-free) ===';
SELECT subject_type, display_name, sort_order, system_defined
FROM maludb_core."malu$svpor_subject_type" ORDER BY subject_type COLLATE "C";
SELECT verb_type, display_name, semantic_class, sort_order
FROM maludb_core."malu$svpor_verb_type" ORDER BY verb_type COLLATE "C";
SELECT s.server_name, t.tool_name
FROM maludb_core."malu$mc2db_tool" t JOIN maludb_core."malu$mc2db_server" s USING (server_id)
ORDER BY s.server_name COLLATE "C", t.tool_name COLLATE "C";

SELECT '=== INFORMATIONAL: physical column order (upgrade-appended columns differ here benignly) ===';
SELECT n.nspname || '.' || c.relname, a.attnum, a.attname
FROM pg_catalog.pg_attribute a
JOIN pg_catalog.pg_class c ON c.oid = a.attrelid
JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
WHERE c.oid IN (SELECT objid FROM ext_member WHERE catalog = 'pg_class')
  AND a.attnum > 0 AND NOT a.attisdropped
ORDER BY (n.nspname || '.' || c.relname) COLLATE "C", a.attnum;
