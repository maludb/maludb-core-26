/* mc2dbd entry point. R1.0-7. */

#include "common.h"
#include "http.h"
#include "db.h"
#include "proxy.h"

#include <ctype.h>
#include <getopt.h>
#include <signal.h>
#include <strings.h>
#include <time.h>
#include <unistd.h>

static volatile sig_atomic_t g_running = 1;
static void on_signal(int sig) { (void)sig; g_running = 0; }

static bool env_truthy(const char *s)
{
    if (!s || !*s) return false;
    return strcmp(s, "1") == 0 ||
           strcasecmp(s, "true") == 0 ||
           strcasecmp(s, "yes") == 0 ||
           strcasecmp(s, "on") == 0;
}

void mc2dbd_log(const char *level, const char *fmt, ...)
{
    char ts[32];
    time_t t = time(NULL);
    struct tm tm;
    localtime_r(&t, &tm);
    strftime(ts, sizeof ts, "%Y-%m-%dT%H:%M:%S", &tm);
    fprintf(stderr, "%s %s mc2dbd ", ts, level);
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
}

static void usage(FILE *f)
{
    fprintf(f,
        "usage: maludb_mc2dbd [options]\n"
        "  --host HOST          bind host (default %s)\n"
        "  --port PORT          bind port (default %d)\n"
        "  --pg-conninfo STR    libpq connection string (or env PGDATABASE etc.)\n"
        "  --tls                enable TLS (requires --tls-cert and --tls-key)\n"
        "  --tls-cert PATH      TLS certificate file\n"
        "  --tls-key  PATH      TLS private key file\n"
        "  --bearer-token TOK   require Authorization: Bearer <TOK>\n"
        "                       (or set env BEARER_TOKEN / MALUDB_MC2DBD_TOKEN)\n"
        "  --foreground         do not daemonize (default for systemd)\n"
        "  --version            print version and exit\n"
        "  --help               this help\n",
        MC2DBD_DEFAULT_HOST, MC2DBD_DEFAULT_PORT);
}

int main(int argc, char **argv)
{
    mc2dbd_config cfg = {
        .bind_host    = strdup(MC2DBD_DEFAULT_HOST),
        .bind_port    = MC2DBD_DEFAULT_PORT,
        .pg_conninfo  = NULL,
        .bearer_token = NULL,
        .tls_enabled  = false,
        .tls_cert_path = NULL,
        .tls_key_path  = NULL,
        .foreground   = true,
    };

    static struct option opts[] = {
        {"host",         required_argument, 0, 'H'},
        {"port",         required_argument, 0, 'P'},
        {"pg-conninfo", required_argument, 0, 'C'},
        {"tls",          no_argument,       0, 'T'},
        {"tls-cert",     required_argument, 0, 'c'},
        {"tls-key",      required_argument, 0, 'k'},
        {"bearer-token", required_argument, 0, 'B'},
        {"foreground",   no_argument,       0, 'f'},
        {"version",      no_argument,       0, 'V'},
        {"help",         no_argument,       0, 'h'},
        {0,0,0,0}
    };

    int o;
    while ((o = getopt_long(argc, argv, "H:P:C:Tc:k:B:fVh", opts, NULL)) != -1) {
        switch (o) {
        case 'H': free(cfg.bind_host); cfg.bind_host = strdup(optarg); break;
        case 'P': cfg.bind_port = atoi(optarg); break;
        case 'C': free(cfg.pg_conninfo); cfg.pg_conninfo = strdup(optarg); break;
        case 'T': cfg.tls_enabled = true; break;
        case 'c': free(cfg.tls_cert_path); cfg.tls_cert_path = strdup(optarg); break;
        case 'k': free(cfg.tls_key_path);  cfg.tls_key_path = strdup(optarg); break;
        case 'B': free(cfg.bearer_token); cfg.bearer_token = strdup(optarg); break;
        case 'f': cfg.foreground = true; break;
        case 'V':
            printf("maludb_mc2dbd %s (MCP %s)\n", MC2DBD_VERSION, MC2DBD_PROTOCOL_VER);
            return 0;
        case 'h': usage(stdout); return 0;
        default:  usage(stderr); return 2;
        }
    }

    /* Env overrides where flags weren't provided. */
    if (!cfg.bearer_token) {
        const char *e = getenv("BEARER_TOKEN");
        if (!e || !*e) e = getenv("MALUDB_MC2DBD_TOKEN");
        if (e && *e) cfg.bearer_token = strdup(e);
    }
    if (!cfg.tls_enabled && env_truthy(getenv("TLS"))) {
        cfg.tls_enabled = true;
    }
    if (!cfg.tls_cert_path) {
        const char *e = getenv("TLS_CERT");
        if (e && *e) cfg.tls_cert_path = strdup(e);
    }
    if (!cfg.tls_key_path) {
        const char *e = getenv("TLS_KEY");
        if (e && *e) cfg.tls_key_path = strdup(e);
    }

    if (cfg.bind_port <= 0 || cfg.bind_port > 65535) {
        LOG_ERROR("invalid port: %d", cfg.bind_port);
        return 2;
    }

    /* Verify PG is reachable before starting MHD. Fail fast on bad config. */
    PGconn *probe = db_open(&cfg);
    if (!probe) {
        LOG_ERROR("PG probe failed; refusing to start");
        return 3;
    }
    db_close(probe);

    signal(SIGTERM, on_signal);
    signal(SIGINT,  on_signal);
    signal(SIGPIPE, SIG_IGN);

    proxy_global_init();

    struct MHD_Daemon *d = http_start(&cfg);
    if (!d) {
        proxy_global_cleanup();
        return 4;
    }

    LOG_INFO("maludb_mc2dbd %s ready", MC2DBD_VERSION);

    /* MHD runs in its own thread; main loop just waits for signal. */
    while (g_running) {
        struct timespec ts = { .tv_sec = 1, .tv_nsec = 0 };
        nanosleep(&ts, NULL);
    }

    LOG_INFO("shutting down");
    http_stop(d);
    proxy_global_cleanup();

    free(cfg.bind_host);
    free(cfg.pg_conninfo);
    free(cfg.bearer_token);
    free(cfg.tls_cert_path);
    free(cfg.tls_key_path);
    return 0;
}
