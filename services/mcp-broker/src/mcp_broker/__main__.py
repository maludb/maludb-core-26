"""Entry point. `python -m mcp_broker` or `maludb-mcp-broker`."""

from __future__ import annotations

import argparse
import os
import sys

from .server import Server
from .tools import Registry


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="maludb-mcp-broker",
        description="MaluDB external MCP broker (stdio JSON-RPC).",
    )
    parser.add_argument(
        "--config",
        default=os.environ.get("MCP_BROKER_CONFIG",
                               "/etc/maludb/mcp-broker.json"),
        help="path to the JSON tool config",
    )
    args = parser.parse_args(argv)

    try:
        registry = Registry.from_config_path(args.config)
    except FileNotFoundError:
        sys.stderr.write(f"config not found: {args.config}\n")
        return 2
    except Exception as e:
        sys.stderr.write(f"config error: {e}\n")
        return 2

    Server(registry).serve()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
