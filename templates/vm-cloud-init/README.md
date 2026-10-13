# Polysite on a fresh VM: cloud-init (plus an AWS EC2 Terraform skeleton)

One file, `cloud-init.yaml`, turns a brand-new Ubuntu 22.04 or 24.04 server into a running Polysite: Docker Engine (from Docker's own repository, signing-key
fingerprint checked), a firewall (SSH, 80, 443), automatic security updates, a swap file on small machines, and the stack of the
[Caddy template](../compose-caddy) (automatic HTTPS, CMS, site, PostgreSQL, nightly backups) started by systemd. Works on any cloud that accepts cloud-init
"user data" (AWS EC2, Google Compute Engine, DigitalOcean, Hetzner, Azure, a local multipass or LXD VM).

Tested with Polysite core **0.1.x**. What was checked for real, without a cloud account: the file is valid against cloud-init's own schema, the scripts pass shellcheck, on a clean
Ubuntu 24.04 container the files it writes produce a complete `.env` with fresh secrets, Docker's key has the fingerprint the script requires, and Docker's apt repository offers the packages
(`sh test.sh`). **Not run:** the bootstrap as root on a real VM (firewall, systemd, starting Docker). Do a first run on a throwaway VM.

## Quickstart

1. Edit the two domain names in `cloud-init.yaml` (`/etc/polysite-bootstrap.env`, near the top).
2. Create a VM (2 vCPU, 4 GB RAM recommended; 2 GB works with the swap file; 20 GB disk) and paste the file as **user data**. AWS: *Advanced details > User data*. Inbound 22 (your address), 80, 443.
3. Point DNS (both names) at the VM.
4. After 3 to 6 minutes: `ssh ubuntu@<ip> sudo cat /root/polysite-setup.txt` shows the **setup token**; open `https://<admin domain>/admin`.
   Progress: `tail -f /var/log/polysite-bootstrap.log`.

`cloud-init.yaml` is generated: edit `files/` or `../compose-caddy`, then `sh build.sh`; `sh test.sh` fails when it is stale.

## AWS with Terraform (`terraform-aws/`)

Creates an EC2 instance (Ubuntu 24.04, encrypted gp3 root volume, IMDSv2 only), an Elastic IP and a security group, and passes `cloud-init.yaml` with your domains as user data. It creates no DNS records
and no database. `terraform validate` passes (Terraform 1.10, AWS provider 5.x); it was **never applied**. Review `terraform plan` before you apply.

```bash
cd terraform-aws
terraform init && terraform plan -var site_domain=www.example.org -var admin_domain=admin.example.org -var ssh_cidr=203.0.113.7/32
```

## Cloud notes

- **AWS:** EBS is the disk (snapshot it on a schedule: Data Lifecycle Manager); RDS PostgreSQL instead of the container: set `DATABASE_URL` to it (the database user needs `CREATEDB`), remove the `db` service, and size the backup image's client to the server's major version; S3 can hold the encrypted off-site backups (rclone `s3`), but **not** the media: there is no S3 storage adapter yet.
- **Google Compute Engine / Cloud SQL** (the pilot's shape): paste as `user-data` metadata on an Ubuntu image; use `docker-compose.prod.yml` of the core with the Cloud SQL proxy instead of the bundled `db`.
- **DigitalOcean / Hetzner:** paste as user data; their cloud firewall is a second layer on top of `ufw`. Managed PostgreSQL works as for RDS.

## Day two

Upgrade: change the three image tags in `/opt/polysite/docker-compose.yml` (or merge the bot's pull request in your copy of this repository and `git pull` on the server), `cd /opt/polysite && docker compose pull && docker compose up -d`; roll back by putting them back.
Backups go to `/opt/polysite/backups` and nightly; **set an off-site remote and passphrase in `/opt/polysite/.env`** and snapshot the disk. Secrets are in `/opt/polysite/.env` (mode 600). Guides: https://polysites.github.io/polysite/guide/deploy/vm

See [LICENSE-NOTE.md](LICENSE-NOTE.md).
