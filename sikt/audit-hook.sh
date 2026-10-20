#!/bin/sh
# Claude Code hook: forwards each event to the audit sidecar. Blocks tool calls when the log is unreachable.
set -u

SOCK=/opt/audit/audit.sock
MAX_FIELD=4000

event=$(cat)
name=$(printf '%s' "$event" | jq -r '.hook_event_name // "unknown"' 2>/dev/null || echo unknown)

extra='{}'
if [ "$name" = SessionEnd ]; then
  extra=$(git -c safe.directory=/workspace -C /workspace status --porcelain 2>/dev/null |
    jq -Rsc '{changed_files: (split("\n") | map(select(length > 0)))}')
fi

record=$(printf '%s' "$event" | jq -c \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg agent "${AGENT_ID:-unknown}" \
  --arg owner "${AGENT_OWNER:-unknown}" \
  --arg model "${ANTHROPIC_MODEL:-}" \
  --argjson max "$MAX_FIELD" \
  --argjson extra "$extra" '
  del(.tool_response)
  | walk(if type == "string" and length > $max then .[0:$max] + "...[truncated]" else . end)
  | {ts: $ts, agent_id: $agent, owner: $owner, model_env: $model} + . + $extra')

if ! printf '%s\n' "$record" | socat -u - "UNIX-CONNECT:$SOCK" 2>/dev/null; then
  echo "Audit log unavailable ($SOCK). Tool call blocked." >&2
  [ "$name" = PreToolUse ] && exit 2
fi
exit 0
