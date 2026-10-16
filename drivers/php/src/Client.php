<?php

declare(strict_types=1);

namespace MaluDB;

use MaluDB\Exceptions\Translator;
use MaluDB\Models\RetrievalHit;
use MaluDB\Models\SourceHit;
use PDO;
use PDOException;

/**
 * Synchronous PHP client for the maludb_core extension.
 *
 * Wraps a PDO_PGSQL connection. Use {@see fromDsn()} to build one,
 * or pass an existing PDO via {@see fromPdo()}. Search path is pinned
 * to "[schema], maludb_core, public" at connect time.
 *
 * Numeric returns come back from libpq as strings; we cast to int /
 * float at the boundary. JSONB returns are decoded to associative
 * arrays.
 */
final class Client
{
    public PDO $raw;

    public function __construct(PDO $pdo, ?string $schema = null)
    {
        $this->raw = $pdo;
        $this->raw->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
        $searchPath = ($schema === null || $schema === '')
            ? 'maludb_core, public'
            : self::quoteIdentifier($schema) . ', maludb_core, public';
        $this->raw->exec('SET search_path = ' . $searchPath);
    }

    public static function fromDsn(
        string $dsn,
        ?string $user = null,
        ?string $password = null,
        ?string $schema = null,
    ): self
    {
        // Accept either a libpq URI ("postgresql:///mydb") or a PDO
        // DSN ("pgsql:host=…;dbname=…"). Normalise the URI form.
        if (str_starts_with($dsn, 'postgresql://') || str_starts_with($dsn, 'postgres://')) {
            $dsn = self::libpqToPdoDsn($dsn);
        }
        return new self(new PDO($dsn, $user, $password), $schema);
    }

    public static function fromPdo(PDO $pdo, ?string $schema = null): self
    {
        return new self($pdo, $schema);
    }

    private static function quoteIdentifier(string $identifier): string
    {
        return '"' . str_replace('"', '""', $identifier) . '"';
    }

    private static function libpqToPdoDsn(string $uri): string
    {
        // PHP's parse_url returns false on URIs with an empty
        // authority component ("postgresql:///mydb"). Sub in a
        // placeholder host so parse_url accepts it, then drop the
        // placeholder back out after parsing.
        $normalised = preg_replace('#^(postgres(?:ql)?)://(?:/)#', '$1://__LOCAL__/', $uri);
        $parts = parse_url($normalised);
        if ($parts === false) {
            throw new \InvalidArgumentException("Invalid DSN: $uri");
        }
        $params = [];
        if (!empty($parts['host']) && $parts['host'] !== '__LOCAL__') {
            $params['host'] = $parts['host'];
        }
        if (!empty($parts['port'])) $params['port'] = (string)$parts['port'];
        if (!empty($parts['path'])) $params['dbname'] = ltrim($parts['path'], '/');
        if (!empty($parts['user'])) $params['user'] = $parts['user'];
        if (!empty($parts['pass'])) $params['password'] = $parts['pass'];

        // Query-string overrides (?host=/var/run/postgresql etc.).
        if (!empty($parts['query'])) {
            parse_str($parts['query'], $q);
            foreach ($q as $k => $v) {
                $params[$k] = (string)$v;
            }
        }
        $pairs = [];
        foreach ($params as $k => $v) {
            $pairs[] = "$k=$v";
        }
        return 'pgsql:' . implode(';', $pairs);
    }

    // ------------------------------------------------------------ //
    // call helpers
    // ------------------------------------------------------------ //

    /** @param array<int,mixed> $params */
    private function scalar(string $sql, array $params = []): mixed
    {
        try {
            $stmt = $this->raw->prepare($sql);
            $stmt->execute($params);
            $row = $stmt->fetch(PDO::FETCH_NUM);
            return $row !== false ? $row[0] : null;
        } catch (PDOException $e) {
            throw Translator::translate($e);
        }
    }

    /** @param array<int,mixed> $params @return list<array<string,mixed>> */
    private function rows(string $sql, array $params = []): array
    {
        try {
            $stmt = $this->raw->prepare($sql);
            $stmt->execute($params);
            return $stmt->fetchAll(PDO::FETCH_ASSOC);
        } catch (PDOException $e) {
            throw Translator::translate($e);
        }
    }

