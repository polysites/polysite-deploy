# Polysite on Kubernetes (Helm)

Your own deployment repository for [Polysite](https://github.com/polysites/polysite) on a Kubernetes cluster: values, secret handling, and optional Argo CD, Flux and
kustomize examples. The chart is published as an OCI package: `oci://ghcr.io/polysites/charts/polysite`. The pinned version is in `chart.yaml`;
Renovate opens a pull request when a new chart is released.

Tested with chart **0.1.0** on Kubernetes 1.31 (k3s): install, the migration Job, an upgrade and a rollback, the whole first-run smoke test through an Ingress
(core `kubernetes/test/run.sh`).

## Quickstart

You need a cluster (1.27+) with an ingress controller and cert-manager (a ClusterIssuer), a PostgreSQL database reachable from it (the user needs `CREATEDB`),
`kubectl` and `helm` 3.8+, and two DNS names pointing at the ingress.

1. Edit `values.yaml`: the two domains, your ingress class, your ClusterIssuer.
2. `./scripts/create-secret.sh 'postgres://user:password@db-host:5432/polysite?sslmode=require'` (prints the setup token).
3. `./scripts/install.sh` (waits until the pods are ready; the migrations run first, in a Job).
4. Open `https://<admin domain>/admin`, enter the setup token, create the first administrator and site.

Only trying it out? Add `--set postgresql.enabled=true --set postgresql.password=...` to the helm command in `install.sh`: a single unmanaged demo database.

## Read before you scale

Run **one CMS replica and one web replica**. The chart refuses more unless you set `cms.allowMultiReplica` / `web.allowMultiReplica`: uploads live on one disk (there is no S3 adapter yet),
and role changes, sign-in limits and form spam limits live in each process's memory, so a role you revoke takes effect on only one replica
(from reading the code; see the guide). One replica still gets self-healing and rolling image updates; it is not active-active. The edge proxy and the ingress scale freely.
Plugins and themes need your own images built from source: `kubernetes/derived-image` in the core repository.

## Day two

| | |
| --- | --- |
| Upgrade | Merge the bot's pull request (a new `chartVersion`), then `./scripts/install.sh` (or let Argo CD / Flux apply it). The migration Job runs from the new image before the pods switch; read the release notes first. |
| Roll back | `helm rollback polysite <revision> -n polysite` puts the previous images back; migrations are additive, so older code runs on the newer schema. |
| Backups | A managed database has its own; the media volume is on you: `backups.enabled` (encrypted, off-site) or volume snapshots. Restore: the guide. |
| Health | `GET /api/health` through the admin hostname; `kubectl -n polysite get pods`. |
| Secrets | In the Secret only, never in git in plain text. Never change `PAYLOAD_SECRET` on a running install; keep a copy apart from backups. |
| Hardening | Pods run non-root, no capabilities, read-only root file systems, no service-account token; `networkPolicy.enabled` is an example policy. Checklist: https://polysites.github.io/polysite/guide/security |

Argo CD: `argocd/application.yaml`. Flux: `flux/`. kustomize: `kustomize/`. These three are examples that were **not** run against a live Argo CD, Flux or kustomize with OCI charts.
Guide: https://polysites.github.io/polysite/guide/deploy/kubernetes

See [LICENSE-NOTE.md](LICENSE-NOTE.md).
