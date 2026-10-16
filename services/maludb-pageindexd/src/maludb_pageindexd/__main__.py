"""maludb-pageindexd entrypoint."""

from __future__ import annotations

import argparse
import logging
import os
import signal
import sys
import threading

from .db import Pool
from .worker import run_forever


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="maludb-pageindexd",
        description="MaluDB PageIndex / ChatIndex builder (V4-PAGEINDEX-02).")
    parser.add_argument("--poll-interval-ms", type=int,
        default=int(os.environ.get("MALUDB_PAGEINDEXD_POLL_INTERVAL_MS", "5000")))
    parser.add_argument("--batch-size", type=int,
        default=int(os.environ.get("MALUDB_PAGEINDEXD_BATCH_SIZE", "1")))
    parser.add_argument("--log-level",
        default=os.environ.get("MALUDB_PAGEINDEXD_LOG_LEVEL", "INFO"))
    args = parser.parse_args(argv)

    logging.basicConfig(level=args.log_level.upper(),
        format="%(asctime)s %(name)s %(levelname)s %(message)s")

    pool = Pool()
    stop = threading.Event()

    def _shutdown(signum, frame):       # noqa: ARG001
        stop.set()
    signal.signal(signal.SIGINT,  _shutdown)
    signal.signal(signal.SIGTERM, _shutdown)

    run_forever(pool, args.poll_interval_ms / 1000.0, args.batch_size, stop)
    return 0


if __name__ == "__main__":
    sys.exit(main())
