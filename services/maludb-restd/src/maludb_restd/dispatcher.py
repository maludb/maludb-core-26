"""Catalog-driven dispatcher for maludb-restd.

Responsibilities:
  * Resolve (method, path) against malu$rest_endpoint.
  * If auth_required, verify a presented bearer token via
    maludb_core.auth_token_verify.
  * Bind the tenant GUC for the request scope.
  * Call the registered handler function and return its result.
  * Write a malu$rest_invocation row via maludb_core.rest_log_invocation.

This first cut handles handler functions that take no SQL arguments
and return either a scalar or a single jsonb. Full request-body
binding lands in V3-API-01b's follow-up alongside the curated
endpoint catalog.
"""

from __future__ import annotations

import dataclasses
import hashlib
import json
import time
import uuid
from typing import Any

import psycopg

from .db import Pool, set_account_guc


@dataclasses.dataclass(frozen=True)
class EndpointRow:
    endpoint_id: int
    method: str
    path: str
    handler_function: str          # regprocedure cast to text, e.g. "maludb_core.maludb_core_version()"
    auth_required: bool
    required_scopes: list[str]
    risk_class: str
    timeout_ms: int
    enabled: bool
    arg_schema: list[dict]         # V3-API-02; empty list = zero-arg call


@dataclasses.dataclass(frozen=True)
class AuthContext:
    token_id: int | None
    account_id: int | None
    token_kind: str | None
    scopes: list[str]


@dataclasses.dataclass(frozen=True)
class DispatchResult:
    status_code: int
    body: Any                       # JSON-serialisable
    error_code: str | None = None
    error_message: str | None = None


