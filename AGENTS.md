# AGENTS.md

Forkable single-user Herdr box: each person runs their own. A bash bootstrap configures an Ubuntu 24.04 host: one account, herdr-core, the Herdr TUI, Claude Code, Codex, omp, mise toolchains, Docker, Tailscale, and sshd. The host is a privileged systemd container, managed by Terraform (kreuzwerker/docker, local state) and reached only over Tailscale; the same bootstrap sets up a dedicated machine. Personal values live in git-ignored files: one directory per box, `boxes/<name>/` (`box.conf`, `authorized_keys`, `env`), templated by the committed `boxes/example/`, and `terraform/terraform.tfvars` (the `boxes` map). See `README.md` for layout and usage.

## Commands

```
mise run check                  # shellcheck + terraform fmt/validate (static)
mise run test                   # test/run.sh: real image with your config, boot bootstrap, idempotency, SSH smoke, replace + re-check (Docker, network)
mise run tf:plan / tf:apply     # build images, create missing boxes; never replaces a running container
mise run tf:replace -- <box>    # plan replacing one box's container; then tf:apply (no tf:plan in between)
mise run deploy -- <box>        # push bootstrap + boxes/<box>/, re-run bootstrap without restart
mise run smoke -- <box>         # check the box the way Herdr connects
mise run login -- <box> [p]     # omp login on the box, forwarding the provider's OAuth callback port
mise run logs -- [box]          # follow both boot units (herdr-box-early, herdr-box-bootstrap)
mise run ts:up -- <box>         # tailscale login in the container
mise run backup -- <box>        # archive the box's home volume into backups/ (git-ignored)
```

`check` is static. `test` proves the image and bootstrap but not Tailscale. Only `smoke` against `herdr-box` proves the running box.

## Standards

- Host scripts: bash with `set -euo pipefail`. Mac-side `scripts/`: POSIX sh. Everything passes shellcheck. Messages are prefixed `herdr-box:`, and errors go to stderr.
- The bootstrap is idempotent. Every step that mutates goes through `changed()`, which counts real changes; a second run prints `changes: 0`, and the test asserts it. Don't mutate outside `changed()`, and don't report a change that didn't happen.
- Non-interactive SSH logins print nothing on stdout, because Herdr's connection is a byte protocol.
- Agent tools install per user into `~/.local/bin`, never as root. Toolchains come from mise (`/etc/mise/conf.d`), installed into the user's home.
- Anything that must outlive the container goes on a volume: `/home`, `/var/lib/tailscale`, and `/var/lib/herdr-box` (SSH host keys).

## Durable decisions

- Container first, with the same bootstrap as a dedicated machine. The container runs it at boot (`herdr-box-bootstrap.service`), and `deploy.sh` runs it on a live box.
- Nothing personal is committed: user, keys, dotfiles repo, and dotfiles checkout come from git-ignored local files; code must not hard-code them, and the test reads them like the box does.
- The image is `FROM` a digest-pinned Ubuntu 24.04, multi-stage and layered by change frequency (rarely-changing system layer first). The system layer is baked in (`bootstrap.sh --system`); the boot bootstrap only verifies it. User config (box.conf, keys, env, dotfiles) is never in the image.
- Dotfiles follow the Dev Containers dotfiles convention: a box-owned checkout at `DOTFILES_TARGET_PATH`, never under `~/projects`, on `DOTFILES_REF` (empty: remote default branch), whose `DOTFILES_INSTALL_COMMAND` (empty: the devcontainer install-script search) owns its own setup. It moves to `DOTFILES_REF` only when nothing local would be lost; a dirty tree or unpushed commits stay put with a warning. Herdr integrations install only when missing, so they never rewrite agent configs the dotfiles link in.
- Replacing a container is explicit: Terraform ignores changes to the image and uploads (`ignore_changes`), and only `tf:replace` rebuilds a box. `deploy` carries live changes.
- Boot is two units: an early, offline host phase before `ssh` and `tailscaled` start, then a late networked phase.
- SSH host keys live only on the state volume (`/var/lib/herdr-box`), never in the image.
- One module instance per box via the `boxes` map; boxes on another Docker host use a second instance with an aliased provider.
- Agent tools float to latest; toolchains are pinned exactly and bumped by Renovate.
- The account follows its home: if its uid differs from the home's owner, the bootstrap adopts the home's uid.
- Single user, so Docker is rootful, with the user in the `docker` group.
- Projects can be shared live from the Docker host: terraform `projects_dir` bind-mounts it at `~/projects`, no syncing. It's container-only and the bootstrap doesn't know about it. The test mounts a throwaway directory there, never the real one.
- Access is Tailscale only: no published ports. Tailscale SSH (`--ssh`, tailnet policy `accept`) signs in the phone app by tailnet identity, since it can't export a key; sshd behind it stays keys-only. The tailnet login is interactive, so no auth key ends up in Terraform state.
- Flutter goes in `config/mise.amd64.toml` and is skipped on arm64.

## Safety

Do not read `.env`, Terraform state or plan files, SSH private keys, or agent login files and credentials on the box (`~/.claude*`, `~/.codex`, `~/.databrickscfg`, `/var/lib/tailscale`). Never `tf:apply`, `tf:replace`, or `deploy` without explicit instruction; review the plan first. `tf:replace` followed by `tf:apply` kills the box's running terminals.
