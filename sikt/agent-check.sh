#!/bin/bash
# Deterministic least-privilege check (Sikt rule 1, controls R1.1-R1.12, plus rules 6-8).
# Reports PASS / FAIL / WARN / NOT_TESTABLE from observed state. Secret values are never printed.
set -uo pipefail

CONF=/workspace/.dockerclaude
SETTINGS=/etc/claude-code/managed-settings.json
AUDIT_SOCK=/opt/audit/audit.sock
MODEL_CREDENTIALS=(CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY)
SECRET_NAME_RE='TOKEN|SECRET|PASSW|API_?KEY|ACCESS_KEY|PRIVATE_KEY|CREDENTIAL|SESSION_KEY|AUTH'
CREDENTIAL_FILES=(.ssh .aws .azure .config/gcloud .kube .docker/config.json .netrc .git-credentials
  .config/gh .vault-token .pypirc)
PROD_ENV_RE='^(KUBECONFIG|AWS_|AZURE_|GOOGLE_APPLICATION_CREDENTIALS|CLOUDSDK_|VAULT_|ARM_)'
SECRET_FILE_ARGS=(-name .env -o -name '.env.*' -o -name '*.pem' -o -name '*.key' -o -name '*.p12'
  -o -name '*.pfx' -o -name 'id_rsa*' -o -name 'id_ed25519*' -o -name '*.tfstate' -o -name '*.tfvars'
  -o -name 'credentials*.json' -o -name 'service-account*.json' -o -name kubeconfig)
EXPECTED_MOUNT_RE='^/(workspace|home/node|opt/audit|etc/claude-code|root/claude-token|sbin/docker-init|etc/hosts|etc/hostname|etc/resolv\.conf|tmp|run|proc|sys|dev)(/|$)|^/$'

declare -i passed=0 warned=0 failed=0 untestable=0
brief=0
audit=0
results=()
for arg; do
  case $arg in
    --brief) brief=1 ;;
    --audit) audit=1 ;;
  esac
done

record() {
  local status=$1 id=$2 title=$3 line
  shift 3
  case $status in
    PASS) passed+=1 ;;
    WARN) warned+=1 ;;
    FAIL) failed+=1 ;;
    NOT_TESTABLE) untestable+=1 ;;
  esac
  results+=("$status $id $title")
  [ "$brief" = 1 ] && { [ "$status" = PASS ] || [ "$status" = NOT_TESTABLE ]; } && return
  printf '[%s] %s %s\n' "$status" "$id" "$title"
  for line; do printf '      %s\n' "$line"; done
  echo
}

setting() {
  jq -r "$1" "$SETTINGS" 2>/dev/null
}

listed_entries() {
  [ -f "$1" ] && sed 's/#.*//; s/[[:space:]]*$//' "$1" | grep -v '^[[:space:]]*$'
}

unreachable() {
  local rc
  curl -sS --connect-timeout 3 --max-time 5 -o /dev/null "$1" 2>/dev/null
  rc=$?
  [ "$rc" = 6 ] || [ "$rc" = 7 ] || [ "$rc" = 28 ]
}

check_identity() {
  if [ -n "${AGENT_ID:-}" ] && [ "$(hostname)" = "$AGENT_ID" ]; then
    record PASS R1.1 "Agent execution context identified" "container: $AGENT_ID" "owner: ${AGENT_OWNER:-unknown}"
  else
    record FAIL R1.1 "Agent execution context not identifiable" "AGENT_ID: ${AGENT_ID:-MISSING}" "hostname: $(hostname)"
  fi
}

