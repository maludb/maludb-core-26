-- MaluDB system catalog (Tier A) — canonical seed vocabulary.
--
-- Reference seed data for the SVPOR taxonomies. Idempotent: every INSERT uses
-- ON CONFLICT DO NOTHING so the file can be re-applied during dev resets and
-- through versioned extension upgrade scripts without duplicating rows.
--
-- Stage     : 3 (per requirements.md §9). Not part of Stage 1.
-- Sources   : white-paper.md §3.1, §5; requirements.md §3.1, §3.2.
-- Run after : docs/design/svpor-system-tables.sql.
--
-- ID assignment uses small sequential integers per table. Stable IDs let
-- future versions reorder/append without rewriting existing data; if you
-- need to deprecate a row, do not reuse its id.

SET search_path TO maludb_core;

BEGIN;

-- ============================================================================
--  malu$object_type — discriminators for malu$governed_object
--  Everything that lives under the polymorphic anchor gets one row here.
-- ============================================================================

INSERT INTO malu$object_type (object_type_id, name, description) VALUES
    ( 1, 'memory',                   'Contextual record of an event, decision, discovery, lesson, dependency, or change (white paper §1.3, §3.1).'),
    ( 2, 'memory_detail_object',     'Addressable child object representing a step, parameter, command, validation, or evidence item; recursively containable.'),
    ( 3, 'subject',                  'First-class entity (person, project, system, ...) used as an SVPOR subject anchor.'),
    ( 4, 'claim',                    'Assertion extracted from a source. May be unverified, contradicted, or partially true.'),
    ( 5, 'fact',                     'Claim or set of claims accepted as true within a defined scope according to verification rules.'),
    ( 6, 'episode_object',           'Concrete DBMS representation of a specific remembered episode (white paper §1.4).'),
    ( 7, 'source_package',           'Verbatim raw input (document, transcript, ticket, log, API payload) preserved with hash and origin.'),
    ( 8, 'workflow_trace',           'Observed sequence of steps for one Episode Object/case.'),
    ( 9, 'generalized_workflow',     'Repeatable process pattern derived from one or more traces.'),
    (10, 'procedural_memory_object', 'Capability-oriented how-to knowledge for performing, adapting, validating, and repairing work.'),
    (11, 'skill_package',            'Governed, evidence-backed procedural memory packaged for reuse with execution policy and audit records.'),
    (12, 'relationship_edge',        'Typed edge between any two governed objects.')
ON CONFLICT (object_type_id) DO NOTHING;

-- ============================================================================
--  malu$subject_type — taxonomy for SVPOR subjects (white paper §5.1)
--  Two-level hierarchy: top-level groupings, then concrete types.
-- ============================================================================

INSERT INTO malu$subject_type (subject_type_id, name, parent_id, description) VALUES
    ( 1, 'actor',           NULL, 'Top-level grouping for human, organizational, and AI actors.'),
    ( 2, 'person',           1,   'Individual human.'),
    ( 3, 'team',             1,   'Group of people working together.'),
    ( 4, 'department',       1,   'Organizational unit.'),
    ( 5, 'organization',     1,   'Company, agency, or other formal organization.'),
    ( 6, 'customer',         1,   'External customer of the organization.'),
    ( 7, 'vendor',           1,   'External vendor or supplier.'),
    ( 8, 'ai_agent',         1,   'AI agent acting on behalf of a user, team, or system.'),

    ( 9, 'artifact',        NULL, 'Top-level grouping for produced or recorded artifacts.'),
    (10, 'document',         9,   'Written document, specification, report, or note.'),
    (11, 'ticket',           9,   'Issue ticket, change request, or work order.'),
    (12, 'log',              9,   'System log, audit log, or recorded telemetry.'),
    (13, 'transcript',       9,   'Conversation, meeting, or interview transcript.'),

    (14, 'infrastructure',  NULL, 'Top-level grouping for technical systems and platforms.'),
    (15, 'system',          14,   'Logical system or platform.'),
    (16, 'server',          14,   'Physical or virtual server.'),
    (17, 'service',         14,   'Running service or daemon.'),
    (18, 'application',     14,   'User-facing application.'),
    (19, 'database',        14,   'Database instance or cluster.'),

    (20, 'place',           NULL, 'Top-level grouping for physical or logical locations.'),
    (21, 'location',        20,   'Physical address, site, or region.'),
    (22, 'data_center',     20,   'Physical or cloud data center.'),

    (23, 'business_object', NULL, 'Top-level grouping for projects, products, and work items.'),
    (24, 'project',         23,   'Time-bounded effort.'),
    (25, 'product',         23,   'Sold or delivered product.'),
    (26, 'initiative',      23,   'Strategic initiative or program.')
ON CONFLICT (subject_type_id) DO NOTHING;

