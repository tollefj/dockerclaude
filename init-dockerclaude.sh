#!/usr/bin/env bash

set -euo pipefail

OUT_DIR=".dockerclaude"
MAX_DEPTH=${MAX_DEPTH:-6}
DEFAULT_NODE_MAJOR=${DEFAULT_NODE_MAJOR:-24}

PRUNE_NAMES=(.git node_modules .venv venv dist build out .next .nuxt .turbo .cache coverage
  __pycache__ .pytest_cache .mypy_cache .ruff_cache .terraform "$OUT_DIR")
SECRET_DIR_NAMES=(env .env secrets secret certs .aws .ssh .gnupg .kube '*backup*' '*dump*')
SECRET_FILE_NAMES=(.env '.env.*' '*.env' '*.pem' '*.key' '*.p12' '*.pfx' '*.jks' '*.keystore'
  'id_rsa*' 'id_ed25519*' 'id_ecdsa*' 'secret.*' 'secrets.*' '*-secret.*' '*_secret.*'
  '*secret*.yaml' '*secret*.yml' '*secret*.json' 'credentials' 'credentials.*' 'service-account*.json'
  .npmrc .netrc .pypirc kubeconfig '*.kubeconfig' '*.tfstate' '*.tfstate.*' '*.tfvars'
  '*.sqlite' '*.sqlite3' '*.dump' '*.bak')
SAFE_SUFFIXES=(.example .sample .template .dist)
NOISE_PATTERNS=(.DS_Store Thumbs.db '*.log' '*.tsbuildinfo' '*.swp' '*.swo' '*.pyc' .idea .vscode)
PROJECT_FILE_NAMES=(package.json 'tsconfig*.json' package-lock.json npm-shrinkwrap.json pnpm-lock.yaml
  pnpm-workspace.yaml yarn.lock bun.lock bun.lockb pyproject.toml uv.lock)
HOST_EXEC_PATHS=(.claude .mcp.json .envrc .vscode .devcontainer .husky .githooks .pre-commit-config.yaml)
TOKEN_MOUNT=/run/claude-token
BASE_DOMAINS=(api.anthropic.com claude.ai platform.claude.com registry.npmjs.org)

CAND_PATHS=()
CAND_ON=()
CAND_TAGS=()

bold=$'\033[1m'
dim=$'\033[2m'
reset=$'\033[0m'

prune_expr=()
for name in "${PRUNE_NAMES[@]}"; do prune_expr+=(-o -name "$name"); done
prune_expr=("${prune_expr[@]:1}")

ask() {
  local reply
  read -r -p "$1 [$2]: " reply || true
  printf '%s' "${reply:-$2}"
}

confirm() {
  local hint="y/N" reply
  [ "$2" = y ] && hint="Y/n"
  read -r -p "$1 [$hint] " reply || true
  case "${reply:-$2}" in [yY]*) return 0 ;; *) return 1 ;; esac
}

