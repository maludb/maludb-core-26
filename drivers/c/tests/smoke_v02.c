/*
 * V3-SDK-01 / libmaludb v0.2.0 smoke test.
 *
 * Exercises the pool / skill / node wrappers added in 0.2.0 against
 * the live `contrib_regression` DB that `make installcheck` populates.
 * Skips with CTest's SKIP exit code (77) when MALUDB_TEST_DSN is
 * unset, matching the v0.1.0 smoke.
 */

#include "maludb.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static int pass = 0;
static int fail = 0;

static void check(const char *name, int cond, const char *detail)
{
    if (cond) {
        printf("  + %s\n", name);
        pass++;
    } else {
        printf("  ! %s  %s\n", name, detail ? detail : "");
        fail++;
    }
}

int main(void)
{
    const char *dsn = getenv("MALUDB_TEST_DSN");
    if (!dsn || !*dsn) {
        fputs("MALUDB_TEST_DSN not set — skipping\n", stderr);
        return 77;
    }

    char tag[32];
    srand((unsigned)time(NULL));
    snprintf(tag, sizeof tag, "cdrv02-%08x", rand());

    maludb_t *m = maludb_connect(dsn);
    if (!m || maludb_last_error_code(m) != MALUDB_OK) {
        fprintf(stderr, "connect failed: %s\n",
                m ? maludb_last_error_message(m) : "alloc");
        maludb_close(m);
        return 1;
    }

    /* ----- pool create + add observation ------------------------- */
    char pool_name[64];
    snprintf(pool_name, sizeof pool_name, "%s_pool", tag);
    int64_t pool_id = maludb_pool_create(m, pool_name, "sql", "v0.2 smoke", NULL, 0);
    check("pool_create returns id > 0",
          pool_id > 0,
          maludb_last_error_message(m));

    int64_t obs_id = maludb_pool_add_observation(
        m, pool_id,
        "{\"note\":\"v0.2 smoke observation\"}",
        0.85,
        NULL, NULL, 0);
    check("pool_add_observation returns id > 0",
          obs_id > 0,
          maludb_last_error_message(m));

    /* ----- skill register + state + transition + execution ------- */
    char skill_name[64];
    snprintf(skill_name, sizeof skill_name, "%s_skill", tag);
    int64_t skill_id = maludb_skill_register(
        m, skill_name, "1.0.0", "v0.2 smoke skill",
        "markdown",
        "{\"environment\":\"any\"}",
        "[]");
    check("skill_register returns id > 0",
          skill_id > 0,
          maludb_last_error_message(m));

    int64_t s_init  = maludb_skill_add_state(m, skill_id, "init",  "start",    NULL, NULL);
    int64_t s_done  = maludb_skill_add_state(m, skill_id, "done",  "terminal", NULL, NULL);
    check("skill_add_state init",
          s_init > 0,
          maludb_last_error_message(m));
    check("skill_add_state done",
          s_done > 0,
          maludb_last_error_message(m));

    int64_t t_id = maludb_skill_add_transition(
        m, skill_id, "init", "done", "ok", NULL, 0);
    check("skill_add_transition init->done",
          t_id > 0,
          maludb_last_error_message(m));

    int64_t exec_id = maludb_skill_begin_execution(
        m, skill_id, "any", NULL, "smoke", 0, pool_id);
    check("skill_begin_execution returns id > 0",
          exec_id > 0,
          maludb_last_error_message(m));

    char *next_state = NULL;
    if (exec_id > 0) {
        next_state = maludb_skill_step_execution(m, exec_id, "ok", NULL);
        check("skill_step_execution advances state",
              next_state != NULL,
              maludb_last_error_message(m));
        free(next_state);
    }

    /* abort_skill_execution requires a not-yet-terminal execution;
     * the step above transitioned exec_id to "done". Start a fresh
     * execution and abort it before stepping. */
    int64_t exec_id_abort = maludb_skill_begin_execution(
        m, skill_id, "any", NULL, "smoke-abort", 0, pool_id);
    if (exec_id_abort > 0) {
        int rc = maludb_skill_abort_execution(m, exec_id_abort, "smoke complete");
        check("skill_abort_execution returns 0",
              rc == 0,
              maludb_last_error_message(m));
    }

    /* ----- node register + submit -------------------------------- */
    char node_name[64];
    char node_fp[64];
    snprintf(node_name, sizeof node_name, "%s_node", tag);
    snprintf(node_fp,   sizeof node_fp,   "%s-fingerprint", tag);
    int64_t node_id = maludb_node_register(
        m, node_name, node_fp, NULL, "v0.2 smoke node");
    check("node_register returns id > 0",
          node_id > 0,
          maludb_last_error_message(m));

    int64_t sub_id = maludb_node_submit(
        m, node_id, "claim_new",
        "{\"subject\":\"smoke\",\"verb\":\"submitted\",\"object_value\":\"node-payload\","
        "\"statement_text\":\"v0.2 smoke node submission\",\"sensitivity\":\"internal\"}",
        0, NULL);
    check("node_submit returns id > 0",
          sub_id > 0,
          maludb_last_error_message(m));

    if (sub_id > 0) {
        int rc = maludb_node_reject(m, sub_id, "smoke complete");
        check("node_reject returns 0",
              rc == 0,
              maludb_last_error_message(m));
    }

    printf("\nv0.2 smoke: %d passed, %d failed\n", pass, fail);

    maludb_close(m);
    return fail == 0 ? 0 : 1;
}
