#!/bin/sh
# Logging hook for the Devin Local migration spike.
#
# Registered on every Devin lifecycle event with an empty matcher, it appends
# each stdin payload to a JSONL file and always allows the action. Nothing is
# sent anywhere: the capture stays on the machine until someone looks at it.
#
#     DEVIN_SPIKE_LOG   where to append   (default /tmp/devin-events.jsonl)
#     DEVIN_SPIKE_BLOCK what to answer    (unset: allow; "json": answer with a
#                       block decision on stdout; "exit2": exit 2 with the
#                       reason on stderr)
#
# See docs/devin-spike.md.
set -u

LOG="${DEVIN_SPIKE_LOG:-/tmp/devin-events.jsonl}"

# One event per line, so a truncated write costs one event rather than the file.
payload=$(cat)
printf '%s\n' "$payload" >> "$LOG" 2>/dev/null || :

case "${DEVIN_SPIKE_BLOCK:-}" in
    json)
        printf '%s\n' '{"decision":"block","reason":"TrustGuard spike: blocked on purpose to test the JSON route"}'
        exit 0
        ;;
    exit2)
        echo "TrustGuard spike: blocked on purpose to test the exit-2 route" >&2
        exit 2
        ;;
    *)
        exit 0
        ;;
esac
