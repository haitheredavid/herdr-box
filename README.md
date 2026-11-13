# herdr-box

Your own [Herdr](https://herdr.dev) dev box over Tailscale: herdr-core, the Herdr TUI, Claude Code, Codex, omp, toolchains and language servers. A systemd Ubuntu container run by Terraform; the same bootstrap also sets up a dedicated machine. Fork it, one box per person.

## Setup

Needs Docker, [mise](https://mise.jdx.dev), and Tailscale on your machine. Each box has its own directory under `boxes/`; `herdr-box` is the default name.

```bash
mkdir boxes/herdr-box && cp boxes/example/* boxes/herdr-box/
$EDITOR boxes/herdr-box/box.conf                        # your user, shell, dotfiles
cp ~/.ssh/id_ed25519.pub boxes/herdr-box/authorized_keys   # key(s) allowed to log in
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

`terraform/terraform.tfvars` lists the boxes to run, keyed by name:

```hcl
boxes = {
  "herdr-box" = {
    projects_dir = "~/projects"   # optional, see Projects
  }
}
```

```bash
mise trust && mise install
mise run tf:init && mise run tf:plan && mise run tf:apply
mise run ts:up -- herdr-box              # once: add the box to your tailnet
terraform -chdir=terraform output -raw ssh_config >> ~/.ssh/config
ssh herdr-box true                       # once: accept the host key
mise run smoke -- herdr-box
```

`boxes/*` (except `boxes/example`) and `terraform.tfvars` are git-ignored. `mise run test` runs the full end-to-end test in a throwaway container.

## Logins

Once, on the box; they live in `/home` and survive rebuilds.

- Claude: `ssh herdr-box`, `claude`
- Codex: `codex login --device-auth`
- omp: `mise run login -- herdr-box anthropic` (forwards omp's OAuth callback; your browser opens)
- Others: `gh auth login`, `databricks auth login`, `aws configure sso`

## Use

- Herdr app (phone): add host `herdr-box`, your `BOX_USER`, port 22, no key; Tailscale SSH signs it in (see Security)
- Herdr TUI: `herdr machine add herdr-box`
- Shell: `ssh herdr-box`, `hc run --bg --name fix --keep claude`, `hc attach fix`
- Update agent tools: `herdr-box-update` on the box

## Dotfiles (optional)

Follows the [Dev Containers dotfiles](https://containers.dev/implementors/json_reference/) convention: set `DOTFILES_REPOSITORY` in `box.conf`, and the box keeps its own checkout at `DOTFILES_TARGET_PATH` (default `~/dotfiles`, never under `~/projects`) on `DOTFILES_REF` (empty: the remote's default branch). `DOTFILES_INSTALL_COMMAND` (a path in the repo, must be idempotent; empty: the first of `install.sh`, `install`, `bootstrap.sh`, `bootstrap`, `script/bootstrap`, `setup.sh`, `setup`, `script/setup`) runs at every boot and deploy. Updates move to `DOTFILES_REF` only when nothing local would be lost: with a dirty tree or unpushed commits the checkout stays put and the bootstrap warns. Example: [haitheredavid/dotfiles](https://github.com/haitheredavid/dotfiles) (`DOTFILES_INSTALL_COMMAND="linux/setup.sh"`).

To change them, edit on your Mac, commit and push, then `mise run deploy -- herdr-box`. To skip the remote, push straight to the box's checkout (the clone already accepts pushes to its checked-out branch via `receive.denyCurrentBranch updateInstead`): `git remote add box herdr-box:dotfiles`, then `git push box HEAD:<branch>`. It works while the box's checkout is clean.

## Projects from your Mac (optional)

Set `projects_dir = "~/projects"` on a box in `terraform.tfvars` to bind-mount that directory at `~/projects` on the box: one copy, edited live from either side. It hides whatever the home volume had in `~/projects` (unmounting brings it back). Dependency and build dirs (`node_modules`, `.venv`, `target`) hold per-OS binaries, so build and run each project on one side. Applies to the container only.

## Environment (optional)

`boxes/<name>/env` holds `KEY=value` lines exported to every shell and Herdr terminal on that box. `deploy` applies changes live; already-running terminals see them after herdr-core restarts.

## mise trust

mise runs a project's `mise.toml` only once it's trusted. List directories to trust without a prompt in `MISE_TRUSTED_PATHS` (colon-separated, e.g. `~/projects/work`); anything else needs `mise trust` on the box. Keep it to code you'd run anyway.

## ctx

ctx is installed on every box from its GitHub release (`config/mise.toml`, mise `http:` backend, pinned and bumped by Renovate). Scaffolding stays on demand: `ctx new|scaffold` or omp `/ctx-new`.

## Shared local model (optional)

On the Mac (Tailscale running): `mise run llm:up` runs Llama 3.1 8B Instruct in a Metal `llama-server` LaunchAgent on loopback and serves it to your tailnet (`tailscale serve`, port 8080). The first start downloads about 4.9 GB. It prints the URL to put in `boxes/<name>/box.conf` as `LLAMA_CPP_URL`; the bootstrap exports it to every shell and Herdr terminal as `LLAMA_CPP_BASE_URL`, where omp discovers it (`omp models`). `llm:status` and `llm:down` check and stop it. Already-running Herdr terminals see it after herdr-core restarts.

## Changing it

- `mise run deploy -- <box>`: push the bootstrap and `boxes/<box>/` and re-run the bootstrap on the live box, no restart. This is how live changes (config, env, dotfiles, packages) reach a box.
- `tf:plan` + `tf:apply`: builds images and creates boxes that don't exist yet. It does **not** replace a running container when the image or uploaded config changes.
- To rebuild a box on a new image: `mise run tf:replace -- <box>` writes a plan replacing that box's container, then `mise run tf:apply` applies it (don't run `tf:plan` in between; it overwrites that plan). This kills its running terminals. `/home`, Tailscale identity and host keys are volumes and survive.
- `mise run backup -- <box>`: archive the box's home volume into `backups/` (git-ignored).
- `mise run logs -- [box]`: follow both boot units (`herdr-box-early` and `herdr-box-bootstrap`).
- Dedicated machine: Ubuntu 24.04 with a sudo user named `BOX_USER`, then `mise run deploy -- <host>` and `sudo tailscale up --ssh`.

## Multiple boxes

Add a directory under `boxes/` and an entry in the `boxes` map per box; each gets its own container, volumes and Tailscale name. Boxes on another Docker host go in a second module instance with an aliased docker provider (`terraform/`). Run `mise run ts:up -- <name>` once per new box, and refresh `~/.ssh/config` from the `ssh_config` output.

## Security

No published ports; SSH only over your tailnet. Tailscale SSH (`--ssh`) answers port 22 on the tailnet address and authenticates by tailnet identity, so the phone needs no key. Your tailnet policy (admin console, Access controls) must `accept` SSH as `BOX_USER`; the default `check` asks for a browser re-login that background Herdr connections can't answer:

```json
"ssh": [{"action": "accept", "src": ["autogroup:member"], "dst": ["autogroup:self"], "users": ["<BOX_USER>"]}]
```

sshd itself stays keys-only for `BOX_USER` (`boxes/<name>/authorized_keys`), and is what non-Tailscale routes reach. The container is privileged and `BOX_USER` has sudo and Docker: it's a single-person box, not one to share. No secrets in the repo or Terraform state.
