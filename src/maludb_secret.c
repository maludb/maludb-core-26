/* maludb_secret.c — V3-SECRET-02 C-backed external secret resolver.
 *
 * Provides:
 *   maludb_secret_resolve_external(text uri) RETURNS text
 *     Reads a secret from the given URI:
 *       file://<absolute-path>   — local filesystem; mode + ownership
 *                                  hardened.
 *       https://<url>            — outbound GET via libcurl; the
 *                                  response body is the secret.
 *     Any other scheme is rejected. Inline / pgp_sym_decrypt secrets
 *     stay in PL/pgSQL (the master-key passphrase lives in a
 *     SECURITY DEFINER helper).
 *
 * Build: links against libcurl (-lcurl in SHLIB_LINK).
 */

#include "postgres.h"
#include "fmgr.h"
#include "miscadmin.h"
#include "utils/builtins.h"
#include "utils/guc.h"
#include "utils/memutils.h"

#include <curl/curl.h>

#include <errno.h>
#include <fcntl.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>


PG_FUNCTION_INFO_V1(maludb_secret_resolve_external);


/* Configurable allowlist of directories under which file:// secrets
 * may live. Set the GUC maludb_core.secret_file_root to a colon-
 * separated list of absolute paths. Default is two well-known dirs
 * matching the V3 install layout. */
static const char *
secret_file_root_default(void)
{
    return "/etc/maludb/secrets:/var/lib/maludb/secrets";
}

/* path normalisation: returns 0 on success, -1 on rejection. The
 * caller passes the post-"file://" path; we require absolute, no
 * '..' segments, no null bytes, no symlink components. */
static int
path_check_allowed(const char *path, char *err, size_t errlen)
{
    if (!path || path[0] != '/')
    {
        snprintf(err, errlen, "file:// path must be absolute");
        return -1;
    }
    if (strstr(path, "/../") != NULL || strstr(path, "/./") != NULL)
    {
        snprintf(err, errlen, "file:// path may not contain '..' or '.' segments");
        return -1;
    }
    /* Allowlist match. */
    const char *roots_env = GetConfigOption("maludb_core.secret_file_root", true, false);
    const char *roots = (roots_env && *roots_env) ? roots_env : secret_file_root_default();
    const char *p = roots;
    int matched = 0;
    while (p && *p)
    {
        const char *colon = strchr(p, ':');
        size_t      root_len = colon ? (size_t)(colon - p) : strlen(p);
        if (root_len > 0 && strncmp(path, p, root_len) == 0
            && (path[root_len] == '/' || path[root_len] == '\0'))
        {
            matched = 1;
            break;
        }
        p = colon ? colon + 1 : NULL;
    }
    if (!matched)
    {
        snprintf(err, errlen, "file:// path '%s' is outside the configured "
                 "maludb_core.secret_file_root allowlist", path);
        return -1;
    }
    return 0;
}

/* Read a regular file with hardened mode/owner checks. Returns
 * palloc'd text* on success; sets *err and returns NULL on rejection.
 * The file must be:
 *   * a regular file (not a symlink or special),
 *   * owned by the postgres OS user (effective uid of the backend),
 *   * mode 0400 or 0600 (no group / world bits beyond owner read).
 * Trailing newlines are stripped to keep the resolved value clean.
 */
static text *
read_file_secret(const char *path, char *err, size_t errlen)
{
    struct stat st;
    int    fd;
    ssize_t n;
    size_t  cap, len;
    char   *buf;

    /* lstat: must not be a symlink. */
    if (lstat(path, &st) != 0)
    {
        snprintf(err, errlen, "lstat(%s) failed: %s", path, strerror(errno));
        return NULL;
    }
    if (!S_ISREG(st.st_mode))
    {
        snprintf(err, errlen, "secret file %s is not a regular file", path);
        return NULL;
    }
    if (st.st_uid != geteuid())
    {
        snprintf(err, errlen,
                 "secret file %s owner uid=%u does not match postgres uid=%u",
                 path, (unsigned) st.st_uid, (unsigned) geteuid());
        return NULL;
    }
    if (st.st_mode & (S_IRWXG | S_IRWXO))
    {
        snprintf(err, errlen,
                 "secret file %s has permissions 0%o; must be 0400 or 0600",
                 path, (unsigned) (st.st_mode & 0777));
        return NULL;
    }

    fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0)
    {
        snprintf(err, errlen, "open(%s) failed: %s", path, strerror(errno));
        return NULL;
    }

    cap = (st.st_size > 0 && st.st_size < (1 << 20)) ? (size_t) st.st_size : 65536;
    if (cap > (1 << 20))                                /* 1 MiB cap */
    {
        close(fd);
        snprintf(err, errlen, "secret file %s exceeds 1 MiB", path);
        return NULL;
    }
    buf = palloc(cap + 1);
    len = 0;
    while ((n = read(fd, buf + len, cap - len)) > 0)
    {
        len += (size_t) n;
        if (len >= cap)
            break;
    }
    close(fd);
    if (n < 0)
    {
        snprintf(err, errlen, "read(%s) failed: %s", path, strerror(errno));
        return NULL;
    }
    /* Trim trailing whitespace / newlines. */
    while (len > 0 && (buf[len - 1] == '\n' || buf[len - 1] == '\r' || buf[len - 1] == ' '))
        len--;

    text *t = (text *) palloc(VARHDRSZ + len);
    SET_VARSIZE(t, VARHDRSZ + len);
    memcpy(VARDATA(t), buf, len);
    pfree(buf);
    return t;
}


