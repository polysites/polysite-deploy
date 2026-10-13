# Polysite on one server: Docker Compose + Caddy

A ready-to-run deployment of [Polysite](https://github.com/polysites/polysite): Caddy (automatic HTTPS), the CMS, the public site, PostgreSQL
and nightly backups, on one Linux server. Click **Use this template**, and you have your own deployment repository.

Tested with Polysite core **0.1.x**. The images are pinned in `docker-compose.yml` (`ghcr.io/polysites/polysite-{cms,web,backup}:v0.1.0`);
`.github/dependabot.yml` and `renovate.json` open a pull request when a new release is published.

## Quickstart (5 minutes, plus DNS)

1. A Linux server with Docker Engine and Compose 2.24+, ports 80 and 443 open, and two DNS names pointing at it (the public site and the admin).
2. `git clone <your repository> /opt/polysite && cd /opt/polysite`
3. `./init.sh www.example.org admin.example.org` writes `.env` with fresh random secrets and prints your **setup token**.
4. `docker compose up -d` (the first start pulls the images and takes a minute or two; Caddy gets certificates by itself).
5. Open `https://admin.example.org/admin`, enter the setup token and create the first administrator and site.

Use the **same** site domain you enter in the setup page as `SITE_DOMAIN`. More public sites: add them to `SITE_DOMAIN` separated by spaces? No:
each extra domain needs its own certificate, so add a block per domain to `Caddyfile` (copy the first one) and a Site record per domain in the admin.

## Day two

| | |
| --- | --- |
| Upgrade | Merge the bot's pull request (or edit the three `v0.1.0` tags), `docker compose pull && docker compose up -d`. Read the release's *Upgrade notes* first. Migrations run when the CMS starts. For a backup, test restore and automatic rollback around the upgrade use the core's `deploy/deploy.sh` instead. |
| Roll back | Put the previous tags back and `docker compose up -d`. Migrations are additive, so older code runs on the newer schema. |
| Backups | Nightly at 03:17 UTC into `./backups`, test restore every Sunday. **Set `BACKUP_RCLONE_REMOTE` and `BACKUP_ENCRYPTION_PASSPHRASE` in `.env`** for an off-site copy: a backup on the same machine is lost with it. Restore: stop `web` and `cms`, `docker compose --profile restore run --rm restore latest --yes`. |
| Health | `GET /api/health` on `https://<admin domain>`; `docker compose ps`. |
| Secrets | In `.env`, mode 600, never committed (`.gitignore`). Never change `PAYLOAD_SECRET` on a running install. Keep a copy of it, apart from the backups. |
| Plugins and themes | The published images hold the core only. A site with plugins or themes builds its own images from source and replaces the image names here. |
| Hardening | Containers run unprivileged with no capabilities; only 80 and 443 are published. The full checklist: https://polysites.github.io/polysite/guide/security |

## Troubleshooting

`docker compose logs --tail 50 cms` first. "refuses to start" with a secret named: replace the placeholder (32+ characters). A certificate that
does not arrive: the DNS name does not point at this server yet, or port 80 is blocked. The deployment guide has the rest:
https://polysites.github.io/polysite/guide/deploying

See [LICENSE-NOTE.md](LICENSE-NOTE.md).
