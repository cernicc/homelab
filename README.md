# homelab

Personal homelab infrastructure.

## Ignition

The `ignition/alfred.bu` file is the Butane source for provisioning the `alfred` machine. Whenever it is changed, recompile the ignition file and commit both:

```bash
make ignition
```

To install uCore on a new machine:

```bash
sudo coreos-installer install --ignition-url https://github.com/cernicc/homelab/raw/main/ignition/alfred.ign /dev/sdX
```

## Provisioning a new machine

Ignition is kept as small as possible: it only does the things that genuinely can't live in the OS image — disk layout (LUKS/TPM2), the `cernic` user + SSH key, the hostname, and the container-signing trust bootstrap (`policy.json` + `registries.d` + `cosign.pub`) needed to verify the custom image the *first* time it's pulled. A signed image can't carry its own verification key, so that trust bootstrap can't move into the image itself. Everything else — sshd hardening, service enablement, the firewall unit, the dotfiles bootstrap unit, the bootc auto-update schedule, the timezone symlink — is baked into the image via `recipes/ucore-server.yml` (`files/system/`, `files/systemd/`), so it can be changed after a machine is already provisioned: push a change, wait for the next image build and the daily `bootc-fetch-apply-updates.timer` run, no reprovisioning required.

Installing writes `ignition/alfred.ign` to disk once; everything after that runs unattended in a chain of gated, one-shot systemd services, each disabling itself and rebooting into the next stage. The `unverified`/`signed` condition-file markers under `/etc/ucore-autorebase/` are what let each autorebase unit know whether it still needs to run after a reboot; `homelab-bootstrap.service` (shipped in the image) uses a `bootstrapped` marker the same way.

The automatic chain after step 2, in order:

1. **Ignition (first boot only)** — creates the `cernic` user, writes `/etc/containers/policy.json` + `registries.d` + `cosign.pub` (needed to verify the custom OS image later), and enables the two autorebase units below.
2. **`ucore-unsigned-autorebase.service`** — runs if neither `unverified` nor `signed` exists yet. Does `rpm-ostree rebase --bypass-driver ostree-unverified-registry:.../ucore-server:latest` with no signature check, just to get the custom image's bits onto disk. Touches `unverified`, disables itself, reboots (**reboot #1**).
3. **`ucore-signed-autorebase.service`** — runs once `unverified` is set but `signed` isn't. Does `bootc switch --enforce-container-sigpolicy`, which this time verifies the image's cosign signature against `policy.json`/`registries.d`/`cosign.pub`. Touches `signed`, disables itself, reboots (**reboot #2**).
4. **`homelab-firewall.service`** and **`homelab-bootstrap.service`** — these ship inside the custom image itself (not from ignition), so they simply don't exist until the machine is actually booted into it after reboot #2. The firewall service sets up the `tailscale` zone, opens 80/443, and moves `incusbr` to the `trusted` zone. The bootstrap service enables linger for `cernic` and runs `chezmoi init --apply` to pull down this repo's dotfiles — which is what installs `homelab-sync.timer`.
5. **`homelab-sync.timer`** (every 5 minutes from here on) — pulls `main`, applies dotfiles via `chezmoi apply`, and reconciles which stacks are running. Stacks stay stopped until `.env` exists (step 5 below).

Steps 3, 4, and 6 below (MOK enrollment, Tailscale, DNS) are manual and can happen any time after reboot #2 — they don't block or get blocked by the automatic chain.

### 1. Boot from Fedora CoreOS ISO

Download the ISO and burn it to a USB drive or mount it via IPMI/KVM:

```bash
podman run --security-opt label=disable --pull=always --rm -v .:/data -w /data \
    quay.io/coreos/coreos-installer:release download -s stable -p metal -f iso
```

### 2. Install

Boot from the ISO and run:

```bash
sudo coreos-installer install --ignition-url https://github.com/cernicc/homelab/raw/main/ignition/alfred.ign /dev/sdX
```

Then reboot. The machine will automatically rebase to the custom image and reboot twice, then apply dotfiles and configure firewall rules. Stacks will not start until `.env` is configured (see step 5).

### 3. Enroll secure boot keys

After the reboots complete, enroll the ublue akmods key (required for Nvidia drivers):

```bash
sudo mokutil --import /etc/pki/akmods/certs/akmods-ublue.der
sudo reboot
```

During reboot you will be prompted to enroll the key — select `Enroll MOK` and confirm.

### 4. Connect to Tailscale

```bash
sudo tailscale up
```

Follow the URL printed to authenticate the machine to your tailnet.

### 5. Create `.env` file

SSH into the machine and create the environment file from the example:

```bash
cp ~/homelab/.env.example ~/homelab/.env
```

Then edit `~/homelab/.env` with your actual credentials. Stacks will start automatically within 5 minutes once the file exists.

### 6. Configure DNS

Point your domain's DNS records to the machine's IP. Services will be available at `<service>.yourdomain.com` as configured in Traefik.

## Stacks

Stacks are managed as systemd user services via the `docker-compose@.service` template. Each stack maps to a directory under `stacks/` containing a `docker-compose.yml`.

- `invoice-ninja` — see [stack README](stacks/invoice-ninja/README.md)
- `media`
- `observability`
- `stirling-pdf` — see [stack README](stacks/stirling-pdf/README.md)
- `traefik`
- `whoami`

### Enable a stack on boot

Add a symlink file to `dotfiles/private_dot_config/systemd/user/default.target.wants/`:

```bash
echo '{{ .chezmoi.homeDir }}/.config/systemd/user/docker-compose@.service' \
  > dotfiles/private_dot_config/systemd/user/default.target.wants/symlink_docker-compose@<stack-name>.service
```

Then commit and push — the machine will pick up the change automatically within 5 minutes.

### Disable a stack

Remove the corresponding symlink file:

```bash
rm dotfiles/private_dot_config/systemd/user/default.target.wants/symlink_docker-compose@<stack-name>.service
```

Then commit and push — the machine will pick up the change automatically within 5 minutes.

## Auto-sync

The machine runs `homelab-sync` every 5 minutes via a systemd timer. Each run:

1. Pulls the latest changes from `main`
2. Applies dotfile changes via `chezmoi apply`
3. Stops any stacks whose symlinks were removed
4. Reloads running stacks and starts newly enabled ones

This means most changes (enabling/disabling stacks, updating compose files) only require a `git push` — no manual SSH needed.

### Control files

Two files on the machine control sync behaviour:

- `~/homelab/.env` — must exist for stacks to start. Until created, `homelab-sync` applies dotfiles but skips all stack management.
- `~/homelab/.working` — create this file to pause the sync cron entirely (useful when making manual changes on the server). Delete it to resume auto-sync.