check_inherited_credentials() {
  local evidence=() name file helper
  while IFS= read -r name; do
    [[ " ${MODEL_CREDENTIALS[*]} " == *" $name "* ]] && continue
    evidence+=("$name: PRESENT")
  done < <(compgen -e | grep -E "$SECRET_NAME_RE")
  [ -n "${SSH_AUTH_SOCK:-}" ] && evidence+=("SSH_AUTH_SOCK: PRESENT (ssh-agent forwarded)")
  for file in "${CREDENTIAL_FILES[@]}"; do
    [ -e "$HOME/$file" ] && evidence+=("~/$file: PRESENT")
  done
  [ -f "$HOME/.npmrc" ] && grep -q '_authToken' "$HOME/.npmrc" && evidence+=("~/.npmrc: auth token PRESENT")
  helper=$(git config --global --get credential.helper 2>/dev/null || true)
  [ -n "$helper" ] && evidence+=("git credential.helper: $helper")
  if [ "${#evidence[@]}" -eq 0 ]; then
    record PASS R1.2 "No inherited user credentials" "environment and home scanned"
  else
    record FAIL R1.2 "Inherited user credentials found" "${evidence[@]}"
  fi
}

check_filesystem() {
  local evidence=() bad=() path
  if touch /usr/.agent-check-probe 2>/dev/null; then
    rm -f /usr/.agent-check-probe
    bad+=("root filesystem is writable")
  else
    evidence+=("root filesystem: read-only")
  fi
  while IFS= read -r path; do evidence+=("writable: $path"); done < <(
    awk '$4 ~ /^rw/ {print $2}' /proc/mounts | grep -vE '^/(proc|sys|dev)(/|$)' | sort -u)
  while IFS= read -r path; do
    [ -e "/workspace/$path" ] && [ -w "/workspace/$path" ] && bad+=("protected path writable: $path")
  done < <(listed_entries "$CONF/protected-paths.txt")
  if [ "${#bad[@]}" -eq 0 ]; then
    record PASS R1.3 "Filesystem scoped" "${evidence[@]}"
  else
    record FAIL R1.3 "Filesystem not scoped" "${bad[@]}" "${evidence[@]}"
  fi
}

check_repository() {
  local repos unexpected=() target
  repos=$(find /workspace -maxdepth 4 -name node_modules -prune -o -name .git -print 2>/dev/null | wc -l | tr -d ' ')
  while IFS= read -r target; do
    [[ "$target" =~ $EXPECTED_MOUNT_RE ]] || unexpected+=("unexpected mount: $target")
  done < <(awk '{print $2}' /proc/mounts | sort -u)
  if [ "${#unexpected[@]}" -gt 0 ]; then
    record WARN R1.4 "Mounts outside the project" "${unexpected[@]}"
  elif [ -w /workspace/.git ]; then
    record WARN R1.4 "Repository writable" "repositories under /workspace: $repos" ".git: read/write (agent can commit and rewrite history)"
  else
    record PASS R1.4 "Repository access scoped" "repositories under /workspace: $repos" ".git: read-only"
  fi
}

check_secrets() {
  local bad=() warn=() evidence=() mode path name
  while read -r mode path; do
    [ "$mode" = ro ] || continue
    path="/workspace/$path"
    if [ -f "$path" ] && [ -s "$path" ]; then
      bad+=("not masked: ${path#/workspace/}")
    elif [ -d "$path" ] && [ -n "$(ls -A "$path" 2>/dev/null)" ]; then
      bad+=("not masked: ${path#/workspace/}/")
    fi
  done < <(listed_entries "$CONF/hidden-paths.txt")
  while IFS= read -r path; do
    path=${path#/workspace/}
    grep -qxF "ro $path" "$CONF/hidden-paths.txt" 2>/dev/null && continue
    case "$path" in *.example | *.sample | *.template | *.dist) continue ;; esac
    warn+=("secret-like file readable: $path")
  done < <(find /workspace -maxdepth 6 \( -name node_modules -o -name .git -o -name .venv \) -prune -o \
    -type f -size +0 \( "${SECRET_FILE_ARGS[@]}" \) -print 2>/dev/null)
  for name in "${MODEL_CREDENTIALS[@]}"; do
    [ -n "${!name:-}" ] && evidence+=("$name: PRESENT (model access only)")
  done
  [ "${CLAUDE_CODE_SUBPROCESS_ENV_SCRUB:-0}" = 1 ] && evidence+=("subprocess credential scrub: on")
  if [ "${#bad[@]}" -gt 0 ]; then
    record FAIL R1.5 "Secrets not scoped to the task" "${bad[@]}" ${warn[@]+"${warn[@]}"}
  elif [ "${#warn[@]}" -gt 0 ]; then
    record WARN R1.5 "Secret-like files visible to the agent" "${warn[@]}" ${evidence[@]+"${evidence[@]}"}
  else
    record PASS R1.5 "Secrets scoped" "masked paths empty" ${evidence[@]+"${evidence[@]}"}
  fi
}