-- ============================================================================
--  malu$verb_type — action / state / observation / derivation classes
--  (white paper §5.2). Flat seed; hierarchy left for ops to add as needed.
-- ============================================================================

INSERT INTO malu$verb_type (verb_type_id, name, semantic_class, parent_id, description) VALUES
    -- events: things that happened
    ( 1, 'installed',   'event',       NULL, 'A system, software, or component was installed.'),
    ( 2, 'configured',  'event',       NULL, 'A system or component was configured.'),
    ( 3, 'deployed',    'event',       NULL, 'A change was deployed to an environment.'),
    ( 4, 'migrated',    'event',       NULL, 'Data, workload, or system was moved between environments.'),
    ( 5, 'upgraded',    'event',       NULL, 'A component version was advanced.'),
    ( 6, 'patched',     'event',       NULL, 'A component received a patch.'),
    ( 7, 'changed',     'event',       NULL, 'A general change was made.'),
    ( 8, 'removed',     'event',       NULL, 'A system, component, or record was removed.'),
    ( 9, 'created',     'event',       NULL, 'A new object, record, or artifact was created.'),
    (10, 'purchased',   'event',       NULL, 'A purchase or procurement event.'),
    (11, 'failed',      'event',       NULL, 'A failure event.'),
    (12, 'recovered',   'event',       NULL, 'A recovery event after a failure.'),

    -- states: assertions about state at a point in time
    (20, 'approved',    'state',       NULL, 'Subject was approved.'),
    (21, 'rejected',    'state',       NULL, 'Subject was rejected.'),
    (22, 'planned',     'state',       NULL, 'Subject was planned.'),
    (23, 'assigned',    'state',       NULL, 'Subject was assigned to an actor or owner.'),
    (24, 'owned',       'state',       NULL, 'Subject is owned by an actor or team.'),

    -- observations: things that were noticed, discussed, or learned
    (40, 'discussed',   'observation', NULL, 'Subject was discussed.'),
    (41, 'discovered',  'observation', NULL, 'Subject was discovered.'),
    (42, 'reviewed',    'observation', NULL, 'Subject was reviewed.'),
    (43, 'reported',    'observation', NULL, 'Subject was reported.'),
    (44, 'learned',     'observation', NULL, 'A lesson or insight was captured.'),
    (45, 'noted',       'observation', NULL, 'Subject was noted.'),

    -- derivations: conclusions, decisions, or verifications drawn from evidence
    (60, 'decided',     'derivation',  NULL, 'A decision was made.'),
    (61, 'verified',    'derivation',  NULL, 'A claim or fact was verified.'),
    (62, 'contradicted','derivation',  NULL, 'A claim or fact was contradicted.'),
    (63, 'superseded',  'derivation',  NULL, 'A prior version was superseded.'),
    (64, 'inferred',    'derivation',  NULL, 'A conclusion was inferred from evidence.')
ON CONFLICT (verb_type_id) DO NOTHING;

-- ============================================================================
--  malu$predicate_type — fields that compose the SVPOR predicate frame
--  (white paper §5.3). value_kind selects which value_* column on
--  malu$memory_predicate_value carries the data for each instance.
-- ============================================================================

INSERT INTO malu$predicate_type (predicate_type_id, name, value_kind, description) VALUES
    ( 1, 'purpose',        'text',           'Why the subject acted, was created, or was changed.'),
    ( 2, 'rationale',      'text',           'Reasoning that led to the decision or action.'),
    ( 3, 'reason',         'text',           'Cause or trigger for the event.'),
    ( 4, 'outcome',        'text',           'Result of the event or decision.'),
    ( 5, 'actor',          'identifier_ref', 'Subject (person, team, agent, system) responsible for the action.'),
    ( 6, 'target',         'identifier_ref', 'Subject acted upon by the verb.'),
    ( 7, 'role',           'text',           'Role the actor played in the event.'),
    ( 8, 'environment',    'text',           'Operational environment or context.'),
    ( 9, 'event_date',     'timestamp',      'Calendar/clock time the event occurred.'),
    (10, 'effective_period','tstzrange',     'Validity window during which the assertion applies.'),
    (11, 'duration',       'numeric',        'Duration of the event in seconds.'),
    (12, 'status',         'enum',           'Status label associated with the event (pending, complete, failed, etc.).'),
    (13, 'impact',         'text',           'Observed or expected impact.'),
    (14, 'mitigation',     'text',           'Mitigation or remediation applied.'),
    (15, 'prerequisites',  'text',           'Conditions that had to hold before the event.'),
    (16, 'conditions',     'text',           'Conditions present during the event.'),
    (17, 'approver',       'identifier_ref', 'Subject that approved the action.'),
    (18, 'requester',      'identifier_ref', 'Subject that requested the action.'),
    (19, 'evidence',       'json',           'Structured evidence supporting the assertion.'),
    (20, 'cost',           'numeric',        'Quantitative cost associated with the event.')
