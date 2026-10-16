"""S3 adapter — stdlib AWS Signature v4 + GET/PUT/HEAD/presign.

The shipping CLI talks to S3 directly via stdlib urllib + hmac +
hashlib. No boto3 dependency.

Adapter config (`malu$storage_adapter.config jsonb`):
    {"bucket": "...", "region": "us-east-1", "key_prefix": "..."}

Adapter secret_ref resolves to a JSON blob:
    {"access_key": "AKIA...", "secret_key": "..."}
optionally with "session_token" for STS-issued creds.
"""

from __future__ import annotations

import datetime as dt
import hashlib
import hmac
import json
import urllib.parse
import urllib.request
from typing import Optional


SERVICE = "s3"
ALG     = "AWS4-HMAC-SHA256"
UNSIGNED_PAYLOAD = "UNSIGNED-PAYLOAD"


class S3Error(RuntimeError):
    pass


def _sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _sign(key: bytes, msg: str) -> bytes:
    return hmac.new(key, msg.encode("utf-8"), hashlib.sha256).digest()


def _signing_key(secret_key: str, date_stamp: str, region: str) -> bytes:
    k_date    = _sign(("AWS4" + secret_key).encode("utf-8"), date_stamp)
    k_region  = _sign(k_date, region)
    k_service = _sign(k_region, SERVICE)
    return _sign(k_service, "aws4_request")


def _resolve_endpoint(adapter_config: dict) -> tuple[str, str, str]:
    """Return (scheme, host, base_path).

    `endpoint_url` overrides the AWS-style host (useful for minio and
    local mocks). When set, `addressing_style` controls whether the
    request URL is path-style (default for overrides, prepends
    "/<bucket>" to the key) or virtual-hosted.
    """
    bucket = adapter_config["bucket"]
    region = adapter_config.get("region", "us-east-1")
    ep     = adapter_config.get("endpoint_url")
    if ep:
        parsed = urllib.parse.urlsplit(ep)
        scheme = parsed.scheme or "https"
        host   = parsed.netloc
        style  = adapter_config.get("addressing_style", "path")
        base   = f"/{bucket}" if style == "path" else ""
        return scheme, host, base
    if region == "us-east-1":
        host = f"{bucket}.s3.amazonaws.com"
    else:
        host = f"{bucket}.s3.{region}.amazonaws.com"
    return "https", host, ""


def _host(bucket: str, region: str) -> str:
    # Backwards-compat shim retained for the signing-vector unit tests.
    if region == "us-east-1":
        return f"{bucket}.s3.amazonaws.com"
    return f"{bucket}.s3.{region}.amazonaws.com"


def _now_utc() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def _canonical_uri(key: str) -> str:
    # Each path segment urlencoded individually; '/' preserved.
    return "/" + "/".join(
        urllib.parse.quote(seg, safe="-._~") for seg in key.split("/") if seg
    )


def _canonical_query(params: dict[str, str]) -> str:
    items = sorted(params.items())
    return "&".join(
        f"{urllib.parse.quote(k, safe='-._~')}={urllib.parse.quote(v, safe='-._~')}"
        for k, v in items
    )