check_production_credentials() {
  local evidence=() name
  while IFS= read -r name; do evidence+=("$name: PRESENT"); done < <(compgen -e | grep -E "$PROD_ENV_RE")
  [ -e "$HOME/.kube/config" ] && evidence+=("~/.kube/config: PRESENT")
  if [ "${#evidence[@]}" -eq 0 ]; then
    record PASS R1.6 "No production credentials" "no kube, cloud or vault configuration"
  else
    record FAIL R1.6 "Production credential sources available" "${evidence[@]}"
  fi
}

check_production_access() {
  local reachable=() blocked=() endpoint
  while IFS= read -r endpoint; do
    if unreachable "https://$endpoint"; then blocked+=("blocked: $endpoint"); else reachable+=("reachable: $endpoint"); fi
  done < <(listed_entries "$CONF/prod-endpoints.txt")
  if [ "${#reachable[@]}" -gt 0 ]; then
    record FAIL R1.7 "Production endpoints reachable" "${reachable[@]}"
  elif [ "${#blocked[@]}" -gt 0 ]; then
    record PASS R1.7 "No route to production" "${blocked[@]}"
  else
    record NOT_TESTABLE R1.7 "No production endpoints listed" "add hosts to .dockerclaude/prod-endpoints.txt"
  fi
}

check_execution() {
  local seccomp
  seccomp=$(awk '/^Seccomp:/ {print $2}' /proc/self/status)
  if [ -f /.dockerenv ]; then
    record PASS R1.8 "Code runs in a controlled execution context" "runtime: docker container" "seccomp mode: ${seccomp:-unknown}"
  else
    record FAIL R1.8 "No container runtime detected"
  fi
}

check_network() {
  local allowed
  allowed=$(listed_entries "$CONF/allowed-domains.txt" | wc -l | tr -d ' ')
  if unreachable https://example.com; then
    record PASS R1.9 "Outbound network default-deny" "example.com: blocked" "allowlist entries: $allowed"
    if [ -n "$(dig +short +time=2 +tries=1 example.com 2>/dev/null)" ]; then
      record WARN R1.9 "DNS not filtered" "names outside the allowlist resolve (possible exfiltration channel)"
    fi
  else
    record WARN R1.9 "Network unrestricted" "outbound connections are not filtered"
  fi
  if unreachable http://169.254.169.254/; then
    record PASS R1.9 "Cloud metadata blocked" "169.254.169.254: blocked"
  else
    record FAIL R1.9 "Cloud metadata reachable" "169.254.169.254: reachable"
  fi
}

check_escalation() {
  local bad=() evidence=() nnp cap
  nnp=$(awk '/^NoNewPrivs:/ {print $2}' /proc/self/status)
  cap=$(awk '/^CapEff:/ {print $2}' /proc/self/status)
  [ "$(id -u)" = 0 ] && bad+=("running as root") || evidence+=("uid: $(id -u) ($(id -un))")
  [ "$nnp" = 1 ] && evidence+=("no_new_privs: 1") || bad+=("no_new_privs: ${nnp:-unknown}")
  [ "$cap" = 0000000000000000 ] && evidence+=("effective capabilities: none") || bad+=("effective capabilities: $cap")
  command -v sudo >/dev/null 2>&1 && bad+=("sudo available")
  command -v doas >/dev/null 2>&1 && bad+=("doas available")
  { [ -S /var/run/docker.sock ] || [ -S /run/docker.sock ]; } && bad+=("docker socket mounted")
  [ -w "$SETTINGS" ] && bad+=("managed settings writable")
  [ -w "$CONF" ] && bad+=(".dockerclaude writable (agent could change its own sandbox)")
  [ "$(setting .permissions.disableBypassPermissionsMode)" = disable ] &&
    evidence+=("bypassPermissions: disabled") || bad+=("bypassPermissions mode allowed")
  if [ "${#bad[@]}" -eq 0 ]; then
    record PASS R1.10 "Agent cannot extend its own privileges" "${evidence[@]}"
  else
    record FAIL R1.10 "Privilege escalation paths" "${bad[@]}"
  fi
}

