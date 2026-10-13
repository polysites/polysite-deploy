# Polysite on one server: Docker Compose + Apache httpd

A ready-to-run deployment of [Polysite](https://github.com/polysites/polysite) behind **Apache httpd** (mod_proxy) with certbot certificates.
Click **Use this template**, and you have your own deployment repository. `proxy/` reproduces the core's Caddy routing, limits and headers and is tested
against the real stack (core `proxy/test`).

Tested with Polysite core **0.1.x**; images pinned in `docker-compose.yml`, bumped by Dependabot/Renovate.

## Quickstart

1. A Linux server with Docker Engine and Compose 2.24+, ports 80 and 443 open, DNS names for the public site and the admin pointing at it.
2. `./init.sh www.example.org admin.example.org` (writes `.env` with random secrets and the domains into `proxy/`; prints your setup token).
3. `docker compose up -d` (plain http for now).
4. Certificates: `docker compose --profile certbot run --rm certbot certonly --webroot -w /var/www/certbot -d www.example.org` and again with `-d admin.example.org`.
5. In `docker-compose.yml` set `command: ["httpd-foreground", "-DTLS"]`, then `docker compose up -d apache`.
6. Open `https://admin.example.org/admin`, enter the setup token, create the first administrator and site.
7. Renewal (daily cron): `cd /opt/polysite && docker compose --profile certbot run --rm certbot renew && docker compose exec apache httpd -k graceful`.

**Know this:** Apache's `LimitRequestBody` is not applied to proxied requests (found by testing), so the configuration checks the declared `Content-Length` with rewrite rules
and refuses chunked request bodies with HTTP 411; browsers never send those for forms or uploads. If a client of yours streams chunked uploads, use the nginx or Caddy template.

## Day two, secrets, hardening, troubleshooting

As in the Caddy template: change the three image tags and `docker compose pull && docker compose up -d` to upgrade (put them back to roll back); nightly backups into
`./backups` (set the off-site remote and passphrase in `.env`); `GET /api/health`; secrets only in `.env`. Guide: https://polysites.github.io/polysite/guide/deploy/proxy

See [LICENSE-NOTE.md](LICENSE-NOTE.md).
