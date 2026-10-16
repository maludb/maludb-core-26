/* mc2dbd external_exec dispatcher — R1.1-1.
 *
 * Wires the catalog row in malu$mc2db_tool_external_exec to a real
 * fork+exec runner. R1.0 stubbed this branch with IMPL_TYPE_NOT_AVAILABLE;
 * R1.1-1 replaces the stub with the implementation below.
 *
 * Lifecycle of one call:
 *   1. catalog lookup       — command_path, argv_template, working_dir,
 *                              environment, run_as_user, timeout_ms,
 *                              max_output_bytes
 *   2. envelope build       — {tool_name, call_id, arguments, context}
 *                              as JSON-on-stdin
 *   3. fork + 3 pipes       — stdin/stdout/stderr
 *   4. select() loop        — non-blocking reads with deadline
 *   5. timeout enforcement  — SIGTERM at deadline, SIGKILL after grace
 *   6. waitpid              — collect exit status
 *   7. parse stdout         — {ok:true,result} | {ok:false,error}
 *   8. produce mc2dbd_tool_result
 *
 * Security defaults:
 *   - command_path MUST be absolute (the catalog CHECK enforces this;
 *     we re-check defensively).
 *   - environment is scrubbed to a minimal base set; per-tool overrides
 *     come from malu$mc2db_tool_external_exec.environment (jsonb object
 *     of string→string).
 *   - argv_template is a JSON array of strings. R1.1-1.1 substitutes
 *     {{key}} placeholders against keys from the tools/call arguments
 *     JSON object. Unmatched placeholders are left in place (matches
 *     the maludb_core _render_substitute convention). Scalar values
 *     (string, integer, number, boolean, null) substitute by their
 *     natural string form; objects/arrays substitute by their compact
 *     JSON serialization. arguments are still also delivered on stdin
 *     so tools can read the full structured input.
 *   - run_as_user is honored only when the listener runs as root and
 *     the requested account exists. Otherwise we run with the listener's
 *     own credentials and surface a warning in the audit row.
 */

#include "exec.h"
#include "db.h"

#include <errno.h>
#include <fcntl.h>
#include <pwd.h>
#include <signal.h>
#include <sys/select.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define EXEC_STDOUT_HARDCAP   (4 * 1024 * 1024)  /* 4 MiB absolute ceiling */
#define EXEC_STDERR_CAP       4096               /* 4 KiB into audit */
#define EXEC_KILL_GRACE_MS    500
#define EXEC_DEFAULT_PATH     "/usr/local/bin:/usr/bin:/bin"

typedef struct exec_meta {
    int64_t  tool_id;
    char    *tool_name;
    char    *command_path;
    json_t  *argv_template;     /* json array of strings (owned) */
    char    *working_dir;
    char    *run_as_user;
    json_t  *environment;       /* json object of string→string (owned) */
    int      timeout_ms;
    int      max_output_bytes;
} exec_meta;

static void exec_meta_free(exec_meta *m)
{
    if (!m) return;
    free(m->tool_name);
    free(m->command_path);
    free(m->working_dir);
    free(m->run_as_user);
    if (m->argv_template) json_decref(m->argv_template);
    if (m->environment)   json_decref(m->environment);
    memset(m, 0, sizeof *m);
}

static void set_err(mc2dbd_tool_result *r, const char *code, const char *msg)
{
    r->is_error      = true;
    r->error_code    = strdup(code);
    r->error_message = strdup(msg);
    json_t *block = json_object();
    json_object_set_new(block, "type", json_string("text"));
    json_object_set_new(block, "text", json_string(msg));
    r->content = json_array();
    json_array_append_new(r->content, block);
}

/* Convenience: copy a possibly-null PG text column into a malloc'd cstring. */
static char *
pg_strdup_or_null(PGresult *r, int row, int col)
{
    if (PQgetisnull(r, row, col)) return NULL;
    return strdup(PQgetvalue(r, row, col));
}

