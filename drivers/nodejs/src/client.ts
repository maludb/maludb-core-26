/**
 * MaluDB Node.js client.
 *
 * Wraps a `pg.Client` (or pool) and exposes typed methods over the
 * maludb_core SQL surface. Calls pin `search_path` to the tenant schema
 * (when supplied) and maludb_core on connect.
 */

import pg from "pg";
import { translate } from "./exceptions.js";
import type {
  NodeSubmission,
  PoolMember,
  ReplayEnvelope,
  RetrievalHit,
  SkillExecution,
  SourceHit,
} from "./models.js";

const { Client } = pg;

export interface MaluDBClientOptions {
  /** Connection string, e.g. "postgresql:///maludb_bench". */
  connectionString?: string;
  /** Or pass individual options accepted by pg.Client. */
  host?: string;
  port?: number;
  database?: string;
  user?: string;
  password?: string;
  schema?: string;
}

function quoteIdent(value: string): string {
  return `"${value.replace(/"/g, '""')}"`;
}

export class MaluDBClient {
  readonly raw: pg.Client;

  constructor(client: pg.Client) {
    this.raw = client;
  }

  /** Connect and pin search_path. */
  static async connect(opts: MaluDBClientOptions): Promise<MaluDBClient> {
    const { schema, ...clientOpts } = opts;
    const client = new Client(clientOpts);
    await client.connect();
    const searchPath = schema
      ? `${quoteIdent(schema)}, maludb_core, public`
      : "maludb_core, public";
    await client.query(`SET search_path = ${searchPath}`);
    return new MaluDBClient(client);
  }

  async end(): Promise<void> {
    await this.raw.end();
  }

  // ---------------------------------------------------------------- //
  // internal call helpers
  // ---------------------------------------------------------------- //
  private async scalar<T>(sql: string, params: unknown[] = []): Promise<T> {
    try {
      const r = await this.raw.query(sql, params);
      return (r.rows[0] && Object.values(r.rows[0])[0]) as T;
    } catch (e) {
      throw translate(e);
    }
  }

  private async rows<T>(sql: string, params: unknown[] = []): Promise<T[]> {
    try {
      const r = await this.raw.query(sql, params);
      return r.rows as T[];
    } catch (e) {
      throw translate(e);
    }
  }

  // ================================================================ //
  // INGEST
  // ================================================================ //

  async registerSourcePackage(args: {
    sourceType: string;
    contentText?: string | null;
    contentJsonb?: Record<string, unknown> | null;
    originJsonb?: Record<string, unknown> | null;
    sensitivity?: string;
  }): Promise<number> {
    return this.scalar<number>(
      `SELECT register_source_package(
         p_source_type   => $1,
         p_content_text  => $2,
         p_content_jsonb => $3::jsonb,
         p_origin_jsonb  => $4::jsonb,
         p_sensitivity   => $5)`,
      [
        args.sourceType,
        args.contentText ?? null,
        args.contentJsonb ? JSON.stringify(args.contentJsonb) : null,
        args.originJsonb ? JSON.stringify(args.originJsonb) : null,
        args.sensitivity ?? "internal",
      ],
    );
  }

  async registerClaim(args: {
    subject?: string;
    verb?: string;
    predicate?: string;
    objectValue?: string;
    statementText?: string;
    sourcePackageId?: number;
    sensitivity?: string;
  }): Promise<number> {
    return this.scalar<number>(
      `SELECT register_claim(
         p_subject        => $1,
         p_verb           => $2,
         p_predicate      => $3,
         p_object_value   => $4,
         p_statement_text => $5,
         p_source_package_id => $6,
         p_sensitivity    => $7)`,
      [
        args.subject ?? null,
        args.verb ?? null,
        args.predicate ?? null,
        args.objectValue ?? null,
        args.statementText ?? null,
        args.sourcePackageId ?? null,
        args.sensitivity ?? "internal",
      ],
    );
  }

  async registerFact(args: {
    claimIds: number[];
    subject?: string;
    verb?: string;
    objectValue?: string;
    statementText?: string;
    verificationScope?: string;
    verificationMethod?: string;
    sensitivity?: string;
  }): Promise<number> {
    return this.scalar<number>(
      `SELECT register_fact(
         p_claim_ids           => $1,
         p_subject             => $2,
         p_verb                => $3,
         p_object_value        => $4,
         p_statement_text      => $5,
         p_verification_scope  => $6,
         p_verification_method => $7,
         p_sensitivity         => $8)`,
      [
        args.claimIds,
        args.subject ?? null,
        args.verb ?? null,
        args.objectValue ?? null,
        args.statementText ?? null,
        args.verificationScope ?? null,
        args.verificationMethod ?? null,
        args.sensitivity ?? "internal",
      ],
    );
  }

