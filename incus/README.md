# Incus

Incus configuration for `alfred`. Its only use so far is dev VMs: sandboxed development machines for running AI agents: one Incus VM per project, each with Docker (for the project's own `.devcontainer`), a clone of that one repo, and its own Tailscale node. The VM is the security boundary -- the agent can be root inside it, and has no route to `alfred`, the LAN, the other stacks or other dev VMs.

- `preseed.yaml` -- one-time init: Incus storage pool and the isolated `incusdev` bridge
- `acls/dev-egress.yaml` -- egress ACL on that bridge: internet only
- `profiles/dev.yaml` -- VM size and cloud-init (Docker, Tailscale, `dev` user)
- `toolchains/<name>.sh` -- optional per-language setup, run as root inside a VM (`rust` so far)
- `homelab-dev` (in `dotfiles/dot_local/bin/`) -- create/snapshot/destroy VMs

## One-time setup

### 1. Tailscale (admin console, not tracked in git)

1. Access controls -> add `tag:dev` to `tagOwners`.
2. Make sure nothing in the policy has `tag:dev` as a source, and that there is no allow-all rule (`"src": ["*"]`) -- otherwise a dev VM can reach every `tag:homelab` service over the tailnet, bypassing everything below. Allow yourself to reach `tag:dev`:

   ```json
   {"src": ["autogroup:admin"], "dst": ["tag:dev"], "ip": ["*"]}
   ```

3. Settings -> Keys -> generate an auth key: reusable, **not** ephemeral, tagged `tag:dev`. Set it as `TS_DEV_AUTHKEY` in `~/homelab/.env` on `alfred`. Never reuse `TS_AUTHKEY` here.

### 2. Firewall

`homelab-firewall.service` puts `incusdev` in a `dev` zone (DHCP and DNS to the host only, forwarding out allowed). It runs at boot, so it takes effect after the next image update and reboot. To apply it right away instead:

```bash
grep '^ExecStart=' /usr/lib/systemd/system/homelab-firewall.service   # confirm the dev-zone lines are in the booted image
sudo systemctl restart homelab-firewall.service
```

If the booted image doesn't have them yet, run the `dev` zone and `dev-out` policy `firewall-cmd` lines from `files/systemd/system/homelab-firewall.service` by hand with `sudo`, followed by `sudo firewall-cmd --reload`.

### 3. Incus

```bash
sudo incus network acl create dev-egress < ~/homelab/incus/acls/dev-egress.yaml
sudo incus admin init --preseed < ~/homelab/incus/preseed.yaml
```

Later changes to the ACL are applied with `sudo incus network acl edit dev-egress < ~/homelab/incus/acls/dev-egress.yaml`.

## Usage

```bash
homelab-dev up myproject          # creates dev-myproject, prints its deploy key
homelab-dev up myproject rust     # same, plus the Rust toolchain
homelab-dev install myproject rust   # add a toolchain to an existing VM
homelab-dev snapshot myproject    # before letting an agent loose
homelab-dev restore myproject <snapshot>
homelab-dev destroy myproject
```

After `up`:

1. Add the printed public key as a deploy key on that project's repo only.
2. From your machine: `ssh dev@dev-myproject`, clone the repo inside the VM, or connect with VS Code Remote-SSH and "Reopen in Container".
3. Don't forward your SSH agent to the VM (`ForwardAgent no`), and don't mount or copy personal credentials into it.

## Verifying isolation

From `homelab-dev shell <project>`:

- `curl -sI https://github.com` -- works (internet and DNS)
- `curl -m 5 http://10.77.0.1:22` and `curl -m 5 http://<alfred LAN IP>:22` -- fail (host)
- `curl -m 5 https://whoami.<tailnet-name>.ts.net` -- fails (tailnet policy)
- `ping -c1 -W2 <another dev VM's 10.77.0.x address>` -- fails (port isolation)
