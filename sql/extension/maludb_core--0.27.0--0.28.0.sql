\echo Use "ALTER EXTENSION maludb_core UPDATE TO '0.28.0'" to load this file. \quit

-- =====================================================================
-- maludb_core 0.27.0 → 0.28.0
--
-- Stage 4 — Graph traversal over relationship edges (S4-1).
--
-- Per requirements.md §9 Stage 4: "Apache AGE for graph traversal
-- (or recursive CTE fallback) integrated."
--
-- Apache AGE on PG 17 PGDG packaging is currently flaky and adds a
-- heavy operational footprint we don't need; the spec accepts the
-- recursive CTE fallback. Stage 4 ships the CTE-based traversal here.
-- An AGE adapter could be added later as a drop-in replacement
-- without changing the helper surface.
--
-- Surface:
--   * graph_neighbors(type, id, direction='out'|'in'|'both',
--                     relationship_filter? text[])
--       → SETOF (target_type, target_id, relationship_type, label,
--                confidence)
--   * graph_walk(type, id, max_depth, direction, rel_filter?,
--                mode='bfs'|'dfs')
--       → SETOF (object_type, object_id, depth, path_ids bigint[],
--                path_kinds text[])
--   * graph_path(src_type, src_id, dst_type, dst_id, max_depth=6)
--       → SETOF path rows; first row = shortest path found.
--
-- All helpers honour RLS on malu$relationship_edge (tenant_owner +
-- grant_visibility from S2-5). Cycle prevention via array-membership
-- check on the running path_ids.
-- =====================================================================

CREATE OR REPLACE FUNCTION maludb_core_version() RETURNS text
    LANGUAGE SQL IMMUTABLE PARALLEL SAFE
    AS $body$ SELECT '0.28.0'::text $body$;

-- ---------------------------------------------------------------------
-- graph_neighbors — one-hop expansion. direction:
--   'out'  : edges where the input is the source
--   'in'   : edges where the input is the target
--   'both' : union of the two
-- relationship_filter: NULL or [] = any relationship_type; otherwise
--   restrict to the listed types.
-- ---------------------------------------------------------------------
CREATE FUNCTION graph_neighbors(
    p_object_type        text,
    p_object_id          bigint,
    p_direction          text   DEFAULT 'out',
    p_relationship_filter text[] DEFAULT NULL
) RETURNS TABLE (
    target_object_type  text,
    target_object_id    bigint,
    relationship_type   text,
    label               text,
    confidence          numeric
) LANGUAGE plpgsql STABLE
AS $body$
BEGIN
    IF p_direction NOT IN ('out','in','both') THEN
        RAISE EXCEPTION 'graph_neighbors: bad direction %', p_direction
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    IF p_direction IN ('out','both') THEN
        RETURN QUERY
        SELECT e.target_object_type, e.target_object_id,
               e.relationship_type, e.label, e.confidence
        FROM malu$relationship_edge e
        WHERE e.source_object_type = p_object_type
          AND e.source_object_id   = p_object_id
          AND (p_relationship_filter IS NULL
               OR cardinality(p_relationship_filter) = 0
               OR e.relationship_type = ANY(p_relationship_filter));
    END IF;

    IF p_direction IN ('in','both') THEN
        RETURN QUERY
        SELECT e.source_object_type, e.source_object_id,
               e.relationship_type, e.label, e.confidence
        FROM malu$relationship_edge e
        WHERE e.target_object_type = p_object_type
          AND e.target_object_id   = p_object_id
          AND (p_relationship_filter IS NULL
               OR cardinality(p_relationship_filter) = 0
               OR e.relationship_type = ANY(p_relationship_filter));
    END IF;
END;
$body$;

