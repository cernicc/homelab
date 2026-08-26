# traefik

Reverse proxy + TLS termination for every other stack, plus its own dashboard at `traefik.${DOMAIN_NAME}`. Routing is Docker-label-driven (`providers.docker`); certs come from Let's Encrypt via Cloudflare's DNS-01 challenge (`CF_API_EMAIL`/`CF_DNS_API_TOKEN`).

## Wildcard default certificate

The `websecure` entrypoint requests one cert covering `${DOMAIN_NAME}` + `*.${DOMAIN_NAME}` at startup (`entryPoints.websecure.http.tls.domains`) and serves it as the entrypoint default. Individual stacks' `tls.certresolver=letsencrypt` router labels don't need to change — Traefik matches new cert requests against certs it already holds before requesting a new one, so every `*.${DOMAIN_NAME}` router just rides the one wildcard cert. Only single-level subdomains are covered (`foo.${DOMAIN_NAME}`, not `foo.bar.${DOMAIN_NAME}`), which is all this homelab uses.
