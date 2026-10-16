/*
 * examples/01-ingest-to-replay.c — C mirror of the SQL / Python /
 * Node.js / PHP example.
 *
 * Build:  cmake --build build --target maludb_example_ingest_to_replay
 * Run:    MALUDB_DSN="postgresql:///maludb_bench?host=/var/run/postgresql" \
 *           ./build/maludb_example_ingest_to_replay
 */

#include "maludb.h"

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

int main(void)
{
    const char *dsn = getenv("MALUDB_DSN");
    if (!dsn) dsn = "postgresql:///mydb";

    /* Per-run uuid so the supersession EXCLUDE doesn't fire on
     * re-runs (same as the Python/Node/PHP examples). */
    char run[16];
    srand((unsigned)time(NULL));
    snprintf(run, sizeof run, "%08x", rand());
    char subject[64];
    snprintf(subject, sizeof subject, "api_gateway_%s", run);

    maludb_t *m = maludb_connect(dsn);
    if (!m || maludb_last_error_code(m) != MALUDB_OK) {
        fprintf(stderr, "connect failed: %s\n",
                m ? maludb_last_error_message(m) : "alloc");
        maludb_close(m);
        return 1;
    }

    char *v = maludb_version(m);
    printf("connected to %s — maludb_core %s\n", dsn, v ? v : "?");
    printf("run-id = %s, subject = %s\n", run, subject);
    free(v);

    char ctext[160], origin[160];
    snprintf(ctext, sizeof ctext,
        "c-example-01 [%s]: 14:22Z api-gateway 5xx burst", run);
    snprintf(origin, sizeof origin,
        "{\"uri\":\"log://oncall/c-example-01/%s\"}", run);
    int64_t sp = maludb_register_source_package(m, "log", ctext, origin, NULL);
    printf("  source_package_id = %" PRId64 "\n", sp);

    char stext_a[160], stext_b[160];
    snprintf(stext_a, sizeof stext_a,
        "c-example-01 [%s]: initial 5xx surge at 14:22Z", run);
    snprintf(stext_b, sizeof stext_b,
        "c-example-01 [%s]: health probe exceeded 2s", run);
    int64_t c1 = maludb_register_claim(m, subject, "observed",  "5xx_burst",     stext_a, sp, NULL);
    int64_t c2 = maludb_register_claim(m, subject, "timed_out", "health_probe",  stext_b, sp, NULL);
    printf("  claim_ids = %" PRId64 ", %" PRId64 "\n", c1, c2);

    int64_t claims[] = { c1, c2 };
    char fact_stext[160];
    snprintf(fact_stext, sizeof fact_stext,
        "c-example-01 [%s]: latency SLO breach", run);
    int64_t f1 = maludb_register_fact(
        m, claims, 2, subject, "incident", "latency_breach", fact_stext,
        "oncall_review", NULL);
    printf("  fact_id = %" PRId64 "\n", f1);

    char ep_title[64], payload[160];
    snprintf(ep_title, sizeof ep_title, "c-example-01-outage-%s", run);
    snprintf(payload, sizeof payload,
        "{\"subject_class\":\"%s\",\"environment\":\"prod\"}", subject);
    int64_t ep = maludb_register_episode(m, "incident", ep_title, "Driver example outage", payload, NULL);
    printf("  episode_id = %" PRId64 "\n", ep);

    printf("\n=== text_search('%s') ===\n", subject);
    maludb_source_hit_t *hits = NULL;
    size_t nhits = 0;
    if (maludb_text_search(m, subject, NULL, 5, &hits, &nhits) == 0) {
        for (size_t i = 0; i < nhits; ++i) {
            printf("  %-14s id=%5" PRId64 "  rank=%.4f\n",
                hits[i].object_type, hits[i].object_id, hits[i].rank);
        }
    }
    maludb_free_source_hits(hits, nhits);

    printf("\n=== retrieve('%s') ===\n", subject);
    maludb_retrieval_hit_t *rhits = NULL;
    size_t nrhits = 0;
    if (maludb_retrieve(m, subject, NULL, 5, &rhits, &nrhits) == 0) {
        for (size_t i = 0; i < nrhits; ++i) {
            printf("  %-14s id=%5" PRId64 "  strategy=%s\n",
                rhits[i].object_type, rhits[i].object_id, rhits[i].strategy);
        }
    }
    maludb_free_retrieval_hits(rhits, nrhits);

    printf("\n=== replay_episode ===\n");
    char *envelope = maludb_replay_episode(m, ep, "current_valid");
    if (envelope) {
        /* Quick-n-dirty: just print envelope length (the JSON has the
         * full shape; the C example doesn't pull in a JSON parser). */
        printf("  envelope length = %zu bytes (JSON)\n", strlen(envelope));
        free(envelope);
    } else {
        printf("  replay returned NULL (err: %s)\n",
            maludb_last_error_message(m));
    }

    maludb_close(m);
    return 0;
}