    // ============================================================ //
    // INGEST
    // ============================================================ //

    /** @param array<string,mixed>|null $originJsonb @param array<string,mixed>|null $contentJsonb */
    public function registerSourcePackage(
        string $sourceType,
        ?string $contentText = null,
        ?array $contentJsonb = null,
        ?array $originJsonb = null,
        string $sensitivity = 'internal',
    ): int {
        return (int)$this->scalar(
            'SELECT register_source_package(
                p_source_type   => :type,
                p_content_text  => :ctext,
                p_content_jsonb => :cjson::jsonb,
                p_origin_jsonb  => :ojson::jsonb,
                p_sensitivity   => :sens)',
            [
                ':type' => $sourceType,
                ':ctext' => $contentText,
                ':cjson' => $contentJsonb !== null ? json_encode($contentJsonb) : null,
                ':ojson' => $originJsonb !== null ? json_encode($originJsonb) : null,
                ':sens' => $sensitivity,
            ],
        );
    }

    public function registerClaim(
        ?string $subject = null,
        ?string $verb = null,
        ?string $predicate = null,
        ?string $objectValue = null,
        ?string $statementText = null,
        ?int $sourcePackageId = null,
        string $sensitivity = 'internal',
    ): int {
        return (int)$this->scalar(
            'SELECT register_claim(
                p_subject        => :s,
                p_verb           => :v,
                p_predicate      => :p,
                p_object_value   => :ov,
                p_statement_text => :stext,
                p_source_package_id => :sp,
                p_sensitivity    => :sens)',
            [
                ':s' => $subject, ':v' => $verb, ':p' => $predicate,
                ':ov' => $objectValue, ':stext' => $statementText,
                ':sp' => $sourcePackageId, ':sens' => $sensitivity,
            ],
        );
    }

    /** @param list<int> $claimIds */
    public function registerFact(
        array $claimIds,
        ?string $subject = null,
        ?string $verb = null,
        ?string $objectValue = null,
        ?string $statementText = null,
        ?string $verificationScope = null,
        ?string $verificationMethod = null,
        string $sensitivity = 'internal',
    ): int {
        // PG ARRAY[] literal — bind via embedded SQL since PDO doesn't
        // expose first-class array binding for the bigint[] type.
        $arr = '{' . implode(',', array_map('intval', $claimIds)) . '}';
        return (int)$this->scalar(
            'SELECT register_fact(
                p_claim_ids => :claims::bigint[],
                p_subject => :s, p_verb => :v,
                p_object_value => :ov, p_statement_text => :stext,
                p_verification_scope => :vscope,
                p_verification_method => :vmeth,
                p_sensitivity => :sens)',
            [
                ':claims' => $arr,
                ':s' => $subject, ':v' => $verb,
                ':ov' => $objectValue, ':stext' => $statementText,
                ':vscope' => $verificationScope, ':vmeth' => $verificationMethod,
                ':sens' => $sensitivity,
            ],
        );
    }

    /** @param array<string,mixed> $payload */
    public function registerMemory(
        string $memoryKind,
        ?string $title = null,
        ?string $summary = null,
        array $payload = [],
        string $sensitivity = 'internal',
    ): int {
        return (int)$this->scalar(
            'SELECT register_memory(
                p_memory_kind   => :k,
                p_title         => :t,
                p_summary       => :s,
                p_payload_jsonb => :p::jsonb,
                p_sensitivity   => :sens)',
            [
                ':k' => $memoryKind, ':t' => $title, ':s' => $summary,
                ':p' => json_encode($payload), ':sens' => $sensitivity,
            ],
        );
    }

    /** @param array<string,mixed> $payload */
    public function registerEpisode(
        string $episodeKind,
        string $title,
        ?string $summary = null,
        array $payload = [],
        string $sensitivity = 'internal',
    ): int {
        return (int)$this->scalar(
            'SELECT register_episode(
                p_episode_kind  => :k,
                p_title         => :t,
                p_summary       => :s,
                p_payload_jsonb => :p::jsonb,
                p_sensitivity   => :sens)',
            [
                ':k' => $episodeKind, ':t' => $title, ':s' => $summary,
                ':p' => json_encode($payload), ':sens' => $sensitivity,
            ],
        );
    }

    // ============================================================ //
    // RETRIEVE
    // ============================================================ //

    /** @param list<string>|null $objectTypes @return list<SourceHit> */
    public function textSearch(string $query, ?array $objectTypes = null, int $limit = 20): array
    {
        $types = $objectTypes ?? ['claim', 'fact', 'memory', 'episode_object'];
        $rows = $this->rows(
            'SELECT object_type, object_id, title_or_subject, snippet, rank::float8 AS rank
             FROM text_search(:q, :t::text[], :l)',
            [
                ':q' => $query,
                ':t' => '{' . implode(',', $types) . '}',
                ':l' => $limit,
            ],
        );
        return array_map(fn($r) => SourceHit::fromRow($r), $rows);
    }

    /** @param list<string>|null $objectTypes @return list<RetrievalHit> */
    public function retrieve(
        string $cueText,
        ?array $objectTypes = null,
        ?string $validAsOf = null,
        ?string $transactionAsOf = null,
        ?float $confidenceFloor = null,
        ?string $hintName = null,
        int $limit = 20,
    ): array {
        $types = $objectTypes ?? ['claim', 'fact', 'memory', 'episode_object'];
        $rows = $this->rows(
            'SELECT object_type, object_id, title, snippet, rank::float8 AS rank,
                    strategy, metadata
             FROM execute_retrieval(
                  ROW(:cue, :t::text[], :v::timestamptz, :tx::timestamptz, :cf::numeric, NULL)
                  ::maludb_core.malu$retrieval_envelope_t,
                  :h, :l)',
            [
                ':cue' => $cueText,
                ':t' => '{' . implode(',', $types) . '}',
                ':v' => $validAsOf, ':tx' => $transactionAsOf,
                ':cf' => $confidenceFloor,
                ':h' => $hintName, ':l' => $limit,
            ],
        );
        return array_map(fn($r) => RetrievalHit::fromRow($r), $rows);
    }

    /** @return array<string,mixed> */
    public function replayEpisode(int $episodeId, string $mode = 'current_valid', ?string $asOf = null): array
    {
        $j = $this->scalar(
            'SELECT replay_episode(:e, :m, :a::timestamptz)',
            [':e' => $episodeId, ':m' => $mode, ':a' => $asOf],
        );
        if (is_string($j)) {
            /** @var array<string,mixed> $decoded */
            $decoded = json_decode($j, true) ?? [];
            return $decoded;
        }
        return is_array($j) ? $j : [];
    }

    // ============================================================ //
    // ACTIVE MEMORY POOL
    // ============================================================ //

    public function createPool(
        string $poolName,
        string $creationKind = 'sql',
        ?string $taskObjective = null,
        ?float $confidenceFloor = null,
        ?int $maxMemberCount = null,
    ): int {
        return (int)$this->scalar(
            'SELECT create_active_memory_pool(
                p_pool_name => :n,
                p_creation_kind => :ck,
                p_task_objective => :t,
                p_confidence_floor => :cf,
                p_max_member_count => :mc)',
            [':n' => $poolName, ':ck' => $creationKind, ':t' => $taskObjective,
             ':cf' => $confidenceFloor, ':mc' => $maxMemberCount],
        );
    }

    /** @param array<string,mixed> $payload @param array<string,mixed>|null $provenance */
    public function poolAddObservation(
        int $poolId,
        array $payload,
        ?float $confidence = null,
        ?array $provenance = null,
    ): int {
        return (int)$this->scalar(
            'SELECT pool_add_observation(
                p_pool_id => :p,
                p_payload_jsonb => :pl::jsonb,
                p_confidence => :c,
                p_provenance => :prov::jsonb)',
            [
                ':p' => $poolId,
                ':pl' => json_encode($payload),
                ':c' => $confidence,
                ':prov' => $provenance !== null ? json_encode($provenance) : null,
            ],
        );
    }

    public function poolPromoteToClaim(
        int $memberId,
        ?string $subject = null,
        ?string $verb = null,
        ?string $objectValue = null,
        ?string $statementText = null,
    ): int {
        return (int)$this->scalar(
            'SELECT pool_promote_to_claim(:m, :s, :v, :ov, :stext)',
            [':m' => $memberId, ':s' => $subject, ':v' => $verb,
             ':ov' => $objectValue, ':stext' => $statementText],
        );
    }

    // ============================================================ //
    // SKILL RUNTIME
    // ============================================================ //

    /** @param array<string,mixed> $applicability */
    public function registerSkill(
        string $name,
        string $version = '1.0.0',
        ?string $description = null,
        array $applicability = [],
    ): int {
        return (int)$this->scalar(
            'SELECT register_skill(
                p_skill_name => :n,
                p_version    => :v,
                p_description => :d,
                p_applicability_jsonb => :a::jsonb)',
            [':n' => $name, ':v' => $version, ':d' => $description,
             ':a' => json_encode($applicability)],
        );
    }

    public function addSkillState(int $skillId, string $stateName, string $stateKind): int
    {
        return (int)$this->scalar('SELECT add_skill_state(:s, :n, :k)',
            [':s' => $skillId, ':n' => $stateName, ':k' => $stateKind]);
    }

    public function addSkillTransition(int $skillId, string $from, string $to, string $onOutcome): int
    {
        return (int)$this->scalar('SELECT add_skill_transition(:s, :f, :t, :o)',
            [':s' => $skillId, ':f' => $from, ':t' => $to, ':o' => $onOutcome]);
    }

    /** @param list<string>|null $technologyStack */
    public function beginSkillExecution(
        int $skillId,
        ?string $environment = null,
        ?array $technologyStack = null,
        ?string $taskObjective = null,
        ?int $activePoolId = null,
    ): int {
        $tech = $technologyStack !== null
            ? '{' . implode(',', $technologyStack) . '}'
            : null;
        return (int)$this->scalar(
            'SELECT begin_skill_execution(
                p_skill_id => :s,
                p_environment => :e,
                p_technology_stack => :t::text[],
                p_task_objective => :to,
                p_active_pool_id => :p)',
            [':s' => $skillId, ':e' => $environment, ':t' => $tech,
             ':to' => $taskObjective, ':p' => $activePoolId],
        );
    }

    /** @param array<string,mixed>|null $observation */
    public function stepSkillExecution(int $executionId, string $outcome, ?array $observation = null): string
    {
        return (string)$this->scalar(
            'SELECT step_skill_execution(:e, :o, :ob::jsonb)',
            [':e' => $executionId, ':o' => $outcome,
             ':ob' => $observation !== null ? json_encode($observation) : null],
        );
    }

    public function abortSkillExecution(int $executionId, ?string $reason = null): void
    {
        $this->scalar('SELECT abort_skill_execution(:e, :r)',
            [':e' => $executionId, ':r' => $reason]);
    }

    // ============================================================ //
    // LOCAL NODE SYNC
    // ============================================================ //

    public function registerLocalNode(
        string $nodeName,
        string $fingerprint,
        ?string $uri = null,
        ?string $description = null,
    ): int {
        return (int)$this->scalar(
            'SELECT register_local_node(:n, :f, :u, :d)',
            [':n' => $nodeName, ':f' => $fingerprint, ':u' => $uri, ':d' => $description],
        );
    }

    /** @param array<string,mixed> $payload */
    public function nodeSubmit(
        int $nodeId,
        string $submissionKind,
        array $payload,
        ?int $localId = null,
        ?string $localHash = null,
    ): int {
        return (int)$this->scalar(
            'SELECT node_submit(
                p_node_id => :n,
                p_submission_kind => :k,
                p_payload_jsonb => :p::jsonb,
                p_local_id => :l,
                p_local_hash => :h)',
            [':n' => $nodeId, ':k' => $submissionKind,
             ':p' => json_encode($payload),
             ':l' => $localId, ':h' => $localHash],
        );
    }

    /** @return array<string,mixed> */
    public function nodeAccept(int $submissionId, ?string $reason = null): array
    {
        $j = $this->scalar('SELECT node_accept(:s, :r)',
            [':s' => $submissionId, ':r' => $reason]);
        if (is_string($j)) {
            /** @var array<string,mixed> $d */
            $d = json_decode($j, true) ?? [];
            return $d;
        }
        return is_array($j) ? $j : [];
    }

    public function nodeReject(int $submissionId, string $reason): void
    {
        $this->scalar('SELECT node_reject(:s, :r)',
            [':s' => $submissionId, ':r' => $reason]);
    }

    public function revokeLocalNode(int $nodeId, string $reason): void
    {
        $this->scalar('SELECT revoke_local_node(:n, :r)',
            [':n' => $nodeId, ':r' => $reason]);
    }

    // ============================================================ //
    // V4 PageIndex
    // ============================================================ //
    public function pageindexBuild(
        int $sourcePackageId,
        string $parserKind = 'pdf',
        ?int $modelAliasId = null,
        ?int $promptTemplateId = null,
        array $builderOptions = []
    ): int {
        return (int)$this->scalar(
            'SELECT source_package_promote_to_page_index(:sp, :pk, :ma, :pt, CAST(:opts AS jsonb))',
            [
                ':sp' => $sourcePackageId, ':pk' => $parserKind,
                ':ma' => $modelAliasId,    ':pt' => $promptTemplateId,
                ':opts' => json_encode($builderOptions),
            ]);
    }

    public function pageindexList(?string $buildStatus = null, int $limit = 50): array
    {
        return $this->rows(
            'SELECT * FROM pageindex_list_trees(:bs, :lim)',
            [':bs' => $buildStatus, ':lim' => $limit]);
    }

    public function pageindexGet(int $treeId): ?array
    {
        $r = $this->rows('SELECT * FROM pageindex_get_tree(:t)', [':t' => $treeId]);
        return $r[0] ?? null;
    }

    public function pageindexAsk(
        string $cueText,
        int $treeId,
        int $maxDepth = 6,
        string $choice = 'overlap',
        int $limit = 1
    ): ?array {
        $opts = ['max_depth' => $maxDepth, 'choice' => $choice];
        $r = $this->rows(
            'SELECT * FROM retrieve_with_envelope_tree(:cue, :t, CAST(:opts AS jsonb), :lim)',
            [
                ':cue' => $cueText, ':t' => $treeId,
                ':opts' => json_encode($opts), ':lim' => $limit,
            ]);
        return $r[0] ?? null;
    }

    public function pageindexSupersede(int $priorTreeId, int $newTreeId): int
    {
        return (int)$this->scalar(
            'SELECT page_index_tree_supersede(:p, :n)',
            [':p' => $priorTreeId, ':n' => $newTreeId]);
    }

    // ============================================================ //
    // V4 ChatIndex
    // ============================================================ //
    public function chatindexBuild(
        int $sourcePackageId,
        ?int $modelAliasId = null,
        ?int $promptTemplateId = null,
        int $maxChildren = 10,
        array $builderOptions = []
    ): int {
        return (int)$this->scalar(
            'SELECT source_package_promote_to_chat_index(:sp, :ma, :pt, :mc, CAST(:opts AS jsonb))',
            [
                ':sp' => $sourcePackageId, ':ma' => $modelAliasId,
                ':pt' => $promptTemplateId, ':mc' => $maxChildren,
                ':opts' => json_encode($builderOptions),
            ]);
    }

    public function chatindexAppend(int $treeId, array $messages): array
    {
        return $this->rows(
            'SELECT * FROM chat_index_append_messages(:t, CAST(:msgs AS jsonb))',
            [':t' => $treeId, ':msgs' => json_encode($messages)]);
    }

    public function chatindexList(?string $buildStatus = null, int $limit = 50): array
    {
        return $this->rows(
            'SELECT * FROM chatindex_list_trees(:bs, :lim)',
            [':bs' => $buildStatus, ':lim' => $limit]);
    }

    public function chatindexAsk(
        string $cueText,
        int $chatTreeId,
        int $maxDepth = 6,
        string $choice = 'overlap',
        int $limit = 1
    ): ?array {
        $opts = ['max_depth' => $maxDepth, 'choice' => $choice];
        $r = $this->rows(
            'SELECT * FROM retrieve_with_envelope_chat_tree(:cue, :t, CAST(:opts AS jsonb), :lim)',
            [
                ':cue' => $cueText, ':t' => $chatTreeId,
                ':opts' => json_encode($opts), ':lim' => $limit,
            ]);
        return $r[0] ?? null;
    }

    // ============================================================ //
    // misc
    // ============================================================ //
    public function version(): string
    {
        return (string)$this->scalar('SELECT maludb_core_version()');
    }
}