class Dispatcher:
    """Stateless dispatcher; one instance per server."""

    def __init__(self, pool: Pool) -> None:
        self._pool = pool

    # -- Public surfaces ------------------------------------------------

    def healthz(self) -> DispatchResult:
        try:
            with self._pool.connection() as conn:
                with conn.cursor() as cur:
                    cur.execute("SELECT 1")
                    cur.fetchone()
            return DispatchResult(200, {"status": "ok"})
        except Exception as e:
            return DispatchResult(503, {"status": "down", "error": str(e)})

    def version(self) -> DispatchResult:
        with self._pool.connection() as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT maludb_core.maludb_core_version()")
                v = cur.fetchone()[0]
        return DispatchResult(200, {"version": v})

    def openapi(self) -> DispatchResult:
        with self._pool.connection() as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT maludb_core.rest_openapi_spec()")
                spec = cur.fetchone()[0]
        return DispatchResult(200, spec)

    def dispatch(
        self,
        method: str,
        path: str,
        request_body: bytes,
        bearer_token: str | None,
        source_ip: str | None,
    ) -> DispatchResult:
        started = time.monotonic()
        started_at = "now()"
        endpoint: EndpointRow | None = None
        auth: AuthContext | None = None

        try:
            endpoint = self._find_endpoint(method, path)
            if endpoint is None:
                return self._record_and_return(
                    started, method, path, request_body,
                    endpoint=None, auth=None, source_ip=source_ip,
                    result=DispatchResult(
                        404,
                        {"error": "endpoint_not_found", "method": method, "path": path},
                        error_code="ENDPOINT_NOT_FOUND",
                        error_message="No registered endpoint matches",
                    ),
                )

            if not endpoint.enabled:
                return self._record_and_return(
                    started, method, path, request_body,
                    endpoint=endpoint, auth=None, source_ip=source_ip,
                    result=DispatchResult(
                        503,
                        {"error": "endpoint_disabled"},
                        error_code="ENDPOINT_DISABLED",
                        error_message="Endpoint is registered but disabled",
                    ),
                )

            if endpoint.auth_required:
                if not bearer_token:
                    return self._record_and_return(
                        started, method, path, request_body,
                        endpoint=endpoint, auth=None, source_ip=source_ip,
                        result=DispatchResult(
                            401,
                            {"error": "missing_token"},
                            error_code="AUTH_MISSING_TOKEN",
                            error_message="Authorization: Bearer required",
                        ),
                    )
                auth = self._verify_token(bearer_token, source_ip)
                if auth is None or auth.account_id is None:
                    return self._record_and_return(
                        started, method, path, request_body,
                        endpoint=endpoint, auth=None, source_ip=source_ip,
                        result=DispatchResult(
                            401,
                            {"error": "invalid_token"},
                            error_code="AUTH_INVALID_TOKEN",
                            error_message="Token unknown, expired, revoked, or CIDR-rejected",
                        ),
                    )
                missing = [s for s in endpoint.required_scopes if s not in (auth.scopes or [])]
                if missing:
                    return self._record_and_return(
                        started, method, path, request_body,
                        endpoint=endpoint, auth=auth, source_ip=source_ip,
                        result=DispatchResult(
                            403,
                            {"error": "scope_missing", "required_scopes": missing},
                            error_code="AUTH_SCOPE_MISSING",
                            error_message=f"Token missing required scopes: {','.join(missing)}",
                        ),
                    )

            # Call the handler.
            try:
                body = self._call_handler(endpoint, request_body, auth)
            except psycopg.Error as e:
                return self._record_and_return(
                    started, method, path, request_body,
                    endpoint=endpoint, auth=auth, source_ip=source_ip,
                    result=DispatchResult(
                        500,
                        {"error": "handler_error", "sqlstate": e.diag.sqlstate if e.diag else None},
                        error_code=f"SQL_{e.diag.sqlstate}" if e.diag and e.diag.sqlstate else "SQL_ERROR",
                        error_message=str(e),
                    ),
                )

            return self._record_and_return(
                started, method, path, request_body,
                endpoint=endpoint, auth=auth, source_ip=source_ip,
                result=DispatchResult(200, body),
            )

        except Exception as e:
            return self._record_and_return(
                started, method, path, request_body,
                endpoint=endpoint, auth=auth, source_ip=source_ip,
                result=DispatchResult(
                    500,
                    {"error": "internal", "detail": str(e)},
                    error_code="INTERNAL",
                    error_message=str(e),
                ),
            )

    # -- Internals ------------------------------------------------------

    def _find_endpoint(self, method: str, path: str) -> EndpointRow | None:
        with self._pool.connection() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    SELECT endpoint_id, method, path, handler_function::text,
                           auth_required, required_scopes, risk_class, timeout_ms, enabled,
                           arg_schema
                      FROM maludb_core.malu$rest_endpoint
                     WHERE method = %s AND path = %s
                       AND retired_at IS NULL
                     LIMIT 1
                    """,
                    (method, path),
                )
                row = cur.fetchone()
                if row is None:
                    return None
                rec = list(row)
                schema = rec[-1] or []
                if isinstance(schema, str):
                    schema = json.loads(schema)
                rec[-1] = list(schema)
                return EndpointRow(*rec)

    def _verify_token(self, plaintext: str, source_ip: str | None) -> AuthContext | None:
        with self._pool.connection() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    SELECT token_id, account_id, token_kind, scopes
                      FROM maludb_core.auth_token_verify(%s, %s::inet)
                    """,
                    (plaintext, source_ip),
                )
                row = cur.fetchone()
        if row is None:
            return AuthContext(None, None, None, [])
        return AuthContext(token_id=row[0], account_id=row[1], token_kind=row[2], scopes=list(row[3] or []))

    def _call_handler(
        self,
        endpoint: EndpointRow,
        request_body: bytes,
        auth: AuthContext | None,
    ) -> Any:
        # handler_function looks like "maludb_core.fn_name(arg1_type, ...)"
        # — strip the parenthesised arg-type list. The named-arg call below
        # supplies the actual values.
        raw = endpoint.handler_function
        fn = raw.split("(", 1)[0].strip() if "(" in raw else raw.strip()

        # Parse the request body if the endpoint declares typed args.
        body_obj: dict[str, Any] = {}
        if endpoint.arg_schema and request_body:
            try:
                parsed = json.loads(request_body)
                if isinstance(parsed, dict):
                    body_obj = parsed
            except json.JSONDecodeError as e:
                raise ValueError(f"request body is not valid JSON: {e}") from e

        named_parts: list[str] = []
        params: list[Any] = []
        for spec in endpoint.arg_schema:
            name = spec["name"]
            wire_name = name[2:] if name.startswith("p_") else name
            required = bool(spec.get("required", False))
            if wire_name in body_obj:
                value = _coerce_arg(body_obj[wire_name], spec.get("type", "text"))
            elif required:
                raise ValueError(f"missing required argument: {wire_name}")
            else:
                value = None
            named_parts.append(f"{name} := %s")
            params.append(value)

        sql = f"SELECT {fn}({', '.join(named_parts)})" if named_parts else f"SELECT {fn}()"

        with self._pool.connection() as conn:
            account_id = auth.account_id if auth else None
            set_account_guc(conn, account_id)
            with conn.cursor() as cur:
                cur.execute(f"SET LOCAL statement_timeout = '{endpoint.timeout_ms}ms'")
                cur.execute(sql, params)
                rows = cur.fetchall()
                if not rows:
                    return None
                if len(rows) == 1 and len(rows[0]) == 1:
                    return rows[0][0]
                # SETOF / TABLE return: serialise as list[dict] when we
                # have column names, else list[list].
                cols = [d.name for d in cur.description] if cur.description else None
                if cols:
                    return [dict(zip(cols, r)) for r in rows]
                return [list(r) for r in rows]

    def _record_and_return(
        self,
        started: float,
        method: str,
        path: str,
        request_body: bytes,
        *,
        endpoint: EndpointRow | None,
        auth: AuthContext | None,
        source_ip: str | None,
        result: DispatchResult,
    ) -> DispatchResult:
        latency_ms = int((time.monotonic() - started) * 1000)
        body_bytes = json.dumps(result.body).encode("utf-8") if result.body is not None else b""

        try:
            with self._pool.connection() as conn:
                with conn.cursor() as cur:
                    cur.execute(
                        """
                        SELECT maludb_core.rest_log_invocation(
                            %s, %s, %s, %s, %s, %s, %s::inet,
                            %s::bytea, %s::bytea,
                            %s::smallint, %s,
                            now() - make_interval(0, 0, 0, 0, 0, 0, %s / 1000.0),
                            now(),
                            %s, %s, %s
                        )
                        """,
                        (
                            endpoint.endpoint_id if endpoint else None,
                            auth.account_id if auth else None,
                            auth.token_id if auth else None,
                            method,
                            path,
                            None,                                # request_user — left to a later cut
                            source_ip,
                            _sha256(request_body),
                            _sha256(body_bytes),
                            result.status_code,
                            latency_ms,
                            latency_ms,
                            200 <= result.status_code < 400,
                            result.error_code,
                            result.error_message,
                        ),
                    )
        except psycopg.Error:
            # Audit-write failure must NOT shadow the response. Operators
            # will see this in PG logs; observability for the audit
            # writer itself is a V3-OBS-01 / V3-LOG-01 concern.
            pass

        return result


