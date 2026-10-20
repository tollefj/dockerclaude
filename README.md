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

hidden paths, host-exec mounts and firewall base domains are configured in `config/*.txt`, one entry per line.