ON CONFLICT (predicate_type_id) DO NOTHING;

-- ============================================================================
--  malu$relationship_type — typed graph edges (white paper §5.5)
--  Inserted in two passes: rows first, inverse pairings via UPDATE.
-- ============================================================================

INSERT INTO malu$relationship_type
    (relationship_type_id, name, category, is_directed, requires_evidence, description) VALUES
    -- association
    ( 1, 'related_to',      'association', false, false, 'Broad semantic association without claim of cause or hierarchy.'),
    ( 2, 'about',           'association', true,  false, 'Subject of the source-side object is the target-side object.'),
    ( 3, 'concerns',        'association', true,  false, 'Inverse of about.'),

    -- governance / evidentiary
    (10, 'supports',        'governance',  true,  false, 'Source-side object provides supporting evidence for target-side.'),
    (11, 'supported_by',    'governance',  true,  false, 'Inverse of supports.'),
    (12, 'contradicts',     'governance',  true,  false, 'Source-side object asserts evidence against target-side.'),
    (13, 'contradicted_by', 'governance',  true,  false, 'Inverse of contradicts.'),
    (14, 'supersedes',      'governance',  true,  false, 'Source-side object replaces target-side under bitemporal supersession.'),
    (15, 'superseded_by',   'governance',  true,  false, 'Inverse of supersedes.'),
    (16, 'verifies',        'governance',  true,  false, 'Source-side object verifies target-side under verification policy.'),
    (17, 'verified_by',     'governance',  true,  false, 'Inverse of verifies.'),

    -- provenance
    (20, 'derived_from',    'provenance',  true,  false, 'Source-side object was derived from target-side under a derivation ledger entry.'),
    (21, 'derives',         'provenance',  true,  false, 'Inverse of derived_from.'),
    (22, 'from',            'provenance',  true,  false, 'Source attribution for an extracted assertion or memory.'),

    -- causal (require evidence per white paper §5.5)
    (30, 'caused_by',       'causal',      true,  true,  'Causal predecessor with evidence and mechanism.'),
    (31, 'causes',          'causal',      true,  true,  'Inverse of caused_by.'),
    (32, 'because_of',      'causal',      true,  true,  'Source-side event occurred because of target-side condition.'),

    -- temporal
    (40, 'before',          'temporal',    true,  false, 'Source-side event preceded target-side.'),
    (41, 'after',           'temporal',    true,  false, 'Source-side event followed target-side.'),
    (42, 'during',          'temporal',    true,  false, 'Source-side event occurred within target-side validity window.'),

    -- containment
    (50, 'contains',        'containment', true,  false, 'Source-side object contains target-side.'),
    (51, 'inside',          'containment', true,  false, 'Inverse of contains.'),
    (52, 'part_of',         'containment', true,  false, 'Source-side is a structural part of target-side.'),
    (53, 'has_part',        'containment', true,  false, 'Inverse of part_of.'),
    (54, 'has_detail',      'containment', true,  false, 'Source-side memory has the target-side as a Memory Detail Object.'),
    (55, 'detail_of',       'containment', true,  false, 'Inverse of has_detail.'),

    -- procedural
    (60, 'depends_on',      'procedural',  true,  false, 'Source-side object operationally depends on target-side.'),
    (61, 'depended_on_by',  'procedural',  true,  false, 'Inverse of depends_on.'),
    (62, 'with',            'procedural',  false, false, 'Co-participant relationship (no asymmetry).')
ON CONFLICT (relationship_type_id) DO NOTHING;

-- second pass — inverse pairings (only set when both sides exist; idempotent)
UPDATE malu$relationship_type r
SET    inverse_id = i.inverse_id
FROM   (VALUES
    ( 2,  3),   ( 3,  2),    -- about / concerns
    (10, 11),   (11, 10),    -- supports / supported_by
    (12, 13),   (13, 12),    -- contradicts / contradicted_by
    (14, 15),   (15, 14),    -- supersedes / superseded_by
    (16, 17),   (17, 16),    -- verifies / verified_by
    (20, 21),   (21, 20),    -- derived_from / derives
    (30, 31),   (31, 30),    -- caused_by / causes
    (40, 41),   (41, 40),    -- before / after
    (50, 51),   (51, 50),    -- contains / inside
    (52, 53),   (53, 52),    -- part_of / has_part
    (54, 55),   (55, 54),    -- has_detail / detail_of
    (60, 61),   (61, 60)     -- depends_on / depended_on_by
) AS i(self_id, inverse_id)
WHERE r.relationship_type_id = i.self_id
  AND r.inverse_id IS DISTINCT FROM i.inverse_id;

COMMIT;
