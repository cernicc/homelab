# invoice-builder

[Invoice Builder](https://github.com/piratuks/invoice-builder) — offline-first invoicing/quoting app, fronted by Traefik at `invoice-builder.${DOMAIN_NAME}`.

Runs the upstream `-standalone` layout as a single container: nginx (port 3001, what Traefik routes to) proxies `/api/*` to the Node backend (port 3000) inside the same container. That's `SERVICE=all` and `BACKEND_HOST=localhost` below — the two-container split upstream also ships isn't needed here since Traefik already does the outer proxying.

No login — same as `whoami`/`stirling-pdf`: anyone reachable on the tailnet can open it and start creating invoices. Data lives in the `app-data` volume as a SQLite file (`DB_DIRECTORY=/data`); back it up by copying the volume, or use the app's own JSON/XLSX export and full-database backup/restore from within the UI.

`VITE_API_URL` (mentioned in upstream's docs) is baked into the frontend at image-build time and doesn't apply here — nginx proxies API calls internally, so the pre-built `ghcr.io/piratuks/invoice-builder` image needs no rebuild.