/* Catalog lookup. Returns true on success, fills *out. */
static bool
load_exec_meta(PGconn *conn, int64_t tool_id, exec_meta *out, char *errbuf, size_t errsz)
{
    char id_buf[32];
    snprintf(id_buf, sizeof id_buf, "%lld", (long long) tool_id);
    const char *params[1] = { id_buf };
    const char *sql =
        "SELECT t.tool_name, t.timeout_ms, t.max_output_bytes, "
        "       ee.command_path, ee.argv_template::text, "
        "       ee.working_dir, ee.run_as_user, ee.environment::text "
        "FROM maludb_core.malu$mc2db_tool t "
        "JOIN maludb_core.malu$mc2db_tool_external_exec ee USING (tool_id) "
        "WHERE t.tool_id = $1";
    PGresult *r = PQexecParams(conn, sql, 1, NULL, params, NULL, NULL, 0);
    if (PQresultStatus(r) != PGRES_TUPLES_OK) {
        snprintf(errbuf, errsz, "external_exec metadata lookup failed: %s",
                 PQresultErrorMessage(r));
        PQclear(r);
        return false;
    }
    if (PQntuples(r) == 0) {
        snprintf(errbuf, errsz,
                 "tool_id %lld has no malu$mc2db_tool_external_exec row",
                 (long long) tool_id);
        PQclear(r);
        return false;
    }

    memset(out, 0, sizeof *out);
    out->tool_id          = tool_id;
    out->tool_name        = pg_strdup_or_null(r, 0, 0);
    out->timeout_ms       = atoi(PQgetvalue(r, 0, 1));
    out->max_output_bytes = atoi(PQgetvalue(r, 0, 2));
    out->command_path     = pg_strdup_or_null(r, 0, 3);
    out->working_dir      = pg_strdup_or_null(r, 0, 5);
    out->run_as_user      = pg_strdup_or_null(r, 0, 6);

    {
        json_error_t je;
        const char *txt = PQgetisnull(r, 0, 4) ? "[]" : PQgetvalue(r, 0, 4);
        out->argv_template = json_loads(txt, 0, &je);
        if (!out->argv_template) out->argv_template = json_array();
    }
    {
        json_error_t je;
        const char *txt = PQgetisnull(r, 0, 7) ? "{}" : PQgetvalue(r, 0, 7);
        out->environment = json_loads(txt, 0, &je);
        if (!out->environment) out->environment = json_object();
    }

    PQclear(r);

    /* Bound max_output_bytes by our hard cap so a misconfigured tool
     * cannot make the listener allocate unbounded memory. */
    if (out->max_output_bytes <= 0 || out->max_output_bytes > EXEC_STDOUT_HARDCAP)
        out->max_output_bytes = EXEC_STDOUT_HARDCAP;
    if (out->timeout_ms <= 0)
        out->timeout_ms = 10000;
    return true;
}

/* Build the stdin envelope. Caller frees with free(). */
static char *
build_envelope(const exec_meta *m,
               const char *call_id_uuid,
               json_t *arguments,
               const char *request_user)
{
    json_t *env = json_object();
    json_object_set_new(env, "tool_name", json_string(m->tool_name ? m->tool_name : ""));
    json_object_set_new(env, "call_id",   json_string(call_id_uuid));
    if (arguments) json_object_set(env, "arguments", arguments);
    else           json_object_set_new(env, "arguments", json_object());

    json_t *ctx = json_object();
    json_object_set_new(ctx, "request_user",
        json_string(request_user ? request_user : "anonymous"));
    json_object_set_new(ctx, "protocol_version", json_string(MC2DBD_PROTOCOL_VER));
    json_object_set_new(env, "context", ctx);

    char *out = json_dumps(env, JSON_COMPACT);
    json_decref(env);
    return out;
}

/* Substitute {{key}} placeholders in `src` against `arguments`. Returns
 * a malloc'd string the caller must free. Unmatched placeholders are
 * left as-is. Non-scalar argument values are serialized to compact JSON.
 *
 * O((|src| + max-value-len) × |arguments|) — fine for argv tokens.
 */
