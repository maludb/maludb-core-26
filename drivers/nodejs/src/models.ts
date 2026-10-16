/**
 * TypeScript types for typed return values from maludb_core helpers.
 *
 * JSONB payloads stay as plain objects; numerics come back as `number`
 * (`pg` parses NUMERIC as string by default; the driver wraps to number
 * where appropriate); timestamps come back as `Date`.
 */

export interface SourceHit {
  object_type: string;
  object_id: number;
  title_or_subject: string | null;
  snippet: string | null;
  rank: number;
}

export interface RetrievalHit {
  object_type: string;
  object_id: number;
  title: string | null;
  snippet: string | null;
  rank: number;
  strategy: string;
  metadata: Record<string, unknown>;
}

export interface SkillExecution {
  execution_id: number;
  skill_id: number;
  actor_role: string;
  active_pool_id: number | null;
  task_objective: string | null;
  environment: string | null;
  technology_stack: string[] | null;
  bound_at: Date;
  started_at: Date | null;
  completed_at: Date | null;
  final_outcome: string | null;
  step_count: number;
  emitted_claim_ids: number[];
}

export interface PoolMember {
  member_id: number;
  pool_id: number;
  member_kind: string;
  member_object_type: string | null;
  member_object_id: number | null;
  payload_jsonb: Record<string, unknown> | null;
  confidence: number | null;
  provenance: Record<string, unknown> | null;
  added_by: string;
  added_at: Date;
  promoted_from_member_id: number | null;
  promoted_to_object_type: string | null;
  promoted_to_object_id: number | null;
}

export interface NodeSubmission {
  submission_id: number;
  node_id: number;
  submission_kind: string;
  local_id: number | null;
  status: string;
  applied_object_type: string | null;
  applied_object_id: number | null;
  reason: string | null;
  submitted_at: Date;
  decided_at: Date | null;
}

export type ReplayEnvelope = {
  episode_id: number;
  mode: "current_valid" | "historical" | "as_of_transaction_time" | "full_bitemporal";
  as_of: string | null;
  temporal_mode_used: string;
  episode: Record<string, unknown>;
  what_happened: Record<string, unknown>;
  steps: Array<Record<string, unknown>>;
  supporting_evidence: Array<Record<string, unknown>>;
  later_changes: Array<Record<string, unknown>>;
  source_packages_inspected: number[];
  included_object_ids: { claim: number[]; fact: number[]; memory: number[] };
  hidden_by_policy_count: number;
  prior_belief?: Record<string, unknown>;
};