/* libcurl write callback: append to a heap buffer. */
typedef struct
{
    char  *buf;
    size_t len;
    size_t cap;
    size_t cap_max;
}   curl_sink_t;

static size_t
curl_sink_write(char *ptr, size_t size, size_t nmemb, void *userdata)
{
    curl_sink_t *s = (curl_sink_t *) userdata;
    size_t       want = size * nmemb;

    if (s->len + want > s->cap_max)
        return 0;                                        /* exceed -> abort */
    while (s->len + want >= s->cap)
    {
        size_t new_cap = s->cap ? s->cap * 2 : 4096;
        if (new_cap > s->cap_max) new_cap = s->cap_max;
        s->buf = repalloc(s->buf, new_cap + 1);
        s->cap = new_cap;
    }
    memcpy(s->buf + s->len, ptr, want);
    s->len += want;
    return want;
}

/* Fetch the URL via libcurl GET. Returns palloc'd text* on success;
 * sets *err and returns NULL on rejection. */
static text *
read_https_secret(const char *url, char *err, size_t errlen)
{
    CURL       *curl;
    CURLcode    rc;
    long        status = 0;
    curl_sink_t sink;
    text       *result = NULL;

    if (strncmp(url, "https://", 8) != 0)
    {
        snprintf(err, errlen, "secret URL must start with https:// (plain http is rejected)");
        return NULL;
    }

    sink.buf     = palloc(4096);
    sink.len     = 0;
    sink.cap     = 4096;
    sink.cap_max = 1 << 20;                              /* 1 MiB */

    curl_global_init(CURL_GLOBAL_DEFAULT);                /* idempotent; safe per call */
    curl = curl_easy_init();
    if (!curl)
    {
        snprintf(err, errlen, "curl_easy_init failed");
        pfree(sink.buf);
        return NULL;
    }
    curl_easy_setopt(curl, CURLOPT_URL,                 url);
    curl_easy_setopt(curl, CURLOPT_HTTPGET,             1L);
    curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION,      0L);
    curl_easy_setopt(curl, CURLOPT_NOSIGNAL,            1L);
    curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT,      5L);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT,             10L);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION,       curl_sink_write);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA,           &sink);
    curl_easy_setopt(curl, CURLOPT_USERAGENT,           "maludb-secret-resolver/0.1");
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER,      1L);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYHOST,      2L);

    rc = curl_easy_perform(curl);
    if (rc != CURLE_OK)
    {
        snprintf(err, errlen, "https GET failed: %s", curl_easy_strerror(rc));
        curl_easy_cleanup(curl);
        pfree(sink.buf);
        return NULL;
    }
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &status);
    curl_easy_cleanup(curl);

    if (status < 200 || status >= 300)
    {
        snprintf(err, errlen, "https GET returned HTTP %ld", status);
        pfree(sink.buf);
        return NULL;
    }

    /* Trim trailing newline / whitespace. */
    while (sink.len > 0 && (sink.buf[sink.len - 1] == '\n'
                            || sink.buf[sink.len - 1] == '\r'
                            || sink.buf[sink.len - 1] == ' '))
        sink.len--;

    result = (text *) palloc(VARHDRSZ + sink.len);
    SET_VARSIZE(result, VARHDRSZ + sink.len);
    memcpy(VARDATA(result), sink.buf, sink.len);
    pfree(sink.buf);
    return result;
}


Datum
maludb_secret_resolve_external(PG_FUNCTION_ARGS)
{
    text   *uri_arg = PG_GETARG_TEXT_PP(0);
    const char *uri = VARDATA_ANY(uri_arg);
    size_t      uri_len = VARSIZE_ANY_EXHDR(uri_arg);
    char       *uri_c   = palloc(uri_len + 1);
    char        err[256];
    text       *result = NULL;

    err[0] = '\0';
    memcpy(uri_c, uri, uri_len);
    uri_c[uri_len] = '\0';

    if (strncmp(uri_c, "file://", 7) == 0)
    {
        const char *path = uri_c + 7;
        if (path_check_allowed(path, err, sizeof(err)) != 0)
            ereport(ERROR,
                    (errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
                     errmsg("maludb_secret_resolve_external: %s", err)));
        result = read_file_secret(path, err, sizeof(err));
    }
    else if (strncmp(uri_c, "https://", 8) == 0)
    {
        result = read_https_secret(uri_c, err, sizeof(err));
    }
    else
    {
        ereport(ERROR,
                (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                 errmsg("maludb_secret_resolve_external: unsupported scheme in '%s'", uri_c),
                 errhint("Supported schemes: file://, https://. env:// support will land alongside V3-AUTH-03.")));
    }

    pfree(uri_c);

    if (result == NULL)
        ereport(ERROR,
                (errcode(ERRCODE_DATA_EXCEPTION),
                 errmsg("maludb_secret_resolve_external: %s",
                        err[0] ? err : "unknown failure")));

    PG_RETURN_TEXT_P(result);
}
