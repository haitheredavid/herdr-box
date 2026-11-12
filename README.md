# herdr-box

Your own [Herdr](https://herdr.dev) dev box over Tailscale: herdr-core, the Herdr TUI, Claude Code, Codex, omp, toolchains and language servers. A systemd Ubuntu container run by Terraform; the same bootstrap also sets up a dedicated machine. Fork it, one box per person.

## Setup

Needs Docker, [mise](https://mise.jdx.dev), and Tailscale on your machine.

```bash
cp config/box.conf.example config/box.conf                         # your user, shell, dotfiles
cp ~/.ssh/id_ed25519.pub config/authorized_keys                    # key(s) allowed to log in
cp terraform/terraform.tfvars.example terraform/terraform.tfvars   # optional

mise trust && mise install
mise run tf:init && mise run tf:plan && mise run tf:apply
mise run ts:up                         # once: add the box to your tailnet
terraform -chdir=terraform output -raw ssh_config >> ~/.ssh/config
ssh herdr-box true                     # once: accept the host key
mise run smoke -- herdr-box
```

Personal files are git-ignored. `mise run test` runs the full end-to-end test in a throwaway container.

## Logins

Once, on the box; they live in `/home` and survive rebuilds.

- Claude: `ssh herdr-box`, `claude`
- Codex: `codex login --device-auth`
- omp: `mise run login -- herdr-box anthropic` (forwards omp's OAuth callback; your browser opens)
- Others: `gh auth login`, `databricks auth login`, `aws configure sso`

## Use

- Herdr app: add machine `herdr-box`
- Herdr TUI: `herdr machine add herdr-box`
- Shell: `ssh herdr-box`, `hc run --bg --name fix --keep claude`, `hc attach fix`
- Update agent tools: `herdr-box-update` on the box

## Dotfiles (optional)

Set `DOTFILES_REPO` in `box.conf`: it's cloned to `~/projects/dotfiles` and `DOTFILES_SETUP` (default `linux/setup.sh`, must be idempotent) runs at every boot. Set `dotfiles_dir` in `terraform.tfvars` to also build the image on that checkout's `linux/Dockerfile`, which should create `BOX_USER` and copy the repo to `/opt/dotfiles`. Example: [haitheredavid/dotfiles](https://github.com/haitheredavid/dotfiles).

## Projects from your Mac (optional)

Set `projects_dir = "~/projects"` in `terraform.tfvars` to bind-mount that directory at `~/projects` on the box: one copy, edited live from either side. It hides whatever the home volume had in `~/projects` (unmounting brings it back), and the dotfiles bootstrap then uses the checkout there. Dependency and build dirs (`node_modules`, `.venv`, `target`) hold per-OS binaries, so build and run each project on one side. Applies to the container only.

## Shared local model (optional)

On the Mac (Tailscale running): `mise run llm:up` runs Llama 3.1 8B Instruct in a Metal `llama-server` LaunchAgent on loopback and serves it to your tailnet (`tailscale serve`, port 8080). The first start downloads about 4.9 GB. It prints the URL to put in `box.conf` as `LLAMA_CPP_URL`; the bootstrap exports it to every shell and Herdr terminal as `LLAMA_CPP_BASE_URL`, where omp discovers it (`omp models`). `llm:status` and `llm:down` check and stop it. Already-running Herdr terminals see it after herdr-core restarts.

## Changing it

- `mise run deploy -- herdr-box`: re-run the bootstrap on the live box, no restart.
- `tf:plan` + `tf:apply`: rebuild and **replace the container** (kills running terminals). `/home`, Tailscale identity and host keys are volumes and survive.
- Dedicated machine: Ubuntu 24.04 with a sudo user named `BOX_USER`, then `mise run deploy -- <host>` and `sudo tailscale up`.

## Security

No published ports; keys-only SSH over your tailnet for `BOX_USER` only. The container is privileged and `BOX_USER` has sudo and Docker: it's a single-person box, not one to share. No secrets in the repo or Terraform state.
