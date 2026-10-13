# Polysite on a server without containers (systemd + nginx/Apache/Caddy)

Your own deployment repository for [Polysite](https://github.com/polysites/polysite) run directly on Ubuntu: Node.js 24, PostgreSQL, two hardened systemd services
(the CMS and the web app, bound to loopback) and a reverse proxy in front. For hosts where Docker is not allowed, or where someone must see every process.
You take over what the images and the deploy script do: **building from source, running the migrations and updating Node.js**.

The core version is pinned in `VERSION` (a git tag of the core repository: `v0.1.0`); Renovate/Dependabot cannot bump a git tag in a text file, so watch the releases.
Tested with Polysite core **0.1.x**.

## What was tested

In a container (`sh test.sh`): both apps were built from source with the steps in `scripts/build.sh` on Node.js 24 and started with the exact commands of the two unit files
(minus systemd) against PostgreSQL, behind the nginx configuration from `proxy/nginx`, and the core's first-run smoke test and proxy checks passed.
**Not run:** systemd itself (the units' hardening options, `ProtectSystem=strict` and the writable paths), `scripts/install.sh` as root on a real server (apt, NodeSource, PostgreSQL role, ufw),
Apache and Caddy against this layout, and certbot. Try it on a throwaway server first.

## Quickstart (Ubuntu 22.04 / 24.04, as root)

1. DNS for the public site and the admin pointing at the server.
2. `git clone <your copy of this repository> /root/polysite-deploy && cd /root/polysite-deploy`
3. `./scripts/install.sh www.example.org admin.example.org` installs the packages, creates the database and `/etc/polysite/polysite.env` (random secrets), clones the core at the pinned tag, builds, starts the services and configures nginx. It prints the setup token (also in `/root/polysite-setup.txt`).
4. Certificates: `apt-get install certbot`, then `certbot certonly --webroot -w /var/www/certbot -d <site> ` and again for the admin (`mkdir -p /var/www/certbot` first); replace `/etc/nginx/conf.d/polysite.conf` by `proxy/nginx/polysite-tls.conf` (set the domains) and `systemctl reload nginx`. Then set `CMS_SCHEME` / `SITE_SCHEME` to `https` in `/etc/polysite/polysite.env` and `systemctl restart polysite-cms polysite-web`.
5. Open `https://<admin domain>/admin`, enter the setup token, create the first administrator and site.

Apache: `proxy/apache/*.conf` (see the proxy guide). Caddy: `proxy/caddy/Caddyfile` (loopback upstreams; set `SITE_DOMAIN`, `CMS_DOMAIN`, the schemes in Caddy's environment).

## Day two

| | |
| --- | --- |
| Upgrade | Back up first (below). `git -C /opt/polysite/src fetch --tags && git -C /opt/polysite/src checkout v<new>`, `sh scripts/build.sh`, `systemctl restart polysite-cms polysite-web` (the CMS unit runs `payload migrate` before it starts). Read the release notes. |
| Roll back | Check out the previous tag, rebuild, restart. Migrations are additive, so older code runs on the newer schema. A rebuild takes minutes: for fast rollbacks keep the previous `src` tree as a second directory and switch a symlink. |
| Backups | Database: `pg_dump --format=custom` on a schedule (or your managed database's); uploads: `/opt/polysite/src/apps/cms/media`. The core's backup scripts (`backup`) run on a host too (they need `pg_dump`, `openssl`, `rclone`). Keep `PAYLOAD_SECRET` apart from the backups. Restore: `pg_restore` and copy the media back with the services stopped. |
| Health | `curl -fsS http://127.0.0.1:3001/api/health` and `:3000/api/health`; `systemctl status polysite-cms polysite-web`; `journalctl -u polysite-cms -n 100`. |
| Secrets | `/etc/polysite/polysite.env`, mode 640 root:polysite. Never change `PAYLOAD_SECRET` on a running install. |
| Hardening | Both services run as an unprivileged user with `NoNewPrivileges`, `ProtectSystem=strict`, no capabilities, loopback-only listeners; the proxy is the only public listener; ufw allows 22, 80, 443. Keep Node.js (24 LTS), PostgreSQL and the OS patched: nothing does it for you except `unattended-upgrades` for the OS packages. Checklist: https://polysites.github.io/polysite/guide/security |

Plugins and themes: put them in `/opt/polysite/src/plugins` and `/opt/polysite/src/themes` before `build.sh` (they are fixed at build time).
Guide: https://polysites.github.io/polysite/guide/deploy/baremetal

See [LICENSE-NOTE.md](LICENSE-NOTE.md).
