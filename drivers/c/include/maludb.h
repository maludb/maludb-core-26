/*
 * libmaludb — C client for the MaluDB PostgreSQL extension.
 *
 * Synchronous, libpq-backed. Mirrors the Python/Node.js/PHP drivers
 * in surface and exception semantics.
 *
 * Ownership rules:
 *   - Every `char *` returned by a maludb_* function is heap-allocated.
 *     The caller MUST free() it.
 *   - Arrays of structs returned via `out` pointers (e.g.
 *     maludb_text_search) are heap-allocated; the caller MUST
 *     maludb_free_hits() them.
 *   - The `maludb_t *` handle holds the connection AND the most
 *     recent error metadata; free with maludb_close().
 *
 * Error model:
 *   - Functions return 0 on success, negative on failure.
 *   - On failure, inspect maludb_last_error_code() and
 *     maludb_last_error_message().
 */

#ifndef MALUDB_H
#define MALUDB_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Visibility -------------------------------------------------------- */
#if defined(MALUDB_BUILDING_LIB)
#  define MALUDB_API __attribute__((visibility("default")))
#else
#  define MALUDB_API
#endif

/* Version ----------------------------------------------------------- */
#define MALUDB_DRIVER_VERSION_MAJOR 0
#define MALUDB_DRIVER_VERSION_MINOR 2
#define MALUDB_DRIVER_VERSION_PATCH 0
#define MALUDB_DRIVER_VERSION_STRING "0.2.0"

/* Error codes ------------------------------------------------------- */
typedef enum {
    MALUDB_OK = 0,
    MALUDB_ERR_GENERIC = -1,
    MALUDB_ERR_CONNECT = -2,
    MALUDB_ERR_NOT_FOUND = -3,             /* SQLSTATE P0002 / 02000 */
    MALUDB_ERR_INVALID_PARAMETER = -4,     /* 22023 / 22P02 */
    MALUDB_ERR_OBJECT_NOT_IN_STATE = -5,   /* 55000 */
    MALUDB_ERR_CHECK_VIOLATION = -6,       /* 23514 */
    MALUDB_ERR_PERMISSION_DENIED = -7,     /* 42501 */
} maludb_errcode_t;

/* Opaque handle ----------------------------------------------------- */
typedef struct maludb_s maludb_t;

/* Returned by text_search / retrieve ---------------------------------*/
typedef struct {
    char    *object_type;     /* "claim" | "fact" | "memory" | "episode_object" */
    int64_t  object_id;
    char    *title_or_subject;
    char    *snippet;
    double   rank;
} maludb_source_hit_t;

typedef struct {
    char    *object_type;
    int64_t  object_id;
    char    *title;
    char    *snippet;
    double   rank;
    char    *strategy;
    char    *metadata_jsonb;  /* raw JSON; caller decodes */
} maludb_retrieval_hit_t;

/* ----- connection lifecycle --------------------------------------- */
MALUDB_API maludb_t *maludb_connect(const char *dsn);
MALUDB_API maludb_t *maludb_connect_schema(const char *dsn, const char *schema);
MALUDB_API void      maludb_close(maludb_t *m);

/* ----- error inspection ------------------------------------------- */
MALUDB_API maludb_errcode_t maludb_last_error_code(const maludb_t *m);
MALUDB_API const char      *maludb_last_error_message(const maludb_t *m);

/* ----- version probe ---------------------------------------------- */
/* Returns a heap-allocated string; caller free()s. NULL on error. */
MALUDB_API char *maludb_version(maludb_t *m);
MALUDB_API char *maludb_search_path(maludb_t *m);

/* ----- ingest helpers --------------------------------------------- */
MALUDB_API int64_t maludb_register_source_package(
    maludb_t   *m,
    const char *source_type,
    const char *content_text,        /* may be NULL */
    const char *origin_jsonb,        /* may be NULL */
    const char *sensitivity);        /* may be NULL → "internal" */

MALUDB_API int64_t maludb_register_claim(
    maludb_t   *m,
    const char *subject,             /* may be NULL */
    const char *verb,                /* may be NULL */
    const char *object_value,        /* may be NULL */
    const char *statement_text,      /* may be NULL */
    int64_t     source_package_id,   /* 0 → NULL */
    const char *sensitivity);        /* may be NULL */

MALUDB_API int64_t maludb_register_fact(
    maludb_t       *m,
    const int64_t  *claim_ids,
    size_t          claim_count,
    const char     *subject,
    const char     *verb,
    const char     *object_value,
    const char     *statement_text,
    const char     *verification_method,
    const char     *sensitivity);