static char *
substitute_placeholders(const char *src, json_t *arguments)
{
    char *result = strdup(src ? src : "");
    if (!arguments || !json_is_object(arguments)) return result;

    const char *key;
    json_t     *val;
    json_object_foreach(arguments, key, val) {
        /* Render value as a heap-allocated string. */
        char *value_str = NULL;
        int ar;
        (void) ar;
        if (json_is_string(val)) {
            value_str = strdup(json_string_value(val));
        } else if (json_is_integer(val)) {
            ar = asprintf(&value_str, "%lld", (long long) json_integer_value(val));
            if (ar < 0) value_str = NULL;
        } else if (json_is_real(val)) {
            ar = asprintf(&value_str, "%.17g", json_real_value(val));
            if (ar < 0) value_str = NULL;
        } else if (json_is_true(val))  { value_str = strdup("true");  }
        else if (json_is_false(val))   { value_str = strdup("false"); }
        else if (json_is_null(val))    { value_str = strdup("null");  }
        else { value_str = json_dumps(val, JSON_COMPACT); }
        if (!value_str) value_str = strdup("");

        /* Build the "{{key}}" placeholder. */
        char *placeholder = NULL;
        ar = asprintf(&placeholder, "{{%s}}", key);
        if (ar < 0 || !placeholder) { free(value_str); continue; }

        /* Replace every occurrence. */
        size_t ph_len  = strlen(placeholder);
        size_t val_len = strlen(value_str);
        for (;;) {
            char *hit = strstr(result, placeholder);
            if (!hit) break;
            size_t prefix_len = (size_t) (hit - result);
            size_t suffix_len = strlen(hit + ph_len);
            char  *next = malloc(prefix_len + val_len + suffix_len + 1);
            if (!next) break;
            memcpy(next, result, prefix_len);
            memcpy(next + prefix_len, value_str, val_len);
            memcpy(next + prefix_len + val_len, hit + ph_len, suffix_len + 1);
            free(result);
            result = next;
        }
        free(placeholder);
        free(value_str);
    }
    return result;
}

/* Build a NULL-terminated argv array. argv[0] is command_path; remaining
 * slots come from argv_template with R1.1-1.1 {{key}} placeholder
 * substitution against the tools/call arguments object. Returns malloc'd
 * argv whose entries are also malloc'd. */
static char **
build_argv(const exec_meta *m, json_t *arguments)
{
    size_t n = m->argv_template ? json_array_size(m->argv_template) : 0;
    char **argv = calloc(n + 2, sizeof(char *));
    argv[0] = strdup(m->command_path);
    for (size_t i = 0; i < n; i++) {
        json_t *e = json_array_get(m->argv_template, i);
        const char *s = json_is_string(e) ? json_string_value(e) : "";
        argv[1 + i] = substitute_placeholders(s, arguments);
    }
    argv[1 + n] = NULL;
    return argv;
}

static void
free_argv(char **argv)
{
    if (!argv) return;
    for (char **p = argv; *p; p++) free(*p);
    free(argv);
}

/* Build envp from a minimal base + the per-tool environment overrides. */
static char **
build_envp(const exec_meta *m)
{
    /* Count overrides */
    size_t over = m->environment && json_is_object(m->environment)
                  ? json_object_size(m->environment) : 0;
    /* Base: PATH, HOME, LANG, LC_ALL plus an MC2DB hint */
    const size_t BASE = 5;
    char **envp = calloc(BASE + over + 1, sizeof(char *));
    size_t i = 0;
    char buf[512];
    snprintf(buf, sizeof buf, "PATH=%s", EXEC_DEFAULT_PATH);          envp[i++] = strdup(buf);
    snprintf(buf, sizeof buf, "HOME=/tmp");                            envp[i++] = strdup(buf);
    snprintf(buf, sizeof buf, "LANG=C.UTF-8");                         envp[i++] = strdup(buf);
    snprintf(buf, sizeof buf, "LC_ALL=C.UTF-8");                       envp[i++] = strdup(buf);
    snprintf(buf, sizeof buf, "MALUDB_MC2DB_TOOL=%s",
             m->tool_name ? m->tool_name : "");                        envp[i++] = strdup(buf);

    if (m->environment && json_is_object(m->environment)) {
        const char *k;
        json_t *v;
        json_object_foreach(m->environment, k, v) {
            if (!json_is_string(v)) continue;
            /* Skip overrides of the base names to preserve scrubbed PATH etc. */
            if (strcmp(k, "PATH") == 0 || strcmp(k, "HOME") == 0 ||
                strcmp(k, "LD_PRELOAD") == 0 || strcmp(k, "LD_LIBRARY_PATH") == 0)
                continue;
            char *kv = NULL;
            int len = asprintf(&kv, "%s=%s", k, json_string_value(v));
            if (len > 0 && kv) envp[i++] = kv;
        }
    }
    envp[i] = NULL;
    return envp;
}

static int64_t
now_ms_int64(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t) ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static void
set_nonblocking(int fd)
{
    int fl = fcntl(fd, F_GETFL, 0);
    if (fl >= 0) fcntl(fd, F_SETFL, fl | O_NONBLOCK);
}