def _request(method: str, adapter_config: dict, credentials: dict,
             key: str, body: Optional[bytes] = None,
             extra_headers: Optional[dict] = None,
             expect_status: tuple[int, ...] = (200, 204)) -> tuple[int, dict, bytes]:
    region = adapter_config.get("region", "us-east-1")
    scheme, host, base = _resolve_endpoint(adapter_config)
    now    = _now_utc()
    amz_date    = now.strftime("%Y%m%dT%H%M%SZ")
    date_stamp  = now.strftime("%Y%m%d")
    payload_hash = _sha256_hex(body or b"")

    canonical_uri = base + _canonical_uri(key)

    headers = {
        "Host":                 host,
        "x-amz-date":           amz_date,
        "x-amz-content-sha256": payload_hash,
    }
    if credentials.get("session_token"):
        headers["x-amz-security-token"] = credentials["session_token"]
    if extra_headers:
        for k, v in extra_headers.items():
            headers[k] = v

    signed_headers_list = sorted(headers.keys(), key=str.lower)
    canonical_headers = "".join(
        f"{h.lower()}:{headers[h].strip()}\n" for h in signed_headers_list)
    signed_headers = ";".join(h.lower() for h in signed_headers_list)

    canonical_request = "\n".join([
        method,
        canonical_uri,
        "",                          # empty canonical query for non-presigned
        canonical_headers,
        signed_headers,
        payload_hash,
    ])

    credential_scope = f"{date_stamp}/{region}/{SERVICE}/aws4_request"
    string_to_sign = "\n".join([
        ALG,
        amz_date,
        credential_scope,
        _sha256_hex(canonical_request.encode("utf-8")),
    ])
    signing_key = _signing_key(credentials["secret_key"], date_stamp, region)
    signature = hmac.new(signing_key, string_to_sign.encode("utf-8"),
                         hashlib.sha256).hexdigest()

    auth = (f"{ALG} Credential={credentials['access_key']}/{credential_scope}, "
            f"SignedHeaders={signed_headers}, Signature={signature}")
    headers["Authorization"] = auth

    url = f"{scheme}://{host}{canonical_uri}"
    req = urllib.request.Request(url, method=method, data=body, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            data = resp.read()
            code = getattr(resp, "status", 200)
    except urllib.error.HTTPError as e:
        data = e.read()
        code = e.code
    if code not in expect_status:
        raise S3Error(f"S3 {method} {key} -> HTTP {code}: {data[:256]!r}")
    return code, dict(resp.headers) if isinstance(resp, urllib.request.http.client.HTTPResponse) else {}, data


def _full_key(adapter_config: dict, content_hash_hex: str) -> str:
    prefix = adapter_config.get("key_prefix", "").strip("/")
    sharded = f"{content_hash_hex[0:2]}/{content_hash_hex[2:4]}/{content_hash_hex}"
    return f"{prefix}/{sharded}" if prefix else sharded


# -- Public surface ------------------------------------------------------

def put_bytes(adapter_config: dict, credentials: dict,
              content_hash_hex: str, data: bytes) -> str:
    """Upload bytes; return the adapter_uri (the relative S3 key)."""
    key = _full_key(adapter_config, content_hash_hex)
    _request("PUT", adapter_config, credentials, key, body=data)
    return key


def get_bytes(adapter_config: dict, credentials: dict,
              adapter_uri: str) -> bytes:
    _, _, body = _request("GET", adapter_config, credentials, adapter_uri)
    return body


def head(adapter_config: dict, credentials: dict,
         adapter_uri: str) -> bool:
    try:
        _request("HEAD", adapter_config, credentials, adapter_uri,
                 expect_status=(200,))
        return True
    except S3Error:
        return False


def presign_get(adapter_config: dict, credentials: dict,
                adapter_uri: str, expires_in_s: int = 600) -> str:
    """Build a SigV4 pre-signed GET URL. expires_in_s clamped to [1, 604800]."""
    if expires_in_s < 1 or expires_in_s > 604800:
        raise S3Error("expires_in_s must be between 1 and 604800 seconds")

    region = adapter_config.get("region", "us-east-1")
    scheme, host, base = _resolve_endpoint(adapter_config)
    now    = _now_utc()
    amz_date   = now.strftime("%Y%m%dT%H%M%SZ")
    date_stamp = now.strftime("%Y%m%d")
    canonical_uri = base + _canonical_uri(adapter_uri)
    credential_scope = f"{date_stamp}/{region}/{SERVICE}/aws4_request"

    query = {
        "X-Amz-Algorithm":      ALG,
        "X-Amz-Credential":     f"{credentials['access_key']}/{credential_scope}",
        "X-Amz-Date":           amz_date,
        "X-Amz-Expires":        str(expires_in_s),
        "X-Amz-SignedHeaders":  "host",
    }
    if credentials.get("session_token"):
        query["X-Amz-Security-Token"] = credentials["session_token"]

    canonical_query = _canonical_query(query)
    canonical_headers = f"host:{host}\n"
    canonical_request = "\n".join([
        "GET",
        canonical_uri,
        canonical_query,
        canonical_headers,
        "host",
        UNSIGNED_PAYLOAD,
    ])
    string_to_sign = "\n".join([
        ALG,
        amz_date,
        credential_scope,
        _sha256_hex(canonical_request.encode("utf-8")),
    ])
    signing_key = _signing_key(credentials["secret_key"], date_stamp, region)
    signature = hmac.new(signing_key, string_to_sign.encode("utf-8"),
                         hashlib.sha256).hexdigest()

    return (f"{scheme}://{host}{canonical_uri}?{canonical_query}"
            f"&X-Amz-Signature={signature}")
