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

## login

first start shows the claude.ai login. run through it once and you stay logged in, in this and every other project. the login lives in the docker volume `dockerclaude-auth`, which all projects share.

the generated settings only allow claude.ai accounts (no api key billing). if `jq` is installed and claude on the host is logged in, the init script also pins the login to the host's organization.

the agent inside the container can read the login. to log out everywhere:

```sh
docker volume rm dockerclaude-auth
```

and revoke the session in your claude.ai settings if you want it fully gone.

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

rules and paths are in `sikt/config/`. login works the same as above, and `make dockerreset` keeps it.