-- ---------------------------------------------------------------------
-- graph_walk — multi-hop walk with depth bound. cycle prevention via
-- array-membership check on path_ids (a tuple is uniquely identified
-- by (object_type, object_id) — we encode object_type into path_kinds
-- so different types with overlapping ids don't collide).
--
-- mode='bfs' relies on ORDER BY depth in the recursive CTE; 'dfs'
-- uses the same recursive structure but orders by path_kinds[] for
-- depth-first emission order.
-- ---------------------------------------------------------------------
CREATE FUNCTION graph_walk(
    p_object_type        text,
    p_object_id          bigint,
    p_max_depth          integer DEFAULT 4,
    p_direction          text    DEFAULT 'out',
    p_relationship_filter text[] DEFAULT NULL,
    p_mode               text    DEFAULT 'bfs'
) RETURNS TABLE (
    object_type    text,
    object_id      bigint,
    depth          integer,
    path_ids       bigint[],
    path_kinds     text[]
) LANGUAGE plpgsql STABLE
AS $body$
BEGIN
    IF p_direction NOT IN ('out','in','both') THEN
        RAISE EXCEPTION 'graph_walk: bad direction %', p_direction
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF p_mode NOT IN ('bfs','dfs') THEN
        RAISE EXCEPTION 'graph_walk: bad mode %', p_mode
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF p_max_depth < 0 OR p_max_depth > 32 THEN
        RAISE EXCEPTION 'graph_walk: max_depth must be in [0, 32]'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    RETURN QUERY
    WITH RECURSIVE walk AS (
        SELECT p_object_type AS object_type,
               p_object_id   AS object_id,
               0::integer    AS depth,
               ARRAY[p_object_id]::bigint[] AS path_ids,
               ARRAY[p_object_type]::text[] AS path_kinds
        UNION ALL
        SELECT n.target_object_type,
               n.target_object_id,
               w.depth + 1,
               w.path_ids || n.target_object_id,
               w.path_kinds || n.target_object_type
        FROM walk w
        CROSS JOIN LATERAL graph_neighbors(
            w.object_type, w.object_id,
            p_direction, p_relationship_filter) n
        WHERE w.depth + 1 <= p_max_depth
          -- cycle prevention: don't re-visit (type, id) on this path
          AND NOT (n.target_object_id = ANY(w.path_ids)
                   AND n.target_object_type = ANY(w.path_kinds)
                   AND array_position(w.path_ids, n.target_object_id) =
                       array_position(w.path_kinds, n.target_object_type))
    )
    SELECT w.object_type, w.object_id, w.depth, w.path_ids, w.path_kinds
    FROM walk w
    WHERE w.depth > 0   -- exclude the seed row from output
    ORDER BY
        CASE WHEN p_mode = 'bfs' THEN w.depth END,
        CASE WHEN p_mode = 'dfs' THEN w.path_kinds || w.path_ids::text[] END,
        w.object_id;
END;
$body$;

-- ---------------------------------------------------------------------
-- graph_path — shortest-path-style query from a source to a target.
-- Returns ALL paths up to max_depth ordered by depth ASC; the first
-- row is the shortest. Returns empty set when no path exists within
-- the depth budget.
-- ---------------------------------------------------------------------
CREATE FUNCTION graph_path(
    p_source_type  text,
    p_source_id    bigint,
    p_target_type  text,
    p_target_id    bigint,
    p_max_depth    integer DEFAULT 6,
    p_direction    text    DEFAULT 'out'
) RETURNS TABLE (
    depth       integer,
    path_ids    bigint[],
    path_kinds  text[]
) LANGUAGE sql STABLE
AS $body$
    SELECT w.depth, w.path_ids, w.path_kinds
    FROM graph_walk(p_source_type, p_source_id, p_max_depth, p_direction) w
    WHERE w.object_type = p_target_type
      AND w.object_id   = p_target_id
    ORDER BY w.depth ASC, w.path_ids;
$body$;

GRANT EXECUTE ON FUNCTION
    graph_neighbors(text, bigint, text, text[]),
    graph_walk(text, bigint, integer, text, text[], text),
    graph_path(text, bigint, text, bigint, integer, text)
TO maludb_memory_admin, maludb_memory_executor, maludb_memory_auditor;