/* Run the child to completion (or timeout). Fills out_buf / err_buf
 * (caller-allocated) and returns:
 *   0 — child exited; *exit_status holds WEXITSTATUS or -1 if signalled
 *   1 — timed out (child was killed)
 *  -1 — internal error before/after spawn (errno set)
 *
 * stdin_text is written then the stdin pipe is closed; the child sees EOF.
 */
static int
run_child(const exec_meta *m,
          char **argv, char **envp,
          const char *stdin_text,
          char *out_buf,  size_t out_cap,  size_t *out_len,
          char *err_buf,  size_t err_cap,  size_t *err_len,
          int *exit_status)
{
    int sin[2]  = {-1, -1};
    int sout[2] = {-1, -1};
    int serr[2] = {-1, -1};
    if (pipe(sin) < 0 || pipe(sout) < 0 || pipe(serr) < 0)
        goto io_err;

    pid_t pid = fork();
    if (pid < 0) goto io_err;

    if (pid == 0) {
        /* Child. */
        dup2(sin[0],  STDIN_FILENO);
        dup2(sout[1], STDOUT_FILENO);
        dup2(serr[1], STDERR_FILENO);
        close(sin[0]);  close(sin[1]);
        close(sout[0]); close(sout[1]);
        close(serr[0]); close(serr[1]);

        /* Optional run_as_user. Best-effort: only honored if we are root
         * AND the user exists. Otherwise we keep our own creds and the
         * audit row is what the operator inspects. */
        if (m->run_as_user && getuid() == 0) {
            struct passwd *pw = getpwnam(m->run_as_user);
            if (pw) {
                if (setgid(pw->pw_gid) != 0) _exit(126);
                if (setuid(pw->pw_uid) != 0) _exit(126);
            }
        }
        if (m->working_dir && m->working_dir[0]) {
            if (chdir(m->working_dir) != 0) _exit(126);
        }
        execve(m->command_path, argv, envp);
        _exit(127);
    }

    /* Parent. */
    close(sin[0]);  sin[0]  = -1;
    close(sout[1]); sout[1] = -1;
    close(serr[1]); serr[1] = -1;

    set_nonblocking(sin[1]);
    set_nonblocking(sout[0]);
    set_nonblocking(serr[0]);

    size_t stdin_off = 0;
    size_t stdin_len = stdin_text ? strlen(stdin_text) : 0;

    *out_len = 0;
    *err_len = 0;

    int64_t deadline = now_ms_int64() + (int64_t) m->timeout_ms;
    int     killed_term = 0;
    int     killed_kill = 0;
    int     timed_out   = 0;

    for (;;) {
        if (sin[1] == -1 && sout[0] == -1 && serr[0] == -1) break;

        fd_set rfds, wfds;
        FD_ZERO(&rfds);
        FD_ZERO(&wfds);
        int maxfd = -1;
        if (sout[0] != -1) { FD_SET(sout[0], &rfds); if (sout[0] > maxfd) maxfd = sout[0]; }
        if (serr[0] != -1) { FD_SET(serr[0], &rfds); if (serr[0] > maxfd) maxfd = serr[0]; }
        if (sin[1]  != -1 && stdin_off < stdin_len)
                           { FD_SET(sin[1],  &wfds); if (sin[1]  > maxfd) maxfd = sin[1]; }
        else if (sin[1] != -1) {
            /* Stdin already drained — close it so the child sees EOF. */
            close(sin[1]);
            sin[1] = -1;
            continue;
        }

        int64_t now = now_ms_int64();
        int64_t remain = deadline - now;
        if (remain <= 0) {
            timed_out = 1;
            if (!killed_term) {
                kill(pid, SIGTERM);
                killed_term = 1;
                deadline = now + EXEC_KILL_GRACE_MS;
                continue;
            } else if (!killed_kill) {
                kill(pid, SIGKILL);
                killed_kill = 1;
                /* Read whatever's buffered, then exit loop after waitpid. */
                break;
            } else break;
        }

        struct timeval tv;
        tv.tv_sec  = remain / 1000;
        tv.tv_usec = (remain % 1000) * 1000;

        int s = select(maxfd + 1, &rfds, &wfds, NULL, &tv);
        if (s < 0) {
            if (errno == EINTR) continue;
            goto io_err;
        }
        if (s == 0) continue;        /* fall through to deadline check */

        if (sin[1] != -1 && FD_ISSET(sin[1], &wfds)) {
            ssize_t n = write(sin[1], stdin_text + stdin_off, stdin_len - stdin_off);
            if (n > 0) stdin_off += (size_t) n;
            else if (n < 0 && errno != EAGAIN && errno != EINTR) {
                close(sin[1]); sin[1] = -1;
            }
            if (stdin_off >= stdin_len) {
                close(sin[1]); sin[1] = -1;
            }
        }
        if (sout[0] != -1 && FD_ISSET(sout[0], &rfds)) {
            if (*out_len < out_cap - 1) {
                ssize_t n = read(sout[0], out_buf + *out_len, out_cap - 1 - *out_len);
                if (n > 0) *out_len += (size_t) n;
                else if (n == 0) { close(sout[0]); sout[0] = -1; }
                else if (errno != EAGAIN && errno != EINTR) {
                    close(sout[0]); sout[0] = -1;
                }
            } else {
                /* Buffer full — terminate child to enforce max_output_bytes. */
                if (!killed_term) { kill(pid, SIGTERM); killed_term = 1; }
                close(sout[0]); sout[0] = -1;
            }
        }
        if (serr[0] != -1 && FD_ISSET(serr[0], &rfds)) {
            if (*err_len < err_cap - 1) {
                ssize_t n = read(serr[0], err_buf + *err_len, err_cap - 1 - *err_len);
                if (n > 0) *err_len += (size_t) n;
                else if (n == 0) { close(serr[0]); serr[0] = -1; }
                else if (errno != EAGAIN && errno != EINTR) {
                    close(serr[0]); serr[0] = -1;
                }
            } else {
                /* Drain and discard further stderr. */
                char trash[256];
                ssize_t n = read(serr[0], trash, sizeof trash);
                if (n <= 0 && (n == 0 || (errno != EAGAIN && errno != EINTR))) {
                    close(serr[0]); serr[0] = -1;
                }
            }
        }
    }

    /* Make sure pipes are closed before we waitpid — the child might be
     * blocked on write otherwise. */
    if (sin[1]  != -1) close(sin[1]);
    if (sout[0] != -1) close(sout[0]);
    if (serr[0] != -1) close(serr[0]);

    out_buf[*out_len] = 0;
    err_buf[*err_len] = 0;

    int status = 0;
    pid_t wp;
    do { wp = waitpid(pid, &status, 0); } while (wp == -1 && errno == EINTR);

    if (timed_out) {
        *exit_status = -1;
        return 1;
    }
    if (WIFEXITED(status))
        *exit_status = WEXITSTATUS(status);
    else if (WIFSIGNALED(status))
        *exit_status = -1;
    else
        *exit_status = -1;
    return 0;

io_err:
    {
        int e = errno;
        if (sin[0]  != -1) close(sin[0]);
        if (sin[1]  != -1) close(sin[1]);
        if (sout[0] != -1) close(sout[0]);
        if (sout[1] != -1) close(sout[1]);
        if (serr[0] != -1) close(serr[0]);
        if (serr[1] != -1) close(serr[1]);
        errno = e;
        return -1;
    }
}

