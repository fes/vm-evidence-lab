#!/usr/bin/env python3
import argparse
import pathlib
import sys


REPOSITORY_ROOT = pathlib.Path(__file__).resolve().parents[1]
if str(REPOSITORY_ROOT) not in sys.path:
    sys.path.insert(0, str(REPOSITORY_ROOT))

from interaction.host import (  # noqa: E402
    InteractionError,
    dump_json,
    dry_run_controller,
    load_json,
    validate_command,
    validate_result,
    validate_session,
)
from interaction.host.selfcheck import run as selfcheck  # noqa: E402


def _read(path: str) -> object:
    data = pathlib.Path(path).read_bytes()
    return load_json(data, path)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Validate and dry-run controller-side interaction commands.")
    parser.add_argument("--self-check", action="store_true")
    parser.add_argument("--session", help="interaction session JSON")
    parser.add_argument("--command", help="one interaction command JSON")
    parser.add_argument(
        "--dry-run", action="store_true",
        help="execute no subprocess and emit a schema-valid result")
    parser.add_argument(
        "--validate-result", metavar="PATH",
        help="validate an already-produced guest interaction result")
    parser.add_argument(
        "--validate-request", action="store_true",
        help="validate a session and command without enforcing the first sequence")
    arguments = parser.parse_args()
    if arguments.self_check:
        selfcheck()
        return 0
    if not arguments.session or not arguments.command:
        parser.error("--session and --command are required")
    try:
        session = _read(arguments.session)
        command = _read(arguments.command)
        if arguments.validate_result:
            result = validate_result(
                _read(arguments.validate_result),
                validate_session(session),
                validate_command(command),
            )
        elif arguments.validate_request:
            validate_command(command, validate_session(session))
            return 0
        elif arguments.dry_run:
            controller = dry_run_controller(session)
            result = controller.execute(command)
        else:
            parser.error(
                "live transport is library-only; use --validate-request, "
                "--dry-run, or --validate-result")
        sys.stdout.write(dump_json(result) + "\n")
    except (OSError, InteractionError) as error:
        sys.stderr.write(f"interactive: {error}\n")
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