trim() {
  local s="${1#"${1%%[![:space:]]*}"}"
  printf '%s' "${s%"${s##*[![:space:]]}"}"
}

find_pruned() {
  find . -maxdepth "$MAX_DEPTH" -type d \( "${prune_expr[@]}" \) -prune -o "$@" -print 2>/dev/null |
    sed 's|^\./||' | sort -u
}

find_by_name() {
  local type=$1 expr=() pattern
  shift
  for pattern in "$@"; do expr+=(-o -name "$pattern"); done
  find_pruned -type "$type" \( "${expr[@]:1}" \)
}

matches_any() {
  local value=$1 pattern
  shift
  for pattern in "$@"; do
    # shellcheck disable=SC2053
    [[ "$value" == $pattern ]] && return 0
  done
  return 1
}

has_safe_suffix() {
  local suffix
  for suffix in "${SAFE_SUFFIXES[@]}"; do
    [[ "$1" == *"$suffix" ]] && return 0
  done
  return 1
}

has_skipped_component() {
  local part parts
  IFS=/ read -ra parts <<<"$1"
  for part in "${parts[@]}"; do
    matches_any "$part" "${NOISE_PATTERNS[@]}" "${PRUNE_NAMES[@]}" && return 0
  done
  return 1
}

git_ignored_paths() {
  local entry path
  while IFS= read -r -d '' entry; do
    [[ "$entry" == '!! '* ]] || continue
    path=${entry#'!! '}
    path=${path%/}
    has_skipped_component "$path" || printf '%s\n' "$path"
  done < <(git status -z --porcelain --ignored=matching --untracked-files=normal 2>/dev/null)
}

gitignore_matches() {
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git_ignored_paths | sort -u
    return
  fi
  [ -f .gitignore ] || return 0
  local line pattern
  while IFS= read -r line || [ -n "$line" ]; do
    pattern=$(trim "${line%$'\r'}")
    case "$pattern" in "" | '#'* | '!'*) continue ;; esac
    pattern=${pattern#/}
    pattern=${pattern%/}
    [ -n "$pattern" ] || continue
    matches_any "$pattern" "${NOISE_PATTERNS[@]}" "${PRUNE_NAMES[@]}" && continue
    if [[ "$pattern" == */* ]]; then
      find_pruned -path "./$pattern"
    else
      find_pruned -name "$pattern"
    fi
  done <.gitignore | sort -u
}

add_candidate() {
  local i=0 n=${#CAND_PATHS[@]}
  [ "$3" != added ] && matches_any "${1##*/}" "${PROJECT_FILE_NAMES[@]}" && return 0
  while [ "$i" -lt "$n" ]; do
    [ "${CAND_PATHS[$i]}" = "$1" ] && return 0
    i=$((i + 1))
  done
  CAND_PATHS+=("$1")
  CAND_ON+=("$2")
  CAND_TAGS+=("$3")
}

collect_candidates() {
  local path
  while IFS= read -r path; do
    [ -n "$path" ] && add_candidate "$path" 1 "secret?"
  done < <(find_by_name d "${SECRET_DIR_NAMES[@]}")

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if has_safe_suffix "$path"; then
      add_candidate "$path" 0 "example"
    else
      add_candidate "$path" 1 "secret?"
    fi
  done < <(find_by_name f "${SECRET_FILE_NAMES[@]}")

  while IFS= read -r path; do
    [ -n "$path" ] && add_candidate "$path" 1 "gitignore"
  done < <(gitignore_matches)
}

draw_checklist() {
  local cursor=$1 top=$2 height=$3 i end mark suffix pointer
  end=$((top + height))
  [ "$end" -gt "${#CAND_PATHS[@]}" ] && end=${#CAND_PATHS[@]}
  for ((i = top; i < end; i++)); do
    mark=" "
    suffix=""
    pointer=" "
    [ "${CAND_ON[$i]}" = 1 ] && mark="x"
    [ -d "${CAND_PATHS[$i]}" ] && suffix="/"
    [ "$i" = "$cursor" ] && pointer=">"
    printf '\033[2K %s [%s] %s%s  %s%s%s\n' "$pointer" "$mark" "${CAND_PATHS[$i]}" "$suffix" \
      "$dim" "${CAND_TAGS[$i]}" "$reset"
  done
  printf '\033[2K%s up/down or j/k move | space toggle | a all | n none | + add path | Enter done (%d/%d)%s\n\033[J' \
    "$dim" "$((cursor + 1))" "${#CAND_PATHS[@]}" "$reset"
}

set_all() {
  local i=0 n=${#CAND_PATHS[@]}
  while [ "$i" -lt "$n" ]; do
    CAND_ON[i]=$1
    i=$((i + 1))
  done
}

prompt_added_path() {
  local path
  printf '\033[?25h\033[2K  Path to hide: '
  read -r path || true
  printf '\033[?25l'
  path=$(trim "$path")
  path=${path#./}
  path=${path%/}
  [ -n "$path" ] && [ -e "$path" ] && add_candidate "$path" 1 "added"
  return 0
}

run_checklist() {
  echo
  echo "${bold}Paths to hide from the container${reset}"
  if [ ! -t 0 ]; then
    return
  fi

  local cursor=0 top=0 height rows key seq drawn=0
  rows=$(tput lines 2>/dev/null || echo 24)
  trap 'printf "\033[?25h"' EXIT
  printf '\033[?25l'
  while true; do
    height=$((rows - 4))
    [ "$height" -gt "${#CAND_PATHS[@]}" ] && height=${#CAND_PATHS[@]}
    [ "$height" -lt 1 ] && height=1
    [ "$cursor" -lt "$top" ] && top=$cursor
    [ "$cursor" -ge "$((top + height))" ] && top=$((cursor - height + 1))
    [ "$drawn" -gt 0 ] && printf '\033[%dA' "$drawn"
    draw_checklist "$cursor" "$top" "$height"
    drawn=$((height + 1))

    IFS= read -rsn1 key || break
    case "$key" in
      "") break ;;
      " ")
        if [ "${#CAND_PATHS[@]}" -gt 0 ]; then
          if [ "${CAND_ON[$cursor]}" = 1 ]; then CAND_ON[cursor]=0; else CAND_ON[cursor]=1; fi
        fi
        ;;
      a) set_all 1 ;;
      n) set_all 0 ;;
      j) [ "$cursor" -lt "$((${#CAND_PATHS[@]} - 1))" ] && cursor=$((cursor + 1)) ;;
      k) [ "$cursor" -gt 0 ] && cursor=$((cursor - 1)) ;;
      +)
        prompt_added_path
        drawn=$((drawn + 1))
        ;;
      $'\033')
        IFS= read -rsn2 seq || break
        case "$seq" in
          '[A') [ "$cursor" -gt 0 ] && cursor=$((cursor - 1)) ;;
          '[B') [ "$cursor" -lt "$((${#CAND_PATHS[@]} - 1))" ] && cursor=$((cursor + 1)) ;;
        esac
        ;;
    esac
  done
  printf '\033[?25h'
  trap - EXIT
}

