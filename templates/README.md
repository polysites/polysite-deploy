# Deployment templates

Each folder here is a **self-contained deployment repository** that can be copied unchanged into its own GitHub *template repository* (`polysites/deploy-<name>`), so a user clicks *Use this template*
and has a deployment repository of their own. They consume the published **packages** (container images and the Helm chart on `ghcr.io/polysites`) by pinned version; Dependabot and Renovate
(configured in each folder) open a pull request when a new release appears.

| Folder | Repository | For |
| --- | --- | --- |
| `compose-caddy` | `deploy-compose-caddy` | One server, Docker Compose, Caddy (automatic HTTPS). The reference path |
| `compose-nginx`, `compose-apache`, `compose-traefik` | `deploy-compose-nginx`, `-apache`, `-traefik` | The same with your own proxy |
| `kubernetes-helm` | `deploy-kubernetes-helm` | A cluster: values, secret script, Argo CD, Flux and kustomize examples |
| `vm-cloud-init` | `deploy-vm-cloud-init` | A fresh Ubuntu VM from cloud-init user data; AWS EC2 Terraform skeleton |
| `bare-metal` | `deploy-bare-metal` | No containers: systemd units and a reverse proxy |

Rules for a template: nothing outside its folder (the proxy files are copies of the tested `proxy` files, and a check fails when they drift); a `README.md` with a five-minute quickstart,
what was tested and with which core version; `.env.example` or values with no real secret; pinned image tags (literal, so Dependabot can read them) or a chart version; `.github/dependabot.yml`,
`renovate.json`, a `validate.yml` workflow that only lints; `LICENSE-NOTE.md` (a template does not pick your licence for you).

Checks: `sh templates/test.sh static` (no images needed), `sh templates/test.sh run caddy|nginx|apache` (starts the stack from local images), `templates/vm-cloud-init/test.sh`, `templates/bare-metal/test.sh <core checkout>`.
Export: `publish-templates.sh (private tooling)` (a dry run unless you pass `--apply`, and it pushes nothing without `--push`). Versions pinned in the templates (`v0.1.0`, chart `0.1.0`) are the first release's;
update them when a release is cut. Docs: [Deployment options](../docs/guide/deploy/index.md).