  async registerMemory(args: {
    memoryKind: string;
    title?: string;
    summary?: string;
    payload?: Record<string, unknown>;
    sensitivity?: string;
  }): Promise<number> {
    return this.scalar<number>(
      `SELECT register_memory(
         p_memory_kind   => $1,
         p_title         => $2,
         p_summary       => $3,
         p_payload_jsonb => $4::jsonb,
         p_sensitivity   => $5)`,
      [
        args.memoryKind,
        args.title ?? null,
        args.summary ?? null,
        JSON.stringify(args.payload ?? {}),
        args.sensitivity ?? "internal",
      ],
    );
  }

  async registerEpisode(args: {
    episodeKind: string;
    title: string;
    summary?: string;
    payload?: Record<string, unknown>;
    sensitivity?: string;
  }): Promise<number> {
    return this.scalar<number>(
      `SELECT register_episode(
         p_episode_kind  => $1,
         p_title         => $2,
         p_summary       => $3,
         p_payload_jsonb => $4::jsonb,
         p_sensitivity   => $5)`,
      [
        args.episodeKind,
        args.title,
        args.summary ?? null,
        JSON.stringify(args.payload ?? {}),
        args.sensitivity ?? "internal",
      ],
    );
  }

  // ================================================================ //
  // RETRIEVE
  // ================================================================ //

  async textSearch(
    query: string,
    args: { objectTypes?: string[]; limit?: number } = {},
  ): Promise<SourceHit[]> {
    return this.rows<SourceHit>(
      `SELECT object_type, object_id, title_or_subject, snippet, rank::float8 AS rank
         FROM text_search($1, $2::text[], $3)`,
      [
        query,
        args.objectTypes ?? ["claim", "fact", "memory", "episode_object"],
        args.limit ?? 20,
      ],
    );
  }

  async retrieve(
    cueText: string,
    args: {
      objectTypes?: string[];
      validAsOf?: string;
      transactionAsOf?: string;
      confidenceFloor?: number;
      hintName?: string;
      limit?: number;
    } = {},
  ): Promise<RetrievalHit[]> {
    return this.rows<RetrievalHit>(
      `SELECT object_type, object_id, title, snippet, rank::float8 AS rank,
              strategy, metadata
         FROM execute_retrieval(
              ROW($1, $2::text[], $3::timestamptz, $4::timestamptz, $5::numeric, NULL)
              ::maludb_core.malu$retrieval_envelope_t,
              $6, $7)`,
      [
        cueText,
        args.objectTypes ?? ["claim", "fact", "memory", "episode_object"],
        args.validAsOf ?? null,
        args.transactionAsOf ?? null,
        args.confidenceFloor ?? null,
        args.hintName ?? null,
        args.limit ?? 20,
      ],
    );
  }

  async replayEpisode(
    episodeId: number,
    mode: ReplayEnvelope["mode"] = "current_valid",
    asOf?: string,
  ): Promise<ReplayEnvelope> {
    return this.scalar<ReplayEnvelope>(
      `SELECT replay_episode($1, $2, $3::timestamptz)`,
      [episodeId, mode, asOf ?? null],
    );
  }

  // ================================================================ //
  // ACTIVE MEMORY POOL
  // ================================================================ //

  async createPool(args: {
    poolName: string;
    creationKind?: "prompt" | "api" | "mcp" | "sql";
    taskObjective?: string;
    confidenceFloor?: number;
    maxMemberCount?: number;
  }): Promise<number> {
    return this.scalar<number>(
      `SELECT create_active_memory_pool(
         p_pool_name => $1,
         p_creation_kind => $2,
         p_task_objective => $3,
         p_confidence_floor => $4,
         p_max_member_count => $5)`,
      [
        args.poolName,
        args.creationKind ?? "sql",
        args.taskObjective ?? null,
        args.confidenceFloor ?? null,
        args.maxMemberCount ?? null,
      ],
    );
  }

  async poolAddObservation(args: {
    poolId: number;
    payload: Record<string, unknown>;
    confidence?: number;
    provenance?: Record<string, unknown>;
  }): Promise<number> {
    return this.scalar<number>(
      `SELECT pool_add_observation(
         p_pool_id => $1,
         p_payload_jsonb => $2::jsonb,
         p_confidence => $3,
         p_provenance => $4::jsonb)`,
      [
        args.poolId,
        JSON.stringify(args.payload),
        args.confidence ?? null,
        args.provenance ? JSON.stringify(args.provenance) : null,
      ],
    );
  }

