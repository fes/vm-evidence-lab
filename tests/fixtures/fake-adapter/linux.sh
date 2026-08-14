#!/usr/bin/env sh
set -eu

job_path=$1
source_map_path=$2
artifact_directory=$3

[ "$(jq -er '.adapter_id' "$job_path")" = fake ]
[ "$(jq -er 'length' "$source_map_path")" -eq 1 ]
source_path=$(jq -er '.[0].path' "$source_map_path")
[ -f "$source_path/evidence.txt" ]

if [ "$(jq -er '.mode' "$job_path")" = fail ]; then
    exit 7
fi

printf 'fake-adapter=pass\n' >"$artifact_directory/fake-result.txt"
