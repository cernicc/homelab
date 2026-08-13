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
