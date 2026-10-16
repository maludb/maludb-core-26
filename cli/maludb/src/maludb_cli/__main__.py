"""maludb CLI entrypoint."""

from __future__ import annotations

import argparse
import os
import sys
import traceback

from . import __version__
from .errors import StagePendingError
from .commands import (
    auth, backup, chatindex, cron, db_cmd, env, install, log_drain, metrics,
    model, pageindex, prompt, queue as queue_cmd, realtime, replay, retrieve,
    secret, source, status, tool,
)
from .output import emit_error


EXIT_OK              = 0
EXIT_USAGE           = 64    # EX_USAGE
EXIT_SOFTWARE        = 70    # EX_SOFTWARE (used for "stage not yet shipped")
EXIT_UNAVAILABLE     = 69    # EX_UNAVAILABLE (DB unreachable etc.)


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="maludb",
        description="MaluDB first-party CLI (V3-CLI-01).")
    parser.add_argument("--version", action="version", version=f"maludb {__version__}")
    parser.add_argument("--format", choices=("text", "json"), default="text",
        help="Output format (default: text).")
    parser.add_argument("--db",       default=os.environ.get("MALUDB_DB"),
        help="PostgreSQL database (env MALUDB_DB).")
    parser.add_argument("--host",     default=os.environ.get("MALUDB_HOST"),
        help="PostgreSQL host (env MALUDB_HOST).")
    parser.add_argument("--port",     default=os.environ.get("MALUDB_PORT"),
        help="PostgreSQL port (env MALUDB_PORT).")
    parser.add_argument("--user",     default=os.environ.get("MALUDB_USER"),
        help="PostgreSQL user (env MALUDB_USER).")
    parser.add_argument("--password", default=os.environ.get("MALUDB_PASSWORD"),
        help="PostgreSQL password (env MALUDB_PASSWORD).")
    parser.add_argument("--schema", default=os.environ.get("MALUDB_SCHEMA"),
        help="Tenant schema to prefix in search_path (env MALUDB_SCHEMA).")

    sub = parser.add_subparsers(dest="cmd", required=True, metavar="<command>")

    status.register(sub)
    install.register(sub)
    db_cmd.register(sub)
    auth.register(sub)
    secret.register(sub)
    model.register(sub)
    prompt.register(sub)
    tool.register(sub)
    source.register(sub)
    retrieve.register(sub)
    replay.register(sub)
    queue_cmd.register(sub)
    cron.register(sub)
    realtime.register(sub)
    metrics.register(sub)
    env.register(sub)
    log_drain.register(sub)
    backup.register(sub)
    pageindex.register(sub)
    chatindex.register(sub)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv)
    if not hasattr(args, "handler"):
        parser.print_help(sys.stderr)
        return EXIT_USAGE

    try:
        rc = args.handler(args)
        return rc if isinstance(rc, int) else EXIT_OK
    except KeyboardInterrupt:
        return 130
    except StagePendingError as e:
        emit_error(args.format, str(e), code=e.code)
        return EXIT_SOFTWARE
    except Exception as e:                                              # noqa: BLE001
        emit_error(args.format, str(e), code=type(e).__name__)
        if args.format != "json" and os.environ.get("MALUDB_TRACEBACK"):
            traceback.print_exc()
        return EXIT_UNAVAILABLE


if __name__ == "__main__":
    sys.exit(main())