def _sha256(buf: bytes) -> bytes:
    return hashlib.sha256(buf or b"").digest()


def _coerce_arg(value: Any, declared_type: str) -> Any:
    """Coerce a JSON-decoded value into the PG type the handler expects.

    psycopg handles the actual SQL binding; we just normalise Python types
    so the bound parameter lines up with the function signature. For
    container types (text[], jsonb) we trust psycopg's default adaptation.
    """
    if value is None:
        return None
    if declared_type in ("text", "name"):
        return value if isinstance(value, str) else str(value)
    if declared_type == "bigint":
        return int(value)
    if declared_type == "integer":
        return int(value)
    if declared_type == "boolean":
        return bool(value)
    if declared_type == "numeric":
        return value                              # psycopg adapts Decimal/float
    if declared_type == "jsonb":
        return json.dumps(value) if not isinstance(value, str) else value
    if declared_type == "timestamptz":
        return value                              # ISO 8601 string is fine
    if declared_type == "text[]":
        if isinstance(value, (list, tuple)):
            return [str(v) for v in value]
        raise ValueError("text[] expects a JSON array")
    if declared_type == "bigint[]":
        if isinstance(value, (list, tuple)):
            return [int(v) for v in value]
        raise ValueError("bigint[] expects a JSON array")
    if declared_type == "bytea_hex":
        return bytes.fromhex(value) if isinstance(value, str) else bytes(value)
    return value
