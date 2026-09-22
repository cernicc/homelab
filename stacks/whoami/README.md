# whoami

[traefik/whoami](https://github.com/traefik/whoami) — a container that just echoes request/connection info back. No real function of its own; historically used as a smoke-test for the Traefik reverse proxy.

## Pilot for the Tailscale-sidecar ingress pattern

Traefik was removed (see git history) and is being replaced with per-service [Tailscale sidecars](https://tailscale.com/blog/docker-tailscale-guide): a `tailscale/tailscale` container per service, sharing its network namespace with the app container (`network_mode: service:<sidecar>`), with `tailscale serve` terminating HTTPS and proxying to the app over loopback.

This stack is the **pilot** for that pattern -- disposable, no real function, cheap to redo -- before rolling it out to every other stack. The main open question it's meant to answer: whether `cap_add: NET_ADMIN` + a real `/dev/net/tun` device actually works from inside this repo's **rootless Podman** setup (`PODMAN_USERNS=keep-id`, via `podman compose`) and its default SELinux enforcement -- every guide for this pattern assumes root Docker, not rootless Podman.

## One-time setup (not tracked in git)

1. Tailscale admin console -> Settings -> OAuth clients -> new client, scope `Devices: Write`, restricted to a tag it owns.
2. ACL policy -> add `"tagOwners": {"tag:homelab": ["autogroup:admin"]}` (or whichever owner makes sense) so the client can tag nodes with it.
3. DNS -> HTTPS Certificates -> enabled (required for `tailscale serve` to auto-issue `*.ts.net` certs).
4. Set `TS_OAUTH_CLIENT_ID` / `TS_OAUTH_CLIENT_SECRET` in `~/homelab/.env` on `alfred`.

## Validating the pilot

After `homelab-sync` picks this up (or `systemctl --user reload docker-compose@whoami.service` to test sooner), over SSH on `alfred`:

- `podman logs whoami-ts` -- sidecar registers as a tailnet node, no restart loop
- `podman exec whoami-ts tailscale status` -- shows itself Active
- `journalctl -b | grep -i avc` -- no SELinux denials
- `https://whoami.<tailnet-name>.ts.net` -- loads with a valid cert and whoami's response

If `NET_ADMIN`/`/dev/net/tun` fails under rootless Podman, the fallback is `TS_USERSPACE=true` (drop the `cap_add`/`devices` block) -- inbound `serve` proxying to `127.0.0.1` over the shared loopback shouldn't strictly need a real TUN interface, only genuine tailnet routing/subnet-router use cases do. Needs empirical confirmation either way.

Once confirmed working, the same pattern rolls out to every other stack's externally-reachable service (see the removed Traefik labels in git history for the full list) -- each gets its own `<service>-ts` sidecar and its own `.ts.net` name.
