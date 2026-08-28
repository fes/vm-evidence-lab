#!/usr/bin/env sh
set -eu

[ "$#" -eq 1 ] || exit 2

jq -e '
    (keys | sort) == ([
      "initial_timeout_seconds", "modes", "platform", "schema_version",
      "stage_timeout_seconds", "stages"
    ] | sort) and
    .schema_version == 1 and
    .platform == "windows" and
    (.modes | type == "array" and length >= 1 and length <= 8 and
      length == (unique | length) and
      all(.[]; type == "string" and test("^[a-z][a-z0-9-]{0,63}$"))) and
    (.initial_timeout_seconds | type == "number" and floor == . and . >= 1 and . <= 1800) and
    (.stage_timeout_seconds | type == "number" and floor == . and . >= 1 and . <= 120) and
    (.stages | type == "array" and length >= 1 and length <= 8) and
    ([.stages[].wait_for] | length == (unique | length)) and
    all(.stages[];
      (keys | sort) == (["events", "wait_for"] | sort) and
      (.wait_for | type == "string" and test("^[a-z][a-z0-9-]{0,63}$")) and
      (.events | type == "array" and length >= 1 and length <= 64) and
      all(.events[];
        (keys | sort) == (["code", "type"] | sort) and
        (
          (.code as $code | .type == "key" and
            ([20, 23, 28, 30, 31, 32, 33, 36, 39, 41, 45, 54, 57, 98] |
              index($code)) != null) or
          (.type == "pointer-button" and .code == 178)
        )
      )
    )
' "$1" >/dev/null
