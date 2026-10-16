#!/usr/bin/env bash
# Test fixture for the R1.1-1 external_exec dispatcher.
#
# Reads a single JSON envelope on stdin (the R1.1-1 contract), echoes
# back the arguments verbatim under result.structuredContent, plus a
# simple success text block. Always exits 0 with ok:true.
#
# This file is invoked by mc2dbd/tests/run_all.sh after a registration
# of an `external_exec` tool whose command_path points here.

set -eu

INPUT="$(cat)"
TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""')
CALL_ID=$(printf '%s' "$INPUT"  | jq -r '.call_id // ""')
ARGS=$(printf '%s' "$INPUT"     | jq -c '.arguments // {}')

# Echo what we got — useful as a sanity check of the contract.
jq -nc \
   --arg tool "$TOOL_NAME" \
   --arg cid  "$CALL_ID" \
   --argjson args "$ARGS" \
   '{ok:true,
     result:{
       content:[{type:"text", text:("echo from " + $tool)}],
       structuredContent:{
         tool_name: $tool,
         call_id:   $cid,
         arguments: $args,
         marker:    "external_exec_ok"
       }
     }}'