covered_by_selected_dir() {
  local i=0 n=${#CAND_PATHS[@]}
  while [ "$i" -lt "$n" ]; do
    if [ "${CAND_ON[$i]}" = 1 ] && [ -d "${CAND_PATHS[$i]}" ] && [[ "$1" == "${CAND_PATHS[$i]}"/* ]]; then
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

volume_name() {
  printf '%s_%s' "$1" "$(printf '%s' "$2" | tr -c 'a-zA-Z0-9' '_' | sed 's/^_*//; s/_*$//')"
}

yaml_quote() {
  printf "'%s'" "${1//\'/\'\'}"
}

node_major_from_compose() {
  local file
  while IFS= read -r file; do
    grep -ho 'node:[0-9][0-9]*' "$file" | head -n 1 | cut -d: -f2
  done < <(find_pruned -type f \( -name 'compose*.y*ml' -o -name 'docker-compose*.y*ml' -o -name 'Dockerfile*' \)) |
    head -n 1
}

detect_node_major() {
  local file version
  version=$(node_major_from_compose || true)
  [ -n "$version" ] && printf '%s' "$version" && return
  for file in .nvmrc .node-version; do
    [ -f "$file" ] || continue
    version=$(sed -n 's/^v\{0,1\}\([0-9][0-9]*\).*/\1/p' "$file" | head -n 1)
    [ -n "$version" ] && printf '%s' "$version" && return
  done
  printf '%s' "$DEFAULT_NODE_MAJOR"
}

detect_package_manager() {
  local declared=""
  [ -f package.json ] &&
    declared=$(sed -n 's/.*"packageManager"[[:space:]]*:[[:space:]]*"\([^"+]*\).*/\1/p' package.json | head -n 1)
  if [ -n "$declared" ]; then
    printf '%s' "$declared"
  elif [ -f pnpm-lock.yaml ]; then
    printf 'pnpm@latest'
  elif [ -f yarn.lock ]; then
    printf 'yarn@stable'
  elif [ -f bun.lock ] || [ -f bun.lockb ]; then
    printf 'bun@latest'
  fi
}

package_manager_install() {
  case "$1" in
    pnpm@* | bun@* | npm@*) printf 'RUN npm install -g %s\n' "$1" ;;
    yarn@*) printf 'RUN npm install -g corepack && corepack enable\n' ;;
  esac
}

project_name() {
  local name
  name=$(basename "$PWD" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' '-' | sed 's/^[-_]*//; s/-*$//')
  printf '%s' "${name:-project}"
}

latest_claude_version() {
  command -v npm >/dev/null 2>&1 && npm view @anthropic-ai/claude-code version 2>/dev/null || printf 'latest'
}

host_claude_version() {
  if command -v claude >/dev/null 2>&1; then
    claude --version 2>/dev/null | awk '{print $1; exit}'
  else
    latest_claude_version
  fi
}

host_uv_version() {
  command -v uv >/dev/null 2>&1 && uv --version 2>/dev/null | awk '{print $2}' || printf 'latest'
}

write_dockerfile() {
  local node_major=$1 apk_packages=$2 package_manager=$3 uv_version=$4 claude_version=$5 firewall=$6
  shift 6
  {
    printf 'FROM node:%s-alpine\n\n' "$node_major"
    printf 'RUN apk add --no-cache %s\n' "$apk_packages"
    [ -n "$uv_version" ] && printf 'COPY --from=ghcr.io/astral-sh/uv:%s /uv /uvx /usr/local/bin/\n' "$uv_version"
    [ -n "$package_manager" ] && package_manager_install "$package_manager"
    printf 'RUN npm install -g @anthropic-ai/claude-code@%s\n' "$claude_version"
    if [ "$#" -gt 0 ]; then
      printf '\nRUN mkdir -p'
      printf ' %q' "$@"
      printf ' && chown -R node:node /workspace\n'
    fi
    if [ "$firewall" = 1 ]; then
      printf '\nCOPY init-firewall.sh entrypoint.sh /usr/local/bin/\n'
      printf 'WORKDIR /workspace\n\n'
      printf 'ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]\n'
      printf 'CMD ["claude"]\n'
    else
      printf '\nCOPY entrypoint.sh /usr/local/bin/\n'
      printf 'USER node\nWORKDIR /workspace\n\n'
      printf 'ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]\n'
    fi
  } >"$OUT_DIR/Dockerfile"
}

write_entrypoint() {
  {
    printf '#!/bin/sh\nset -eu\n'
    printf '[ -r %s ] && export CLAUDE_CODE_OAUTH_TOKEN="$(cat %s)"\n' "$TOKEN_MOUNT" "$TOKEN_MOUNT"
    if [ "$1" = 1 ]; then
      printf '/usr/local/bin/init-firewall.sh\nexec su-exec node "$@"\n'
    else
      printf 'exec claude "$@"\n'
    fi
  } >"$OUT_DIR/entrypoint.sh"
  chmod 755 "$OUT_DIR/entrypoint.sh"
}

write_firewall() {
  cat >"$OUT_DIR/init-firewall.sh" <<'EOF'
#!/bin/bash
# Default-deny egress, modeled on the claude-code reference dev container.
set -euo pipefail

DOMAINS_FILE=/workspace/.dockerclaude/allowed-domains.txt
IPV4_RE='^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$'

add_ip() {
  [[ "$1" =~ $IPV4_RE ]] && ipset add allowed "$1" -exist
  return 0
}

ipset create allowed hash:net -exist
ipset flush allowed

while IFS= read -r line || [ -n "$line" ]; do
  entry=${line%%#*}
  entry=${entry//[[:space:]]/}
  [ -n "$entry" ] || continue
  if [ "$entry" = "@github" ]; then
    while read -r cidr; do add_ip "$cidr"; done < <(curl -fsS --connect-timeout 10 https://api.github.com/meta |
      jq -r '(.web + .api + .git)[]')
    continue
  fi
  ips=$(dig +short A "$entry" | grep -E "$IPV4_RE" || true)
  [ -n "$ips" ] || echo "Warning: could not resolve $entry"
  for ip in $ips; do add_ip "$ip"; done
done <"$DOMAINS_FILE"

iptables -F
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m set --match-set allowed dst -j ACCEPT
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

ip6tables -F 2>/dev/null || true
ip6tables -A INPUT -i lo -j ACCEPT 2>/dev/null || true
ip6tables -A OUTPUT -o lo -j ACCEPT 2>/dev/null || true
for chain in INPUT FORWARD OUTPUT; do ip6tables -P "$chain" DROP 2>/dev/null || true; done

if curl -fsS --connect-timeout 5 -o /dev/null https://example.com 2>/dev/null; then
  echo "Firewall check failed: example.com is reachable"
  exit 1
fi
if ! curl -sS --connect-timeout 10 -o /dev/null https://api.anthropic.com; then
  echo "Firewall check failed: api.anthropic.com is unreachable"
  exit 1
fi
echo "Firewall active. Allowlist: .dockerclaude/allowed-domains.txt"
EOF
  chmod 755 "$OUT_DIR/init-firewall.sh"
}

write_allowed_domains() {
  local file="$OUT_DIR/allowed-domains.txt"
  if [ -f "$file" ]; then
    echo "Keeping existing $file"
    return
  fi
  {
    printf '# One domain per line. @github adds GitHub web/api/git ranges.\n'
    printf '# Read at container start; restart the container after editing.\n'
    printf '%s\n' "$@"
  } >"$file"
}

write_settings() {
  local permissions=$'  "permissions": {\n    "defaultMode": "auto"\n  },\n'
  {
    # Bash sandbox stays off: bubblewrap needs user namespaces, which Docker's default seccomp profile blocks.
    printf '{\n%s  "sandbox": {\n    "enabled": false\n  },\n' "$permissions"
    cat <<'EOF'
  "env": {
    "DISABLE_TELEMETRY": "1",
    "DISABLE_ERROR_REPORTING": "1",
    "DISABLE_AUTOUPDATER": "1",
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"
  }
}
EOF
  } >"$OUT_DIR/settings.json"
}

is_hidden() {
  local mask
  for mask in ${masks[@]+"${masks[@]}"}; do
    [ "$1" = "$mask" ] || [[ "$1" == "$mask"/* ]] && return 0
  done
  return 1
}

host_exec_paths() {
  local isolate_git=$1 path
  for path in "${HOST_EXEC_PATHS[@]}"; do
    [ -e "$path" ] && ! is_hidden "$path" && printf '%s\n' "$path"
  done
  if [ "$isolate_git" = 0 ] && [ -d .git ]; then
    for path in .git/hooks .git/config; do
      [ -e "$path" ] && printf '%s\n' "$path"
    done
  fi
  return 0
}

MAKE_TARGETS=(dockerclaude dockerterm)

print_make_target() {
  local target=$1 compose_project=$2
  case $target in
    dockerclaude)
      printf 'dockerclaude: ## Run Claude Code sandboxed in Docker\n'
      printf '\tdocker compose -f %s/compose.yml run --build --rm claude\n\n' "$OUT_DIR" ;;
    dockerterm)
      printf 'dockerterm: ## Shell into the running dockerclaude container\n'
      printf '\tdocker exec -it -u node $$(docker ps -q --filter label=com.docker.compose.project=%s --filter label=com.docker.compose.service=claude | head -n 1) /bin/bash\n\n' "$compose_project" ;;
  esac
}

print_make_snippet() {
  local compose_project=$1
  shift
  printf '# --- Sandboxed Claude Code (generated by init-dockerclaude.sh) ---\n\n'
  local target
  for target in "$@"; do
    print_make_target "$target" "$compose_project"
  done
  printf '.PHONY: %s\n' "$*"
}

missing_make_targets() {
  local target
  for target in "${MAKE_TARGETS[@]}"; do
    grep -Eq "^${target}[[:space:]]*:" Makefile || echo "$target"
  done
}

append_make_snippet() {
  [ -s Makefile ] && [ -n "$(tail -c 1 Makefile)" ] && printf '\n' >>Makefile
  [ -s Makefile ] && printf '\n' >>Makefile
  print_make_snippet "$@" >>Makefile
}

setup_makefile() {
  local compose_project=$1 missing=() target
  if [ ! -f Makefile ]; then
    if confirm "Create a Makefile with the dockerclaude targets?" n; then
      append_make_snippet "$compose_project" "${MAKE_TARGETS[@]}"
    fi
    return
  fi

  while IFS= read -r target; do missing+=("$target"); done < <(missing_make_targets)
  if [ ${#missing[@]} -eq 0 ]; then
    echo "Makefile already has all dockerclaude targets, left unchanged."
    return
  fi

  local snippet="$OUT_DIR/Makefile.snippet"
  print_make_snippet "$compose_project" "${missing[@]}" >"$snippet"
  echo "Makefile exists. Missing targets: ${missing[*]}"
  echo "Snippet (also saved to $snippet):"
  echo
  sed 's/^/    /' "$snippet"
  echo
  if confirm "Append this snippet to the end of Makefile?" y; then
    append_make_snippet "$compose_project" "${missing[@]}"
    echo "Appended to Makefile."
  else
    echo "Not appended. Paste $snippet into your Makefile when ready."
  fi
}

main() {
  if git rev-parse --show-toplevel >/dev/null 2>&1 && [ "$(git rev-parse --show-toplevel)" != "$(pwd -P)" ]; then
    echo "Note: you are not in the git root ($(git rev-parse --show-toplevel))."
    confirm "Continue in $PWD anyway?" n || exit 1
  fi
  command -v docker >/dev/null 2>&1 || echo "Note: docker was not found on PATH."

  if [ -d "$OUT_DIR" ] && [ -n "$(ls -A "$OUT_DIR" 2>/dev/null)" ]; then
    confirm "$OUT_DIR/ already exists. Overwrite?" n || exit 1
  fi

  echo "Scanning $PWD ..."
  collect_candidates
  run_checklist

  local masks=() mask_modes=() i=0 n=${#CAND_PATHS[@]} path
  while [ "$i" -lt "$n" ]; do
    path=${CAND_PATHS[$i]}
    i=$((i + 1))
    [ "${CAND_ON[$((i - 1))]}" = 1 ] || continue
    covered_by_selected_dir "$path" && continue
    if [[ "$path" == *:* ]]; then
      echo "Skipping $path: Docker volume paths cannot contain ':'. Move or rename it."
      continue
    fi
    masks+=("$path")
    if [ "${CAND_TAGS[$((i - 1))]}" = gitignore ]; then mask_modes+=(rw); else mask_modes+=(ro); fi
  done

  local node_major apk_extra package_manager uv_version="" claude_version isolate_git=0 is_python=0
  echo
  node_major=$(detect_node_major)
  claude_version=$(host_claude_version)
  package_manager=$(detect_package_manager)

  apk_extra=""
  [ -f Makefile ] && apk_extra="make"
  if [ -f pyproject.toml ] || [ -f uv.lock ] || [ -f requirements.txt ]; then
    is_python=1
    apk_extra=$(trim "$apk_extra python3")
    uv_version=$(host_uv_version)
  fi

  echo
  echo "${bold}Container${reset}"
  local nm_dirs=()
  while IFS= read -r path; do
    [ -n "$path" ] && nm_dirs+=("$path")
  done < <(find . -maxdepth "$MAX_DEPTH" -name .git -prune -o -type d -name node_modules -print -prune 2>/dev/null | sed 's|^\./||' | sort)
  if [ "${#nm_dirs[@]}" -gt 0 ] &&
    ! confirm "Give the container its own empty node_modules (${#nm_dirs[@]} found; host node_modules is shared otherwise, and macOS binaries won't run on Linux)?" n; then
    nm_dirs=()
  fi
  if [ -d .git ] && confirm "Mount all of .git read-only (hooks and config are protected either way; commit from the host)?" n; then
    isolate_git=1
  fi

  local firewall=0 domains=("${BASE_DOMAINS[@]}" @github) extra_domains
  echo "  Permission mode is auto (a classifier reviews each action)."
  if confirm "Block network access, with a specific allowlist?" n; then
    firewall=1
    [ "$package_manager" != "${package_manager#yarn@}" ] && domains+=(repo.yarnpkg.com)
    [ "$is_python" = 1 ] && domains+=(pypi.org files.pythonhosted.org)
    extra_domains=$(ask "Extra allowed domains besides Anthropic, npm and GitHub (space separated, '-' for none)" "-")
    # shellcheck disable=SC2206
    [ "$extra_domains" != "-" ] && domains+=($extra_domains)
  fi

  local protect=() protect_project_claude=0
  while IFS= read -r path; do
    [ -n "$path" ] && protect+=("$path")
  done < <(host_exec_paths "$isolate_git")
  [ -e .claude ] || is_hidden .claude || protect_project_claude=1
  if [ "${#protect[@]}" -gt 0 ] || [ "$protect_project_claude" = 1 ]; then
    echo "  Files the host runs later (hooks, MCP, editor tasks):${protect[*]+ ${protect[*]}}"
    [ "$protect_project_claude" = 1 ] && echo "  .claude/ does not exist yet; an empty read-only one would be mounted."
    if ! confirm "Mount these read-only?" y; then
      protect=()
      protect_project_claude=0
    fi
  fi

  local token_path token_source=""
  echo
  echo "${bold}Authentication${reset}"
  echo "  The container logs in with a token created on the host."
  echo "  Open another terminal, run 'claude setup-token', and save the printed token to a file (e.g. ~/.claude-token)."
  read -r -p "  Press Enter when the token file exists (or to continue without one) " _ || true
  token_path=$(ask "Path to Claude OAuth token file from 'claude setup-token' ('-' to skip)" "~/.claude-token")
  if [ "$token_path" != "-" ]; then
    if [ -r "${token_path/#\~/$HOME}" ]; then
      token_source="${token_path/#\~/$HOME}"
    else
      echo "  $token_path is not readable, skipping. Use /login inside Claude instead."
    fi
  fi

  local compose_project
  compose_project="$(project_name)-claude"
  mkdir -p "$OUT_DIR"

  local owned_targets=() named_volumes=(claude-home) volume_lines=() name
  volume_lines+=("$(yaml_quote "..:/workspace")")
  volume_lines+=("$(yaml_quote ".:/workspace/$OUT_DIR:ro")")
  [ "$isolate_git" = 1 ] && volume_lines+=("$(yaml_quote "../.git:/workspace/.git:ro")")

  for path in ${protect[@]+"${protect[@]}"}; do
    if [[ "$path" == *:* ]]; then
      echo "Skipping $path: Docker volume paths cannot contain ':'."
      continue
    fi
    volume_lines+=("$(yaml_quote "../$path:/workspace/$path:ro")")
  done
  if [ "$protect_project_claude" = 1 ]; then
    named_volumes+=(project-claude)
    volume_lines+=("$(yaml_quote "project-claude:/workspace/.claude:ro")")
  fi

  i=0
  while [ "$i" -lt "${#masks[@]}" ]; do
    path=${masks[$i]}
    if [ -d "$path" ]; then
      name=$(volume_name "mask$i" "$path")
      named_volumes+=("$name")
      if [ "${mask_modes[$i]}" = rw ]; then
        owned_targets+=("/workspace/$path")
        volume_lines+=("$(yaml_quote "$name:/workspace/$path")")
      else
        volume_lines+=("$(yaml_quote "$name:/workspace/$path:ro")")
      fi
    else
      volume_lines+=("$(yaml_quote "/dev/null:/workspace/$path:ro")")
    fi
    i=$((i + 1))
  done

  i=0
  while [ "$i" -lt "${#nm_dirs[@]}" ]; do
    path=${nm_dirs[$i]}
    name=$(volume_name "nm$i" "$path")
    named_volumes+=("$name")
    owned_targets+=("/workspace/$path")
    volume_lines+=("$(yaml_quote "$name:/workspace/$path")")
    i=$((i + 1))
  done

  volume_lines+=("$(yaml_quote "claude-home:/home/node")")
  volume_lines+=("$(yaml_quote "./settings.json:/etc/claude-code/managed-settings.json:ro")")
  [ -n "$token_source" ] && volume_lines+=("$(yaml_quote "$token_source:$TOKEN_MOUNT:ro")")

  {
    printf '# Generated by init-dockerclaude.sh. Run from the project root:\n'
    printf '#   docker compose -f %s/compose.yml run --rm claude\n' "$OUT_DIR"
    printf 'name: %s\n\nservices:\n  claude:\n    build: .\n' "$compose_project"
    printf '    working_dir: /workspace\n    stdin_open: true\n    tty: true\n'
    printf '    security_opt:\n      - no-new-privileges:true\n    cap_drop:\n      - ALL\n'
    if [ "$firewall" = 1 ]; then
      printf '    cap_add:\n      - NET_ADMIN\n      - NET_RAW\n      - SETUID\n      - SETGID\n'
    fi
    printf '    volumes:\n'
    printf '      - %s\n' "${volume_lines[@]}"
    printf '\nvolumes:\n'
    printf '  %s:\n' "${named_volumes[@]}"
  } >"$OUT_DIR/compose.yml"

  local apk_packages="git bash ripgrep curl openssh-client${apk_extra:+ $apk_extra}"
  [ "$firewall" = 1 ] && apk_packages+=" iptables ip6tables ipset bind-tools jq su-exec"
  write_dockerfile "$node_major" "$(trim "$apk_packages")" "$package_manager" "$uv_version" \
    "$claude_version" "$firewall" ${owned_targets[@]+"${owned_targets[@]}"}
  if [ "$firewall" = 1 ]; then
    write_firewall
    write_allowed_domains "${domains[@]}"
  else
    rm -f "$OUT_DIR/init-firewall.sh"
  fi
  write_entrypoint "$firewall"
  write_settings

  echo
  setup_makefile "$compose_project"

  echo
  echo "${bold}Done.${reset} Created $OUT_DIR/Dockerfile, $OUT_DIR/compose.yml and $OUT_DIR/settings.json"
  echo "Hidden from the container: ${#masks[@]} path(s). Read-only for host-run config: ${#protect[@]} path(s)."
  if [ "$firewall" = 1 ]; then
    echo "Network: allowlist in $OUT_DIR/allowed-domains.txt, auto mode."
  else
    echo "Network: unrestricted, auto mode."
  fi
  echo "Still writable: Makefile, package.json scripts and other project files. Review diffs before running them on the host."
  echo
  echo "Start:    docker compose -f $OUT_DIR/compose.yml run --rm claude   (or: make dockerclaude)"
  if [ -n "$token_source" ]; then
    echo "Login:    token from $token_source is mounted read-only"
  else
    echo "Login:    run /login inside Claude the first time"
  fi
  echo "Upgrade:  docker compose -f $OUT_DIR/compose.yml build --no-cache"
  echo "Re-run this script to change what is hidden."
  if [ "${#nm_dirs[@]}" -gt 0 ]; then
    echo "node_modules starts empty in the container. Install dependencies inside it first."
  fi
}

main "$@"
