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

Then reboot. The machine will automatically rebase to the custom image and reboot twice, then apply dotfiles, configure firewall rules, and start all stacks. No further SSH needed.

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

### 5. Configure DNS

Point your domain's DNS records to the machine's IP. Services will be available at `<service>.yourdomain.com` as configured in Traefik.

## Stacks

Stacks are managed as systemd user services via the `docker-compose@.service` template. Each stack maps to a directory under `stacks/` containing a `docker-compose.yml`.

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