check_tools() {
  local managed allowed project_servers
  managed=$(setting .allowManagedMcpServersOnly)
  allowed=$(jq -r '(.allowedMcpServers // []) | map(.serverName // .serverUrl // (.serverCommand | tostring)) | join(", ")' "$SETTINGS" 2>/dev/null)
  project_servers=$(jq -r '(.mcpServers // {}) | keys | join(", ")' /workspace/.mcp.json 2>/dev/null || true)
  if [ "$managed" != true ]; then
    record FAIL R1.11 "MCP servers not restricted by managed settings"
  elif [ -n "$allowed" ]; then
    record WARN R1.11 "MCP servers allowed" "allowed: $allowed" "verify each is scoped to project and operation"
  else
    record PASS R1.11 "Tools limited to built-ins" "MCP servers: none allowed" ${project_servers:+"blocked from .mcp.json: $project_servers"}
  fi
}

check_lifetime() {
  record NOT_TESTABLE R1.12 "Credential lifetime not observable" "container is removed on exit" \
    "model token expiry is not visible inside the container; rotate tokens from 'claude setup-token'"
}

check_checkpoints() {
  local asks
  asks=$(jq -r '(.permissions.ask // []) | length' "$SETTINGS" 2>/dev/null)
  if [ "$(setting .allowManagedPermissionRulesOnly)" = true ] && [ "${asks:-0}" -gt 0 ]; then
    record PASS R6.1 "Critical actions require confirmation" "managed ask rules: $asks" "permission mode: $(setting .permissions.defaultMode)"
  else
    record FAIL R6.1 "Critical-action checkpoints missing or overridable"
  fi
}

check_audit() {
  if [ -S "$AUDIT_SOCK" ] && printf '' | socat -u - "UNIX-CONNECT:$AUDIT_SOCK" 2>/dev/null; then
    record PASS R7.1 "Actions logged outside the agent's reach" "sink: $AUDIT_SOCK (append-only sidecar)"
  else
    record FAIL R7.1 "Audit log sink unreachable" "sink: $AUDIT_SOCK"
  fi
}

check_memory() {
  if [ "$(setting .autoMemoryEnabled)" = false ]; then
    record PASS R8.1 "No persistent agent memory" "autoMemoryEnabled: false"
  else
    record WARN R8.1 "Persistent agent memory enabled" "review or delete with: make dockerreset"
  fi
}

send_audit() {
  printf '%s\n' "${results[@]}" | jq -Rsc --argjson f "$failed" --argjson w "$warned" --argjson p "$passed" \
    '{hook_event_name: "AgentCheck", passed: $p, warnings: $w, failed: $f, results: (split("\n") | map(select(length > 0)))}' |
    /usr/local/bin/audit-hook.sh
}

echo "SIKT AGENT SECURITY CHECK"
echo
check_identity
check_inherited_credentials
check_filesystem
check_repository
check_secrets
check_production_credentials
check_production_access
check_execution
check_network
check_escalation
check_tools
check_lifetime
check_checkpoints
check_audit
check_memory

printf 'Controls passed: %d\nWarnings:        %d\nFailed:          %d\nNot testable:    %d\n\n' \
  "$passed" "$warned" "$failed" "$untestable"
[ "$audit" = 1 ] && send_audit
if [ "$failed" -gt 0 ]; then
  echo "Compliance: FAIL"
  exit 1
fi
echo "Compliance: PASS (absence of evidence is not evidence of absence; see NOT_TESTABLE)"
