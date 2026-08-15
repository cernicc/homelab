# invoice-ninja

`app` (invoiceninja-debian) + `nginx` + `mysql` + `redis`, fronted by Traefik at `invoices.${DOMAIN_NAME}`.

## APP_ENV

The image's entrypoint (`/usr/local/bin/init.sh`) runs under `sh -eu` and does `if [ "$APP_ENV" = "production" ]` — with `APP_ENV` unset that's an unbound-variable error, and the container exits before ever starting supervisord. `APP_ENV=production` must be set in `~/homelab/.env`; it's also what gates running migrations and the first-admin bootstrap below.

## APP_KEY

Generate one with the same image pinned in `docker-compose.yml`:

```bash
docker run --rm invoiceninja/invoiceninja-debian:5.13.31 php artisan key:generate --show
```

Set the result as `APP_KEY` in `~/homelab/.env`.

## First admin account

The `app` container's entrypoint creates the first admin account from `IN_USER_EMAIL`/`IN_PASSWORD`, but only once — it's gated by "no account exists yet in the database" and is skipped on every start after that, regardless of what those two vars are set to.

Because of that, don't put them in the persisted `~/homelab/.env`. Pass them ephemerally, only on the very first deploy of this stack, as shell-exported vars for that one `up` invocation:

```bash
IN_USER_EMAIL=admin@example.com IN_PASSWORD=changeme \
  podman compose --env-file ~/homelab/.env up -d
```

Compose's variable interpolation prefers shell env over the `.env` file, so the container sees them for that one run without either ever touching disk. Every later start (via `docker-compose@invoice-ninja.service`) runs with both vars simply absent — harmless, since account creation is already skipped by then.
