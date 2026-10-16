"""maludb-realtimed entrypoint."""

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
    p = argparse.ArgumentParser(prog="maludb-realtimed",
        description="MaluDB realtime gateway (V3-REALTIME-01).")
    p.add_argument("--host", default=os.environ.get("MALUDB_REALTIMED_HOST_BIND", "127.0.0.1"))
    p.add_argument("--port", type=int, default=int(os.environ.get("MALUDB_REALTIMED_PORT_BIND", "5332")))
    p.add_argument("--log-level", default=os.environ.get("MALUDB_REALTIMED_LOG_LEVEL", "INFO"))
    args = p.parse_args(argv)

    logging.basicConfig(level=args.log_level.upper(),
        format="%(asctime)s %(name)s %(levelname)s %(message)s")

    pool = Pool()
    server = serve(args.host, args.port, pool)

    def _shutdown(signum, frame):                                      # noqa: ARG001
        threading.Thread(target=server.shutdown, daemon=True).start()
    signal.signal(signal.SIGINT,  _shutdown)
    signal.signal(signal.SIGTERM, _shutdown)

    try:
        server.serve_forever(poll_interval=0.5)
    finally:
        pool.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
