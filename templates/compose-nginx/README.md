# Polysite on one server: Docker Compose + nginx

A ready-to-run deployment of [Polysite](https://github.com/polysites/polysite) behind **nginx** with Let's Encrypt certificates from certbot.
Click **Use this template**, and you have your own deployment repository. The nginx configuration (`proxy/`) reproduces the core's
Caddy routing, request-size limits and security headers, and is tested against the real stack (core `proxy/test`).

Tested with Polysite core **0.1.x**; images pinned in `docker-compose.yml`, bumped by Dependabot/Renovate.

## Quickstart

1. A Linux server with Docker Engine and Compose 2.24+, ports 80 and 443 open, DNS names for the public site and the admin pointing at it.
2. `./init.sh www.example.org admin.example.org` (writes `.env` with random secrets and the domains into `proxy/`; prints your setup token).
3. `docker compose up -d` (plain http for now).
4. Certificates: `docker compose --profile certbot run --rm certbot certonly --webroot -w /var/www/certbot -d www.example.org` and again with `-d admin.example.org`.
5. In `docker-compose.yml` change `./proxy/polysite.conf` to `./proxy/polysite-tls.conf`, then `docker compose up -d nginx`.
6. Open `https://admin.example.org/admin`, enter the setup token, create the first administrator and site.
7. Renewal: add to cron `cd /opt/polysite && docker compose --profile certbot run --rm certbot renew && docker compose exec nginx nginx -s reload` (daily).

An extra public site domain needs its own certificate and a name in the `server_name` line (and its own `ssl_certificate` pair in the TLS file).

## Day two, secrets, hardening, troubleshooting

Same as the Caddy template (`../compose-caddy`; the text is in the core guides): upgrade by changing the three image tags and `docker compose pull && docker compose up -d`;
roll back by putting them back; nightly backups into `./backups` (set the off-site remote and passphrase in `.env`); `GET /api/health`;
secrets only in `.env`. Known differences: nginx cannot remove its `Server` header (only the version), and `http2 on;` needs nginx 1.25.1+ (the image has it).
Guide: https://polysites.github.io/polysite/guide/deploy/proxy

See [LICENSE-NOTE.md](LICENSE-NOTE.md).