void
dispatch_external_exec(PGconn *conn,
                       const char *call_id_uuid,
                       json_t *tool_meta,
                       json_t *arguments,
                       const char *request_user,
                       mc2dbd_tool_result *out)
{
    int64_t tool_id = (int64_t) json_integer_value(json_object_get(tool_meta, "tool_id"));
    if (tool_id <= 0) {
        set_err(out, MC2DB_ERR_INTERNAL, "external_exec dispatch missing tool_id");
        return;
    }

    char errbuf[512] = {0};
    exec_meta meta;
    if (!load_exec_meta(conn, tool_id, &meta, errbuf, sizeof errbuf)) {
        set_err(out, MC2DB_ERR_INTERNAL, errbuf);
        return;
    }
    if (!meta.command_path || meta.command_path[0] != '/') {
        set_err(out, MC2DB_ERR_INTERNAL,
                "external_exec command_path must be absolute");
        exec_meta_free(&meta);
        return;
    }
    if (access(meta.command_path, X_OK) != 0) {
        char m[512];
        snprintf(m, sizeof m,
                 "external_exec command not executable: %s (%s)",
                 meta.command_path, strerror(errno));
        set_err(out, MC2DB_ERR_INTERNAL, m);
        exec_meta_free(&meta);
        return;
    }

    char *envelope = build_envelope(&meta, call_id_uuid, arguments, request_user);
    if (!envelope) {
        set_err(out, MC2DB_ERR_INTERNAL, "failed to build stdin envelope");
        exec_meta_free(&meta);
        return;
    }

    char **argv = build_argv(&meta, arguments);
    char **envp = build_envp(&meta);

    char  *out_buf = malloc((size_t) meta.max_output_bytes + 1);
    char   err_buf[EXEC_STDERR_CAP + 1];
    if (!out_buf) {
        set_err(out, MC2DB_ERR_INTERNAL, "out-of-memory allocating stdout buffer");
        free(envelope); free_argv(argv); free_argv(envp); exec_meta_free(&meta);
        return;
    }
    size_t out_len = 0, err_len = 0;
    int    exit_status = -1;

    int rc = run_child(&meta, argv, envp, envelope,
                       out_buf, (size_t) meta.max_output_bytes + 1, &out_len,
                       err_buf, sizeof err_buf, &err_len,
                       &exit_status);

    free_argv(argv);
    free_argv(envp);
    free(envelope);

    if (rc == -1) {
        char m[256];
        snprintf(m, sizeof m, "external_exec spawn failed: %s", strerror(errno));
        set_err(out, MC2DB_ERR_INTERNAL, m);
        free(out_buf);
        exec_meta_free(&meta);
        return;
    }
    if (rc == 1) {
        char m[256];
        snprintf(m, sizeof m,
                 "external_exec timed out after %d ms (stderr: %.200s)",
                 meta.timeout_ms, err_len ? err_buf : "");
        set_err(out, MC2DB_ERR_TOOL_EXECUTION, m);
        free(out_buf);
        exec_meta_free(&meta);
        return;
    }
    if (exit_status != 0) {
        char m[512];
        snprintf(m, sizeof m,
                 "external_exec exit %d (stderr: %.300s)",
                 exit_status, err_len ? err_buf : "");
        set_err(out, MC2DB_ERR_TOOL_EXECUTION, m);
        free(out_buf);
        exec_meta_free(&meta);
        return;
    }

    /* Parse stdout JSON envelope. */
    json_error_t je;
    json_t *resp = json_loadb(out_buf, out_len, 0, &je);
    free(out_buf);

    if (!resp || !json_is_object(resp)) {
        char m[256];
        snprintf(m, sizeof m,
                 "external_exec produced non-JSON stdout: %.200s",
                 je.text[0] ? je.text : "parse error");
        set_err(out, MC2DB_ERR_TOOL_EXECUTION, m);
        if (resp) json_decref(resp);
        exec_meta_free(&meta);
        return;
    }

    json_t *ok_v = json_object_get(resp, "ok");
    bool    ok   = json_is_true(ok_v);
    if (!ok) {
        json_t *err_obj = json_object_get(resp, "error");
        const char *code = "TOOL_EXECUTION_ERROR";
        const char *msg  = "external_exec reported failure";
        if (json_is_object(err_obj)) {
            const char *c = json_string_value(json_object_get(err_obj, "code"));
            const char *m = json_string_value(json_object_get(err_obj, "message"));
            if (c && *c) code = c;
            if (m && *m) msg  = m;
        }
        set_err(out, code, msg);
        json_decref(resp);
        exec_meta_free(&meta);
        return;
    }

    /* Success. Pull result.{content,structuredContent} or use the bare
     * `result` as structuredContent when neither is present. */
    json_t *result = json_object_get(resp, "result");
    if (result && json_is_object(result)) {
        json_t *content = json_object_get(result, "content");
        json_t *sc      = json_object_get(result, "structuredContent");
        if (content && json_is_array(content))
            out->content = json_incref(content);
        if (sc) out->structured = json_incref(sc);
        if (!out->content && !out->structured) {
            /* Fallback: surface whatever result was as structuredContent. */
            out->structured = json_incref(result);
            json_t *block = json_object();
            json_object_set_new(block, "type", json_string("text"));
            json_object_set_new(block, "text", json_string("ok"));
            out->content = json_array();
            json_array_append_new(out->content, block);
        } else if (!out->content) {
            json_t *block = json_object();
            json_object_set_new(block, "type", json_string("text"));
            json_object_set_new(block, "text", json_string("ok"));
            out->content = json_array();
            json_array_append_new(out->content, block);
        }
    } else {
        json_t *block = json_object();
        json_object_set_new(block, "type", json_string("text"));
        json_object_set_new(block, "text", json_string("ok"));
        out->content = json_array();
        json_array_append_new(out->content, block);
    }

    json_decref(resp);
    exec_meta_free(&meta);
}
