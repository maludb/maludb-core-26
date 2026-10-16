#!/usr/bin/env bash
# Test fixture for the R1.1-1.1 argv_template substitution.
#
# The mc2dbd external_exec dispatcher builds argv from argv_template
# with {{key}} placeholders substituted from the tools/call arguments
# object. This fixture echoes its received argv (everything past $0)
# back in result.structuredContent.argv so the test can verify
# substitution happened.

set -eu

# Drain the stdin envelope (we don't use it, but it's the contract).
cat >/dev/null

# Build a JSON array of our argv ($1, $2, ...). jq -nR captures one
# string per line, but argv may contain newlines (unlikely here);
# use printf+jq -s for robustness on a single-line invocation.
ARGV_JSON='[]'
for a in "$@"; do
    ARGV_JSON=$(jq -nc --argjson cur "$ARGV_JSON" --arg next "$a" \
                '$cur + [$next]')
done

jq -nc --argjson argv "$ARGV_JSON" \
    '{ok:true,
      result:{
        content:[{type:"text", text:"argv echoed"}],
        structuredContent:{
          argv: $argv,
          marker: "argv_substitute_ok"
        }
      }}'
