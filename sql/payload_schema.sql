-- Stage 2 S2-6 — payload schema validation.
--
-- Exercises:
--   * _payload_validate handles type / required / properties / enum /
--     additionalProperties / numeric bounds / string bounds + pattern
--   * register_payload_schema upserts catalog rows
--   * validate_payload looks up by (object_type, kind, default)
--   * triggers fire on memory.payload_jsonb / episode.payload_jsonb /
--     mdo.body_jsonb / claim.statement_jsonb / fact.statement_jsonb /
--     source_package.origin_jsonb
--   * missing required key, type mismatch, additionalProperty,
--     enum miss, pattern miss all raise check_violation on INSERT

\set ECHO all
SET search_path = maludb_core, public;
SET client_min_messages = NOTICE;

-- ---------- _payload_validate: bare type checks ---------------------
SELECT array_length(_payload_validate('{"type":"string"}'::jsonb, '"hi"'::jsonb), 1)
       AS string_ok;
SELECT array_length(_payload_validate('{"type":"string"}'::jsonb, '42'::jsonb), 1)
       AS string_violation_count;
SELECT _payload_validate('{"type":"integer"}'::jsonb, '3.14'::jsonb)
       AS int_vs_float_err;

-- enum
SELECT _payload_validate(
    '{"enum":["red","green","blue"]}'::jsonb, '"green"'::jsonb)
    AS enum_ok;
SELECT _payload_validate(
    '{"enum":["red","green","blue"]}'::jsonb, '"yellow"'::jsonb)
    AS enum_miss;

-- object: required + additionalProperties=false
SELECT _payload_validate(
    '{"type":"object","required":["name"],
      "properties":{"name":{"type":"string"}},
      "additionalProperties":false}'::jsonb,
    '{"name":"Ed"}'::jsonb)
    AS obj_required_ok;

SELECT _payload_validate(
    '{"type":"object","required":["name"],
      "properties":{"name":{"type":"string"}},
      "additionalProperties":false}'::jsonb,
    '{"age":42}'::jsonb)
    AS obj_required_missing_plus_extra;

-- numeric bounds
SELECT _payload_validate(
    '{"type":"integer","minimum":0,"maximum":10}'::jsonb,
    '15'::jsonb)
    AS int_above_max;

-- string bounds + pattern
SELECT _payload_validate(
    '{"type":"string","minLength":3,"maxLength":12,"pattern":"^[A-Z]"}'::jsonb,
    '"ok-bypassed"'::jsonb)
    AS pattern_fails;

-- ---------- register_payload_schema + validate_payload --------------
-- decision-kind: required + pattern, NO additionalProperties:false so
-- that the multi-schema layering with a 'default' schema below stays
-- consistent. additionalProperties:false is exercised separately on
-- memory_kind='change' below.
SELECT register_payload_schema(
    'memory', 'decision',
    '{"type":"object","required":["decision_id","rationale"],
      "properties":{
        "decision_id":{"type":"string","pattern":"^DEC-[0-9]{4}$"},
        "rationale":{"type":"string","minLength":10},
        "alternatives_considered":{"type":"integer","minimum":0}
      }}'::jsonb,
    p_description => 'memory_kind=decision payload contract'
) > 0 AS schema_registered;

-- 'change' kind: strict — additionalProperties:false
SELECT register_payload_schema(
    'memory', 'change',
    '{"type":"object","required":["delta"],
      "properties":{"delta":{"type":"string","minLength":1}},
      "additionalProperties":false}'::jsonb
) > 0 AS strict_schema_registered;

-- valid payload
SELECT validate_payload(
    'memory', 'decision',
    '{"decision_id":"DEC-0001","rationale":"adopted because X outweighs Y"}'::jsonb
) AS validate_decision_ok;

-- invalid payload — missing field, bad pattern
SELECT validate_payload(
    'memory', 'decision',
    '{"decision_id":"bad-pattern"}'::jsonb
);

-- ---------- trigger fires on INSERT/UPDATE --------------------------
-- Happy path
SELECT register_memory(
    p_memory_kind  => 'decision',
    p_title        => 'Pick a DB',
    p_payload_jsonb => '{"decision_id":"DEC-0042","rationale":"chose PostgreSQL for governance"}'::jsonb
) AS happy_memory \gset

SELECT memory_id, memory_kind FROM malu$memory WHERE memory_id = :happy_memory;

-- Failing path: pattern mismatch
SELECT register_memory(
    p_memory_kind  => 'decision',
    p_title        => 'Should reject',
    p_payload_jsonb => '{"decision_id":"WRONG","rationale":"too short"}'::jsonb
);

-- Failing path: missing required
SELECT register_memory(
    p_memory_kind  => 'decision',
    p_title        => 'Should reject',
    p_payload_jsonb => '{"decision_id":"DEC-0001"}'::jsonb
);

-- Failing path: additional property on a strict-additionalProperties=false schema
SELECT register_memory(
    p_memory_kind  => 'change',
    p_title        => 'Should reject',
    p_payload_jsonb => '{"delta":"some change","novel_key":"x"}'::jsonb
);

-- ---------- different kind = different schema (no match → permissive)
-- "event" kind has no schema → any payload allowed
SELECT register_memory(
    p_memory_kind  => 'event',
    p_title        => 'no schema kind',
    p_payload_jsonb => '{"anything":"goes"}'::jsonb
) > 0 AS event_payload_unrestricted;

-- ---------- 'default' schema fires regardless of kind ---------------
SELECT register_payload_schema(
    'memory', 'default',
    '{"type":"object","required":["recorded_by"]}'::jsonb,
    p_description => 'every memory must say who recorded it'
) > 0 AS default_schema_registered;

-- now 'event' must include recorded_by
SELECT register_memory(
    p_memory_kind  => 'event',
    p_title        => 'should reject sans recorded_by',
    p_payload_jsonb => '{"anything":"goes"}'::jsonb
);

-- ...and so must our previous decision-kind path
SELECT register_memory(
    p_memory_kind  => 'decision',
    p_title        => 'now also missing recorded_by',
    p_payload_jsonb => '{"decision_id":"DEC-0099","rationale":"long enough rationale text"}'::jsonb
);

-- valid: both default + decision-kind requirements satisfied.
-- (decision-kind has no additionalProperties:false, so the extra
-- recorded_by key passes the kind schema cleanly.)
SELECT register_memory(
    p_memory_kind  => 'decision',
    p_title        => 'finally satisfies both schemas',
    p_payload_jsonb => '{"decision_id":"DEC-0100","rationale":"long enough rationale text","recorded_by":"ed"}'::jsonb
) > 0 AS both_schemas_ok;

-- ---------- disabling a schema turns off validation -----------------
UPDATE malu$payload_schema SET enabled = false
 WHERE target_object_type = 'memory' AND schema_name = 'default';

SELECT register_memory(
    p_memory_kind  => 'event',
    p_title        => 'after disable, recorded_by no longer required',
    p_payload_jsonb => '{"x":1}'::jsonb
) > 0 AS disabled_schema_skipped;

-- ---------- cleanup -------------------------------------------------
DELETE FROM malu$memory WHERE title IN
    ('Pick a DB','no schema kind','finally satisfies both schemas',
     'after disable, recorded_by no longer required');
DELETE FROM malu$payload_schema WHERE target_object_type = 'memory';
