\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.17.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.16.0 → 0.17.0
--
-- Stage 2 — Recursive Memory Detail Object addressing (S2-4).
--
-- Per requirements.md §3.7 Memory Detail Objects MUST be:
--   * addressable independently of their parent memory
--   * recursively containable
--   * depth-limited expansion supported at query time
--
-- The S2-1 table already has the structural recursion (parent_mdo_id
-- self-reference + memory_id/episode_id top-level attach). S2-4 adds:
--
--   * mdo_uri  — stable generated column "mdo://<schema>/<id>",
--                independent of parent. Unique index for O(log n)
--                URI → row lookup.
--   * mdo_resolve(uri)        → bigint
--   * mdo_ancestors(mdo_id)   → SETOF chain rows (0 = self, 1 = parent, ...)
--   * mdo_descendants(mdo_id, max_depth) → SETOF subtree rows with
--                ordinal_path. NULL max_depth = unbounded.
--   * mdo_root(mdo_id)        → (root_kind, root_id, mdo_chain bigint[])
--   * mdo_subtree_json(mdo_id, max_depth=5) → jsonb tree for API surfaces
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.17.0'::text $body$;

-- ---------------------------------------------------------------------
-- Stable URI column. Generated STORED so the value lives next to the
-- row data and lookups by URI hit a unique index.
-- ---------------------------------------------------------------------
ALTER TABLE malu$memory_detail_object
    ADD COLUMN mdo_uri text GENERATED ALWAYS AS
        ('mdo://' || owner_schema || '/' || mdo_id::text) STORED;

CREATE UNIQUE INDEX malu$mdo_uri_idx
    ON malu$memory_detail_object(mdo_uri);

-- ---------------------------------------------------------------------
-- mdo_resolve(uri) → bigint
--
-- Parses a mdo:// URI and returns the matching mdo_id (subject to RLS
-- on the underlying table). Raises invalid_parameter_value on
-- malformed URIs and no_data_found when the row isn't accessible.
-- ---------------------------------------------------------------------
CREATE FUNCTION mdo_resolve(p_uri text) RETURNS bigint
LANGUAGE plpgsql STABLE
AS $body$
DECLARE
    v_parts  text[];
    v_schema text;
    v_id     bigint;
BEGIN
    IF p_uri IS NULL OR p_uri !~ '^mdo://[^/]+/[0-9]+$' THEN
        RAISE EXCEPTION 'invalid mdo URI: %', COALESCE(p_uri, '<null>')
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    v_parts  := regexp_match(p_uri, '^mdo://([^/]+)/([0-9]+)$');
    v_schema := v_parts[1];
    v_id     := v_parts[2]::bigint;

    PERFORM 1 FROM malu$memory_detail_object
     WHERE mdo_id = v_id AND owner_schema = v_schema::name;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'MDO not found or not visible: %', p_uri
            USING ERRCODE = 'no_data_found';
    END IF;
    RETURN v_id;
END;
$body$;

-- ---------------------------------------------------------------------
-- mdo_ancestors(mdo_id) → SETOF (mdo_id, parent_mdo_id, depth,
--                                detail_kind, title)
--
-- Walks the parent chain upward. depth=0 is the input row itself;
-- depth=1 is its parent_mdo, etc. Terminates when parent_mdo_id is
-- NULL (top-level MDO attached directly to a memory or episode).
-- ---------------------------------------------------------------------
CREATE FUNCTION mdo_ancestors(p_mdo_id bigint) RETURNS TABLE (
    mdo_id        bigint,
    parent_mdo_id bigint,
    depth         integer,
    detail_kind   text,
    title         text
) LANGUAGE sql STABLE
AS $body$
    WITH RECURSIVE walk AS (
        SELECT m.mdo_id, m.parent_mdo_id, 0::integer AS depth,
               m.detail_kind, m.title
        FROM malu$memory_detail_object m
        WHERE m.mdo_id = p_mdo_id
        UNION ALL
        SELECT m.mdo_id, m.parent_mdo_id, w.depth + 1,
               m.detail_kind, m.title
        FROM walk w
        JOIN malu$memory_detail_object m ON m.mdo_id = w.parent_mdo_id
    )
    SELECT mdo_id, parent_mdo_id, depth, detail_kind, title
    FROM walk
    ORDER BY depth;
$body$;

-- ---------------------------------------------------------------------
-- mdo_descendants(mdo_id, max_depth=NULL) →
--     SETOF (mdo_id, parent_mdo_id, depth, ordinal_path,
--            detail_kind, title)
--
-- Walks the subtree downward. depth=0 is the input row itself.
-- ordinal_path is a dotted ordinal chain like "1.2.3"; NULLs in the
-- chain render as "?" so the path stays human-scannable. Pass
-- max_depth to bound the recursion (None = unbounded).
-- ---------------------------------------------------------------------
CREATE FUNCTION mdo_descendants(
    p_mdo_id    bigint,
    p_max_depth integer DEFAULT NULL
) RETURNS TABLE (
    mdo_id        bigint,
    parent_mdo_id bigint,
    depth         integer,
    ordinal_path  text,
    detail_kind   text,
    title         text
) LANGUAGE sql STABLE
AS $body$
    WITH RECURSIVE walk AS (
        SELECT m.mdo_id, m.parent_mdo_id, 0::integer AS depth,
               COALESCE(m.ordinal::text, '?') AS ordinal_path,
               m.detail_kind, m.title
        FROM malu$memory_detail_object m
        WHERE m.mdo_id = p_mdo_id
        UNION ALL
        SELECT c.mdo_id, c.parent_mdo_id, w.depth + 1,
               w.ordinal_path || '.' || COALESCE(c.ordinal::text, '?'),
               c.detail_kind, c.title
        FROM walk w
        JOIN malu$memory_detail_object c ON c.parent_mdo_id = w.mdo_id
        WHERE p_max_depth IS NULL OR w.depth + 1 <= p_max_depth
    )
    SELECT mdo_id, parent_mdo_id, depth, ordinal_path, detail_kind, title
    FROM walk
    ORDER BY ordinal_path, mdo_id;
