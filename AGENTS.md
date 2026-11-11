# AGENTS.md

Forkable single-user Herdr box: each person runs their own. A bash bootstrap configures an Ubuntu 24.04 host: one account, herdr-core, the Herdr TUI, Claude Code, Codex, omp, mise toolchains, Docker, Tailscale, and sshd. The host is a privileged systemd container, managed by Terraform (kreuzwerker/docker, local state) and reached only over Tailscale; the same bootstrap sets up a dedicated machine. Personal values live in git-ignored files (`config/box.conf`, `config/authorized_keys`, `terraform/terraform.tfvars`) with committed `*.example` templates. See `README.md` for layout and usage.

## Commands

```
mise run check                  # shellcheck + terraform fmt/validate (static)
mise run test                   # test/run.sh: real image with your config, boot bootstrap, idempotency, SSH smoke, replace + re-check (Docker, network)
mise run tf:plan / tf:apply     # build image + run container (replaces it when bootstrap/, config/, image/ change)
mise run deploy -- <host>       # push bootstrap/config, re-run bootstrap without restart
mise run smoke -- <host>        # check the box the way Herdr connects
mise run login -- <host> [p]    # omp login on the box, forwarding the provider's OAuth callback port
mise run logs / ts:up           # follow boot bootstrap / tailscale login in the container
```

`check` is static. `test` proves the image and bootstrap but not Tailscale. Only `smoke` against `herdr-box` proves the running box.

## Standards

- Host scripts: bash with `set -euo pipefail`. Mac-side `scripts/`: POSIX sh. Everything passes shellcheck. Messages are prefixed `herdr-box:`, and errors go to stderr.
- The bootstrap is idempotent. A second run creates and installs nothing, and the test asserts this.
- Non-interactive SSH logins print nothing on stdout, because Herdr's connection is a byte protocol.
- Agent tools install per user into `~/.local/bin`, never as root. Toolchains come from mise (`/etc/mise/conf.d`), installed into the user's home.
- Anything that must outlive the container goes on a volume: `/home`, `/var/lib/tailscale`, and `/var/lib/herdr-box` (SSH host keys).

## Durable decisions

- Container first, with the same bootstrap as a dedicated machine. The container runs it at boot (`herdr-box-bootstrap.service`), and `deploy.sh` runs it on a live box.
- Nothing personal is committed: user, keys, dotfiles repo, and dotfiles checkout come from git-ignored local files; code must not hard-code them, and the test reads them like the box does.
- The image is `FROM` `BASE`: plain Ubuntu, or the image from the user's dotfiles checkout (terraform `dotfiles_dir`, its `linux/Dockerfile`). The system layer is baked in (`bootstrap.sh --system`); the boot bootstrap only verifies it. The dotfiles repo owns its own setup (`DOTFILES_SETUP`); `bootstrap/dotfiles.sh` only ensures the repo (seeded from `/opt/dotfiles` or cloned) and calls it. Herdr integrations install only when missing, so they never rewrite agent configs the dotfiles link in. If the account's uid differs from its home's owner (base image vs an older volume), the bootstrap follows the home.
- Single user, so Docker is rootful, with the user in the `docker` group.
- Access is Tailscale only: no published ports, keys-only sshd. The tailnet login is interactive, so no auth key ends up in Terraform state.
- Flutter goes in `config/mise.amd64.toml` and is skipped on arm64.

## Safety

Do not read `.env`, Terraform state or plan files, SSH private keys, or agent login files and credentials on the box (`~/.claude*`, `~/.codex`, `~/.databrickscfg`, `/var/lib/tailscale`). Never `tf:apply` or `deploy` without explicit instruction; review the plan first. Applying replaces the running container whenever the image inputs changed.
