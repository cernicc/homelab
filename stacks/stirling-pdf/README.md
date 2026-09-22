# stirling-pdf

[Stirling-PDF](https://www.stirlingpdf.com/) — self-hosted PDF toolkit (merge, split, convert, OCR, etc.). No ingress configured currently (Traefik was removed; nothing fronts this yet).

Login is disabled (`SECURITY_ENABLELOGIN=false`), same as `whoami`/`jellyfin` — anyone who can reach it has no auth in front of them. Flip that env var to `"true"` in `docker-compose.yml` if that ever needs to change; the default account is then `admin`/`stirling` on first boot, to be changed after logging in.

Uses the `-fat` image tag, which bundles the OCR/conversion tooling (LibreOffice, Tesseract, etc.) that the `-ultra-lite` tag drops.
