#!/usr/bin/env python3
"""Run one trusted argv without a shell and terminate its process group on timeout."""

import argparse
import os
import signal
import subprocess
import sys


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--timeout-ms", required=True, type=int)
    parser.add_argument("argv", nargs=argparse.REMAINDER)
    arguments = parser.parse_args()
    argv = arguments.argv
    if argv and argv[0] == "--":
        argv = argv[1:]
    if not argv or arguments.timeout_ms < 1 or arguments.timeout_ms > 300000:
        parser.error("expected --timeout-ms within 1..300000 and a trusted argv")
    process = subprocess.Popen(
        argv,
        stdin=subprocess.DEVNULL,
        start_new_session=True,
    )
    try:
        return process.wait(timeout=arguments.timeout_ms / 1000)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()
        sys.stderr.write(
            f"bounded exec: trusted command exceeded {arguments.timeout_ms} ms\n"
        )
        return 124


if __name__ == "__main__":
    raise SystemExit(main())
