# Polysite on one server: Docker Compose + Traefik

A ready-to-run deployment of [Polysite](https://github.com/polysites/polysite) behind **Traefik v3** with automatic Let's Encrypt certificates.
Click **Use this template**, and you have your own deployment repository. Routing is in `proxy/dynamic/polysite.yml` (file provider: no Docker socket
is mounted) and reproduces the core's Caddy routing, limits and headers; the same files are tested against the real stack (core `proxy/test`).

Tested with Polysite core **0.1.x**; images pinned in `docker-compose.yml`, bumped by Dependabot/Renovate.

## Quickstart

1. A Linux server with Docker Engine and Compose 2.24+, ports 80 and 443 open, DNS names for the public site and the admin pointing at it.
2. `./init.sh www.example.org admin.example.org`, then put your e-mail address in `proxy/traefik.yml` (`acme.email`).
3. `docker compose up -d`; Traefik requests the certificates on the first visit to each name (HTTP-01 on port 80).
4. Open `https://admin.example.org/admin`, enter the setup token, create the first administrator and site.

Add a public site domain: `|| Host(`other.example.net`)` to the `polysite-media`, `polysite-form-intake`, `polysite-api` and `polysite-web` rules (see the comment at the top of the file).

## Day two, secrets, hardening, troubleshooting

As in the Caddy template: change the three image tags and `docker compose pull && docker compose up -d` to upgrade; nightly backups into `./backups`; `GET /api/health`;
secrets only in `.env`. Certificates live in the `traefik-acme` volume (back it up or re-issue). Guide: https://polysites.github.io/polysite/guide/deploy/proxy

See [LICENSE-NOTE.md](LICENSE-NOTE.md).
