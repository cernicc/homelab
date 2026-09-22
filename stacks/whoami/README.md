# whoami

[traefik/whoami](https://github.com/traefik/whoami) — a container that just echoes request/connection info back. No real function of its own; historically used as a smoke-test for the Traefik reverse proxy.

## Tailscale-sidecar ingress pattern

Traefik was removed (see git history) and replaced with per-service [Tailscale sidecars](https://tailscale.com/blog/docker-tailscale-guide): a `tailscale/tailscale` container per service, sharing its network namespace with the app container (`network_mode: service:<sidecar>`), with `tailscale serve` terminating HTTPS and proxying to the app over loopback.

This stack was the pilot for the pattern -- disposable, no real function, cheap to redo -- confirming that `cap_add: NET_ADMIN` + a real `/dev/net/tun` device works from inside this repo's **rootless Podman** setup (`PODMAN_USERNS=keep-id`, via `podman compose`) under its default SELinux enforcement, which every guide for this pattern assumes root Docker rather than rootless Podman for. It's now also rolled out to `stirling-pdf`, with the rest of the externally-reachable stacks to follow (see the removed Traefik labels in git history for the full list) -- each gets its own `<service>-ts` sidecar and its own `.ts.net` name.

## One-time setup (not tracked in git)

1. ACL policy -> add `"tagOwners": {"tag:homelab": ["group:owner", "autogroup:admin"]}` (or whichever owner makes sense) so a key can tag nodes with it.
2. Tailscale admin console -> Settings -> Keys -> Generate auth key, tagged `tag:homelab` (the tag rides with the key, so no `--advertise-tags` needed on the container).
3. DNS -> HTTPS Certificates -> enabled (required for `tailscale serve` to auto-issue `*.ts.net` certs).
4. Set `TS_AUTHKEY` in `~/homelab/.env` on `alfred`.

Note: an OAuth client (`TS_CLIENT_ID`/`TS_CLIENT_SECRET`) was tried first and consistently hit `403: calling actor does not have enough permissions to perform this function` on every `tailscale up` attempt, even with the OAuth client correctly scoped (`tag:homelab`, Core `Write`) and `tagOwners` correct -- root cause not identified, switched to a plain auth key instead per the blog guide.

## Verifying the sidecar

Over SSH on `alfred`:

- `podman logs whoami-ts` -- sidecar registers as a tailnet node, no restart loop
- `podman exec whoami-ts tailscale status` -- shows itself Active
- `journalctl -b | grep -i avc` -- no SELinux denials
- `https://whoami.<tailnet-name>.ts.net` -- loads with a valid cert and whoami's response