MALUDB_API int64_t maludb_register_memory(
    maludb_t   *m,
    const char *memory_kind,
    const char *title,
    const char *summary,
    const char *payload_jsonb,       /* may be NULL → "{}" */
    const char *sensitivity);

MALUDB_API int64_t maludb_register_episode(
    maludb_t   *m,
    const char *episode_kind,
    const char *title,
    const char *summary,
    const char *payload_jsonb,
    const char *sensitivity);

/* ----- retrieve --------------------------------------------------- */
/*
 * Populates `*out_hits` with a heap-allocated array of length
 * `*out_count`. Caller MUST maludb_free_source_hits().
 */
MALUDB_API int maludb_text_search(
    maludb_t              *m,
    const char            *query,
    const char *const     *object_types,    /* NULL or NULL-terminated */
    int                    limit,
    maludb_source_hit_t  **out_hits,
    size_t                *out_count);

MALUDB_API void maludb_free_source_hits(maludb_source_hit_t *hits, size_t count);

MALUDB_API int maludb_retrieve(
    maludb_t                 *m,
    const char               *cue_text,
    const char *const        *object_types,
    int                       limit,
    maludb_retrieval_hit_t  **out_hits,
    size_t                   *out_count);

MALUDB_API void maludb_free_retrieval_hits(maludb_retrieval_hit_t *hits, size_t count);

/*
 * Replay an episode. Returns a heap-allocated JSON envelope on
 * success (caller free()s) or NULL on error.
 */
MALUDB_API char *maludb_replay_episode(
    maludb_t   *m,
    int64_t     episode_id,
    const char *mode);               /* "current_valid" default */

/* ===================================================================
 * V3-SDK-01 (v0.2.0) — pool / skill / node wrappers.
 *
 * Mirrors the Python/Node.js/PHP coverage for Stage 5 (active memory
 * pools, skill runtime) and Stage 6 (local node sync). Every helper
 * returns the new object id (or -1 on error) unless documented
 * otherwise; error metadata is captured on the maludb_t handle and
 * recoverable via maludb_last_error_code() / _message().
 * =================================================================== */

/* ----- Active memory pools (Stage 5 / S5-3) ----------------------- */
MALUDB_API int64_t maludb_pool_create(
    maludb_t      *m,
    const char    *pool_name,
    const char    *creation_kind,         /* may be NULL → 'sql' */
    const char    *task_objective,        /* may be NULL */
    const char *const *authorized_partitions, /* NULL or NULL-terminated */
    int            max_member_count);     /* <= 0 → SQL default */

MALUDB_API int64_t maludb_pool_add_observation(
    maludb_t   *m,
    int64_t     pool_id,
    const char *payload_jsonb,            /* required */
    double      confidence,               /* < 0 → NULL */
    const char *provenance_jsonb,         /* may be NULL */
    const char *access_label,             /* may be NULL */
    int64_t     account_id);              /* 0 → NULL */

MALUDB_API int64_t maludb_pool_promote_to_claim(
    maludb_t   *m,
    int64_t     member_id,
    const char *subject,                  /* may be NULL */
    const char *verb,                     /* may be NULL */
    const char *object_value,             /* may be NULL */
    const char *statement_text,           /* may be NULL */
    const char *sensitivity);             /* may be NULL → 'internal' */

/* ----- Skill runtime (Stage 5 / S5-2) ----------------------------- */
MALUDB_API int64_t maludb_skill_register(
    maludb_t   *m,
    const char *skill_name,
    const char *version,                  /* may be NULL → '1.0.0' */
    const char *description,              /* may be NULL */
    const char *packaging_kind,           /* may be NULL → 'markdown' */
    const char *applicability_jsonb,      /* may be NULL → '{}' */
    const char *precondition_jsonb);      /* may be NULL → '[]' */

MALUDB_API int64_t maludb_skill_add_state(
    maludb_t   *m,
    int64_t     skill_id,
    const char *state_name,
    const char *state_kind,
    const char *step_jsonb,               /* may be NULL */
    const char *validation_jsonb);        /* may be NULL */

MALUDB_API int64_t maludb_skill_add_transition(
    maludb_t   *m,
    int64_t     skill_id,
    const char *from_state,
    const char *to_state,
    const char *on_outcome,
    const char *guard_jsonb,              /* may be NULL */
    int         ordinal);