  async poolPromoteToClaim(args: {
    memberId: number;
    subject?: string;
    verb?: string;
    objectValue?: string;
    statementText?: string;
  }): Promise<number> {
    return this.scalar<number>(
      `SELECT pool_promote_to_claim($1, $2, $3, $4, $5)`,
      [
        args.memberId,
        args.subject ?? null,
        args.verb ?? null,
        args.objectValue ?? null,
        args.statementText ?? null,
      ],
    );
  }

  // ================================================================ //
  // SKILL RUNTIME
  // ================================================================ //

  async registerSkill(args: {
    name: string;
    version?: string;
    description?: string;
    applicability?: Record<string, unknown>;
  }): Promise<number> {
    return this.scalar<number>(
      `SELECT register_skill(
         p_skill_name => $1,
         p_version    => $2,
         p_description => $3,
         p_applicability_jsonb => $4::jsonb)`,
      [
        args.name,
        args.version ?? "1.0.0",
        args.description ?? null,
        JSON.stringify(args.applicability ?? {}),
      ],
    );
  }

  async addSkillState(skillId: number, stateName: string, stateKind: string): Promise<number> {
    return this.scalar<number>("SELECT add_skill_state($1, $2, $3)", [
      skillId, stateName, stateKind,
    ]);
  }

  async addSkillTransition(
    skillId: number, fromState: string, toState: string, onOutcome: string,
  ): Promise<number> {
    return this.scalar<number>(
      "SELECT add_skill_transition($1, $2, $3, $4)",
      [skillId, fromState, toState, onOutcome],
    );
  }

  async beginSkillExecution(args: {
    skillId: number;
    environment?: string;
    technologyStack?: string[];
    taskObjective?: string;
    activePoolId?: number;
  }): Promise<number> {
    return this.scalar<number>(
      `SELECT begin_skill_execution(
         p_skill_id => $1,
         p_environment => $2,
         p_technology_stack => $3::text[],
         p_task_objective => $4,
         p_active_pool_id => $5)`,
      [
        args.skillId,
        args.environment ?? null,
        args.technologyStack ?? null,
        args.taskObjective ?? null,
        args.activePoolId ?? null,
      ],
    );
  }

  async stepSkillExecution(
    executionId: number,
    outcome: string,
    observation?: Record<string, unknown>,
  ): Promise<string> {
    return this.scalar<string>(
      `SELECT step_skill_execution($1, $2, $3::jsonb)`,
      [executionId, outcome, observation ? JSON.stringify(observation) : null],
    );
  }

  async abortSkillExecution(executionId: number, reason?: string): Promise<void> {
    await this.scalar("SELECT abort_skill_execution($1, $2)", [executionId, reason ?? null]);
  }

  // ================================================================ //
  // LOCAL NODE SYNC
  // ================================================================ //

  async registerLocalNode(args: {
    nodeName: string;
    fingerprint: string;
    uri?: string;
    description?: string;
  }): Promise<number> {
    return this.scalar<number>(
      "SELECT register_local_node($1, $2, $3, $4)",
      [args.nodeName, args.fingerprint, args.uri ?? null, args.description ?? null],
    );
  }

  async nodeSubmit(args: {
    nodeId: number;
    submissionKind: string;
    payload: Record<string, unknown>;
    localId?: number;
    localHash?: string;
  }): Promise<number> {
    return this.scalar<number>(
      `SELECT node_submit(
         p_node_id => $1,
         p_submission_kind => $2,
         p_payload_jsonb => $3::jsonb,
         p_local_id => $4,
         p_local_hash => $5)`,
      [
        args.nodeId,
        args.submissionKind,
        JSON.stringify(args.payload),
        args.localId ?? null,
        args.localHash ?? null,
      ],
    );
  }

  async nodeAccept(submissionId: number, reason?: string): Promise<Record<string, unknown>> {
    return this.scalar<Record<string, unknown>>(
      "SELECT node_accept($1, $2)",
      [submissionId, reason ?? null],
    );
  }

  async nodeReject(submissionId: number, reason: string): Promise<void> {
    await this.scalar("SELECT node_reject($1, $2)", [submissionId, reason]);
  }

  async revokeLocalNode(nodeId: number, reason: string): Promise<void> {
    await this.scalar("SELECT revoke_local_node($1, $2)", [nodeId, reason]);
  }