$body$;

-- ---------------------------------------------------------------------
-- mdo_root(mdo_id) → (root_kind, root_id, mdo_chain bigint[])
--
-- Identifies the top-level owner of the chain (memory, episode_object,
-- or 'orphan' if the chain top has neither). mdo_chain is the
-- ordered ID list from root MDO down to leaf — `mdo_chain[1]` is the
-- top-most MDO. Useful for breadcrumbs and replay seed selection.
-- ---------------------------------------------------------------------
CREATE TYPE malu$mdo_root_result AS (
    root_kind  text,
    root_id    bigint,
    mdo_chain  bigint[]
);

CREATE FUNCTION mdo_root(p_mdo_id bigint) RETURNS malu$mdo_root_result
LANGUAGE plpgsql STABLE
AS $body$
DECLARE
    v_top_id    bigint;
    v_chain     bigint[];
    v_memory_id bigint;
    v_episode_id bigint;
    v_kind      text;
BEGIN
    SELECT array_agg(a.mdo_id ORDER BY a.depth DESC)
    INTO v_chain
    FROM mdo_ancestors(p_mdo_id) a;

    IF v_chain IS NULL OR array_length(v_chain, 1) IS NULL THEN
        RAISE EXCEPTION 'unknown mdo_id: %', p_mdo_id
            USING ERRCODE = 'no_data_found';
    END IF;

    v_top_id := v_chain[1];
    SELECT memory_id, episode_id
    INTO v_memory_id, v_episode_id
    FROM malu$memory_detail_object WHERE mdo_id = v_top_id;

    IF v_memory_id  IS NOT NULL THEN v_kind := 'memory';
    ELSIF v_episode_id IS NOT NULL THEN v_kind := 'episode_object';
    ELSE v_kind := 'orphan';
    END IF;

    RETURN ROW(
        v_kind,
        COALESCE(v_memory_id, v_episode_id),
        v_chain
    )::malu$mdo_root_result;
END;
$body$;

-- ---------------------------------------------------------------------
-- mdo_subtree_json(mdo_id, max_depth=5) → jsonb
--
-- Tree-shaped JSON for API surfaces. Each node carries:
--   { mdo_id, mdo_uri, detail_kind, ordinal, title, body_text,
--     body_jsonb, children: [...] }
--
-- Implemented bottom-up: assemble each node's `children` array first
-- (because PG's jsonb_object_agg / nested aggregation is awkward),
-- then walk up. Single recursive CTE plus a final aggregation pass.
-- ---------------------------------------------------------------------
CREATE FUNCTION mdo_subtree_json(
    p_mdo_id    bigint,
    p_max_depth integer DEFAULT 5
) RETURNS jsonb
LANGUAGE sql STABLE
AS $body$
    WITH RECURSIVE walk AS (
        SELECT m.mdo_id, m.parent_mdo_id, 0::integer AS depth,
               m.mdo_uri, m.detail_kind, m.ordinal, m.title,
               m.body_text, m.body_jsonb
        FROM malu$memory_detail_object m
        WHERE m.mdo_id = p_mdo_id
        UNION ALL
        SELECT c.mdo_id, c.parent_mdo_id, w.depth + 1,
               c.mdo_uri, c.detail_kind, c.ordinal, c.title,
               c.body_text, c.body_jsonb
        FROM walk w
        JOIN malu$memory_detail_object c ON c.parent_mdo_id = w.mdo_id
        WHERE w.depth + 1 <= p_max_depth
    ),
    rev AS (
        -- Build each node's JSON, including its children — process
        -- deepest first so children's JSON is ready when the parent
        -- aggregates them. Materialize via a CTE expression with a
        -- LATERAL subquery that re-walks the partial subtree.
        SELECT w.mdo_id, w.parent_mdo_id, w.depth,
               jsonb_build_object(
                   'mdo_id',      w.mdo_id,
                   'mdo_uri',     w.mdo_uri,
                   'detail_kind', w.detail_kind,
                   'ordinal',     w.ordinal,
                   'title',       w.title,
                   'body_text',   w.body_text,
                   'body_jsonb',  w.body_jsonb,
                   'children',    COALESCE(
                       (SELECT jsonb_agg(
                                   mdo_subtree_json(c.mdo_id, p_max_depth - w.depth - 1)
                                   ORDER BY c.ordinal NULLS LAST, c.mdo_id)
                        FROM malu$memory_detail_object c
                        WHERE c.parent_mdo_id = w.mdo_id
                          AND w.depth + 1 <= p_max_depth),
                       '[]'::jsonb)
               ) AS node_json
        FROM walk w
        WHERE w.depth = 0
    )
    SELECT node_json FROM rev LIMIT 1;
$body$;

GRANT EXECUTE ON FUNCTION
    mdo_resolve(text),
    mdo_ancestors(bigint),
    mdo_descendants(bigint, integer),
    mdo_root(bigint),
    mdo_subtree_json(bigint, integer)
TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
