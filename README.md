# a manual and highly configurable containerized claude

install once (outside your repos):

```sh
git clone https://github.com/tollefj/dockerclaude.git ~/.dockerclaude-tools
```

run from the root of any repo:

```sh
~/.dockerclaude-tools/init-dockerclaude.sh
docker compose -f .dockerclaude/compose.yml run --rm claude
```

optional allowlist (edit `.dockerclaude/allowed-domains.txt`):

```sh
~/.dockerclaude-tools/add-firewall.sh
```

hidden paths/mounts/firewall domains etc are in `config/`

___

## sikt profile
aligned with security guidelines at [Sikt](https://sikt.no)

use it instead of the init script:

```sh
~/.dockerclaude-tools/init-dockerclaude-sikt.sh
make dockerclaude   # runs agent-check first, refuses to start on FAIL
make dockercheck    # least-privilege report
make dockerverify   # gitleaks, semgrep, osv-scanner on the host
```

rules and paths are in `sikt/config/`.
