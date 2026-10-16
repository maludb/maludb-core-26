"""maludb-restd entrypoint."""

from __future__ import annotations

import argparse
import logging
import os
import signal
import sys
import threading

from .db import Pool
from .server import serve


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="maludb-restd",
        description="MaluDB REST gateway (V3-API-01).")
    parser.add_argument("--host", default=os.environ.get("MALUDB_RESTD_HOST_BIND", "127.0.0.1"))
    parser.add_argument("--port", type=int, default=int(os.environ.get("MALUDB_RESTD_PORT_BIND", "5331")))
    parser.add_argument("--log-level", default=os.environ.get("MALUDB_RESTD_LOG_LEVEL", "INFO"))
    args = parser.parse_args(argv)

    logging.basicConfig(level=args.log_level.upper(),
        format="%(asctime)s %(name)s %(levelname)s %(message)s")

    pool = Pool()
    server = serve(args.host, args.port, pool)

    stop = threading.Event()
    def _shutdown(signum, frame):       # noqa: ARG001
        stop.set()
        threading.Thread(target=server.shutdown, daemon=True).start()
    signal.signal(signal.SIGINT, _shutdown)
    signal.signal(signal.SIGTERM, _shutdown)

    try:
        server.serve_forever(poll_interval=0.5)
    finally:
        pool.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