MALUDB_API int64_t maludb_skill_begin_execution(
    maludb_t   *m,
    int64_t     skill_id,
    const char *environment,              /* may be NULL */
    const char *const *technology_stack,  /* NULL or NULL-terminated */
    const char *task_objective,           /* may be NULL */
    int64_t     account_id,               /* 0 → NULL */
    int64_t     active_pool_id);          /* 0 → NULL */

/* Returns a heap-allocated next-state name on success (caller free()s),
 * or NULL on error. */
MALUDB_API char *maludb_skill_step_execution(
    maludb_t   *m,
    int64_t     execution_id,
    const char *outcome,
    const char *observation_jsonb);       /* may be NULL */

/* Returns 0 on success, negative on error. */
MALUDB_API int maludb_skill_abort_execution(
    maludb_t   *m,
    int64_t     execution_id,
    const char *reason);                  /* may be NULL */

/* ----- Local memory nodes (Stage 6 / S6-1) ------------------------ */
MALUDB_API int64_t maludb_node_register(
    maludb_t   *m,
    const char *node_name,
    const char *fingerprint,
    const char *uri,                      /* may be NULL */
    const char *description);             /* may be NULL */

MALUDB_API int64_t maludb_node_submit(
    maludb_t   *m,
    int64_t     node_id,
    const char *submission_kind,
    const char *payload_jsonb,
    int64_t     local_id,                 /* 0 → NULL */
    const char *local_hash);              /* may be NULL */

/* Returns a heap-allocated JSON envelope describing the accepted
 * object (caller free()s), or NULL on error. */
MALUDB_API char *maludb_node_accept(
    maludb_t   *m,
    int64_t     submission_id,
    const char *reason);                  /* may be NULL */

/* Returns 0 on success, negative on error. */
MALUDB_API int maludb_node_reject(
    maludb_t   *m,
    int64_t     submission_id,
    const char *reason);                  /* required */

/* ===== V4 PageIndex (alpha.5+) ============================== */

/* Promote a Source Package to a PageIndex tree. parser_kind is one
 * of "pdf" | "markdown" | "plain_text". Returns the new tree_id or
 * a negative value on error. */
MALUDB_API int64_t maludb_pageindex_build(
    maludb_t   *m,
    int64_t     source_package_id,
    const char *parser_kind,
    int64_t     model_alias_id,           /* 0 -> NULL */
    int64_t     prompt_template_id,       /* 0 -> NULL */
    const char *builder_options_jsonb);   /* may be NULL */

/* Mark a tree superseded by a new tree. Writes a 'supersedes' edge.
 * Returns the new edge_id or negative on error. */
MALUDB_API int64_t maludb_pageindex_supersede(
    maludb_t   *m,
    int64_t     prior_tree_id,
    int64_t     new_tree_id);

/* Descend a PageIndex tree to answer a query. Returns a heap-
 * allocated JSON string with envelope_id / leaf_mdo_id /
 * leaf_title / leaf_summary / depth_reached, or NULL on error.
 * Caller free()s. */
MALUDB_API char *maludb_pageindex_ask(
    maludb_t   *m,
    const char *cue_text,
    int64_t     tree_id,
    const char *descent_options_jsonb,    /* may be NULL */
    int         limit);                   /* 0 -> 1 */

/* ===== V4 ChatIndex (alpha.5+) ============================== */

/* Promote a chat-transcript Source Package to a ChatIndex tree. */
MALUDB_API int64_t maludb_chatindex_build(
    maludb_t   *m,
    int64_t     source_package_id,
    int64_t     model_alias_id,           /* 0 -> NULL */
    int64_t     prompt_template_id,       /* 0 -> NULL */
    int         max_children,             /* 0 -> 10 */
    const char *builder_options_jsonb);   /* may be NULL */

/* Append one or more messages. messages_jsonb is a JSON array;
 * each element is {message_index, system_message?, user_message?,
 * assistant_message?, topic_branch? {new, from_ancestor_mdo_id?}}.
 * Returns 0 on success, negative on error. */
MALUDB_API int maludb_chatindex_append(
    maludb_t   *m,
    int64_t     tree_id,
    const char *messages_jsonb);          /* required */

/* Descend a ChatIndex tree. Same return shape as
 * maludb_pageindex_ask. */
MALUDB_API char *maludb_chatindex_ask(
    maludb_t   *m,
    const char *cue_text,
    int64_t     chat_tree_id,
    const char *descent_options_jsonb,    /* may be NULL */
    int         limit);                   /* 0 -> 1 */

#ifdef __cplusplus
}
#endif

#endif /* MALUDB_H */
