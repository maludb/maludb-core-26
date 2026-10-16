/*
 * Smoke test for libmaludb. Mirrors the Python / Node.js / PHP
 * smoke tests in scope.
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
        printf("  ✓ %s\n", name);
        pass++;
    } else {
        printf("  ✗ %s  %s\n", name, detail ? detail : "");
        fail++;
    }
}

int main(void)
{
    const char *dsn = getenv("MALUDB_TEST_DSN");
    if (!dsn || !*dsn) {
        fputs("MALUDB_TEST_DSN not set — skipping\n", stderr);
        return 77; /* CTest's SKIP exit code */
    }

    /* Per-run tag so re-running the smoke doesn't collide on the
     * supersession-engine EXCLUDE. */
    char tag[32];
    srand((unsigned)time(NULL));
    snprintf(tag, sizeof tag, "cdrv-%08x", rand());
    char subject[64];
    snprintf(subject, sizeof subject, "%s_subj", tag);

    maludb_t *m = maludb_connect(dsn);
    if (!m || maludb_last_error_code(m) != MALUDB_OK) {
        fprintf(stderr, "connect failed: %s\n",
                m ? maludb_last_error_message(m) : "alloc");
        maludb_close(m);
        return 1;
    }

    /* version() */
    printf("version()\n");
    char *v = maludb_version(m);
    check("matches /^0\\./", v && v[0] == '0' && v[1] == '.', v ? v : "(null)");
    free(v);

    maludb_t *tenant = maludb_connect_schema(dsn, "driver_tenant");
    char *tenant_path = tenant ? maludb_search_path(tenant) : NULL;
    check("schema connect prefixes search_path",
          tenant_path && !strncmp(tenant_path, "driver_tenant, maludb_core, public", 35),
          tenant_path ? tenant_path : (tenant ? maludb_last_error_message(tenant) : "alloc"));
    free(tenant_path);
    maludb_close(tenant);

    /* ingest → retrieve */
    printf("ingest → retrieve\n");
    char content[128], origin[128];
    snprintf(content, sizeof content, "%s log line", tag);
    snprintf(origin, sizeof origin, "{\"uri\":\"log://%s\"}", tag);
    int64_t sp = maludb_register_source_package(m, "log", content, origin, NULL);
    check("register_source_package > 0", sp > 0,
          maludb_last_error_message(m));

    char stext_a[128], stext_b[128];
    snprintf(stext_a, sizeof stext_a, "%s: claim a", tag);
    snprintf(stext_b, sizeof stext_b, "%s: claim b", tag);
    int64_t c1 = maludb_register_claim(m, subject, "observed", "event_a", stext_a, sp, NULL);
    int64_t c2 = maludb_register_claim(m, subject, "confirmed", "event_a", stext_b, sp, NULL);

    int64_t claims[] = { c1, c2 };
    char fact_stext[128];
    snprintf(fact_stext, sizeof fact_stext, "%s: verified", tag);
    int64_t fact = maludb_register_fact(
        m, claims, 2, subject, "verified_incident", "event_a", fact_stext,
        "manual", NULL);
    check("register_fact > 0", fact > 0, maludb_last_error_message(m));

    maludb_source_hit_t *hits = NULL;
    size_t nhits = 0;
    const char *types[] = { "claim", "fact", NULL };
    int rc = maludb_text_search(m, tag, types, 20, &hits, &nhits);
    int has_claim_or_fact = 0;
    for (size_t i = 0; i < nhits; ++i) {
        if (!strcmp(hits[i].object_type, "claim") ||
            !strcmp(hits[i].object_type, "fact")) {
            has_claim_or_fact = 1;
            break;
        }
    }
    check("text_search returns claim or fact",
          rc == 0 && has_claim_or_fact,
          maludb_last_error_message(m));
    maludb_free_source_hits(hits, nhits);

    maludb_retrieval_hit_t *rhits = NULL;
    size_t nrhits = 0;
    rc = maludb_retrieve(m, subject, NULL, 10, &rhits, &nrhits);
    check("retrieve returns hits", rc == 0 && nrhits > 0,
          maludb_last_error_message(m));
    maludb_free_retrieval_hits(rhits, nrhits);

    /* not-found translation */
    printf("not-found translation\n");
    char *envelope = maludb_replay_episode(m, (int64_t)1 << 40, "current_valid");
    check("replay of impossibly-large id returns MALUDB_ERR_NOT_FOUND",
          envelope == NULL && maludb_last_error_code(m) == MALUDB_ERR_NOT_FOUND,
          maludb_last_error_message(m));
    free(envelope);

    maludb_close(m);
    printf("\n%d passed, %d failed\n", pass, fail);
    return fail == 0 ? 0 : 1;
}
