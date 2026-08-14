#!/usr/bin/env sh
set -eu

script_dir=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=relay/common.sh
. "$script_dir/common.sh"

relay_process_jobs