  // ================================================================ //
  // V4 PageIndex
  // ================================================================ //
  async pageindexBuild(args: {
    sourcePackageId: number;
    parserKind?: "pdf" | "markdown" | "plain_text";
    modelAliasId?: number;
    promptTemplateId?: number;
    builderOptions?: Record<string, unknown>;
  }): Promise<number> {
    return this.scalar<number>(
      "SELECT source_package_promote_to_page_index($1, $2, $3, $4, $5::jsonb)",
      [
        args.sourcePackageId,
        args.parserKind ?? "pdf",
        args.modelAliasId ?? null,
        args.promptTemplateId ?? null,
        JSON.stringify(args.builderOptions ?? {}),
      ],
    );
  }

  async pageindexList(args: {
    buildStatus?: string;
    limit?: number;
  } = {}): Promise<Record<string, unknown>[]> {
    return this.rows<Record<string, unknown>>(
      "SELECT * FROM pageindex_list_trees($1, $2)",
      [args.buildStatus ?? null, args.limit ?? 50],
    );
  }

  async pageindexGet(treeId: number): Promise<Record<string, unknown> | null> {
    const r = await this.rows<Record<string, unknown>>(
      "SELECT * FROM pageindex_get_tree($1)",
      [treeId],
    );
    return r[0] ?? null;
  }

  async pageindexAsk(args: {
    cueText: string;
    treeId: number;
    maxDepth?: number;
    choice?: "overlap" | "first";
    limit?: number;
  }): Promise<Record<string, unknown> | null> {
    const opts = { max_depth: args.maxDepth ?? 6, choice: args.choice ?? "overlap" };
    const r = await this.rows<Record<string, unknown>>(
      "SELECT * FROM retrieve_with_envelope_tree($1, $2, $3::jsonb, $4)",
      [args.cueText, args.treeId, JSON.stringify(opts), args.limit ?? 1],
    );
    return r[0] ?? null;
  }

  async pageindexSupersede(priorTreeId: number, newTreeId: number): Promise<number> {
    return this.scalar<number>(
      "SELECT page_index_tree_supersede($1, $2)",
      [priorTreeId, newTreeId],
    );
  }

  // ================================================================ //
  // V4 ChatIndex
  // ================================================================ //
  async chatindexBuild(args: {
    sourcePackageId: number;
    modelAliasId?: number;
    promptTemplateId?: number;
    maxChildren?: number;
    builderOptions?: Record<string, unknown>;
  }): Promise<number> {
    return this.scalar<number>(
      "SELECT source_package_promote_to_chat_index($1, $2, $3, $4, $5::jsonb)",
      [
        args.sourcePackageId,
        args.modelAliasId ?? null,
        args.promptTemplateId ?? null,
        args.maxChildren ?? 10,
        JSON.stringify(args.builderOptions ?? {}),
      ],
    );
  }

  async chatindexAppend(
    treeId: number,
    messages: Record<string, unknown>[],
  ): Promise<Record<string, unknown>[]> {
    return this.rows<Record<string, unknown>>(
      "SELECT * FROM chat_index_append_messages($1, $2::jsonb)",
      [treeId, JSON.stringify(messages)],
    );
  }

  async chatindexList(args: {
    buildStatus?: string;
    limit?: number;
  } = {}): Promise<Record<string, unknown>[]> {
    return this.rows<Record<string, unknown>>(
      "SELECT * FROM chatindex_list_trees($1, $2)",
      [args.buildStatus ?? null, args.limit ?? 50],
    );
  }

  async chatindexAsk(args: {
    cueText: string;
    chatTreeId: number;
    maxDepth?: number;
    choice?: "overlap" | "first";
    limit?: number;
  }): Promise<Record<string, unknown> | null> {
    const opts = { max_depth: args.maxDepth ?? 6, choice: args.choice ?? "overlap" };
    const r = await this.rows<Record<string, unknown>>(
      "SELECT * FROM retrieve_with_envelope_chat_tree($1, $2, $3::jsonb, $4)",
      [args.cueText, args.chatTreeId, JSON.stringify(opts), args.limit ?? 1],
    );
    return r[0] ?? null;
  }

  // ================================================================ //
  // misc
  // ================================================================ //
  async version(): Promise<string> {
    return this.scalar<string>("SELECT maludb_core_version()");
  }
}

// Re-exports so consumers can `import { ... } from "@maludb/client"`
export type { SourceHit, RetrievalHit, SkillExecution, PoolMember, NodeSubmission };
