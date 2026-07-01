# Reference

Lookup tables for `lab.env`, `lab.secrets`, tasks, ports, profiles, and the app
inventory. For narrative explanations see [architecture.md](architecture.md) and
[operations.md](operations.md).

---

## Hardware requirements

Sizing for the **full stack** (all apps + platform + host-side registry/Gitea).
`task check` reports the host's CPU/RAM/free-disk against these and warns when a
value is below the minimum (a warning, not a hard failure — the lab may still
start, but pods can stay `Pending` or get OOM-killed).

| Resource | Minimum | Recommended | Notes |
|---|---|---|---|
| CPU | 4 vCPU | 8 vCPU | crAPI schedules ~10 services; below the minimum they may not fit. |
| Memory | 8 GB | 16 GB | Below the minimum, expect OOM-kills / `Pending` pods. |
| Free disk | 40 GB | 60 GB | Measured on the filesystem backing `/var/lib/docker` (images + volumes). |

Cluster-only runs (`task cluster:only`, no apps) are much lighter — 2 vCPU / 4 GB
suffices for pure network / CNI testing.

---

## `lab.env` variables

`lab.env` holds **host/infra** settings only. Which apps deploy and how they're
exposed lives in Git (`argocd/lab-apps/`), not here.

| Variable | Default | Change needs | Notes |
|---|---|---|---|
| `LAB_HOST_IP` | — (required) | `task reset` | Your VM's primary IP; external clients reach apps here. |
| `LAB_DOMAIN` | `lab.local` | re-sync | Base domain for app hostnames / TLS SANs. |
| `CLUSTER_NAME` | `k3d-app-delivery-fabric` | `task reset` | k3d cluster name. |
| `CNI` | `cilium` | `task reset` | `cilium` or `calico` (installed post-cluster). |
| `LAB_AGENTS` | `2` | `task reset` | k3d agent node count (server is always 1). |
| `LAB_PROFILE` | `mixed` | re-bootstrap | Exposure scenario; selects `lab-apps/profiles/<name>.yaml`. |
| `INGRESS_KIND` | `none` | re-bootstrap | Routing layer flavour: `none`/`nginx`/`cis`/`gateway`. |
| `NODEPORT_RANGES` | `"30080-30099 30440-30459"` | `task reset` | Host NodePort bands published at create. |
| `ARGOCD_HTTP_PORT` | `30090` | `task reset` | Argo CD UI NodePort; must fall within `NODEPORT_RANGES`. |
| `ARGOCD_REPO_URL` | _(blank → auto)_ | re-bootstrap | Argo's source repo; blank auto-detects (Gitea → origin). |
| `ARGOCD_TARGET_REVISION` | _(blank → branch)_ | re-bootstrap | Branch/tag/SHA Argo tracks; blank = current branch. |
| `ARGOCD_WAIT_TIMEOUT` | `900` | n/a | Seconds `task argocd:wait` blocks for Healthy. |
| `REGISTRY_PORT` | `5000` | restart registry | Host registry port. |
| `REGISTRY_NAME` | `k3d-app-delivery-fabric-registry` | restart registry | Registry container name. |
| `GITEA_HTTP_PORT` | `3000` | restart Gitea | Gitea host port. |
| `GITEA_NAME` | `k3d-app-delivery-fabric-gitea` | restart Gitea | Gitea container name. |
| `GITEA_REPO` | `k3d-app-delivery-fabric` | re-setup | Repo name created in Gitea. |
| `GITEA_ADMIN_USER` | `giteaadmin` | re-setup | Gitea admin username. |
| `GITEA_IMAGE` | `gitea/gitea:1.22` | restart Gitea | Gitea image (commented by default). |

**Repo-URL resolution** (when `ARGOCD_REPO_URL` is blank): explicit value →
running Gitea with the lab repo → git `origin`. See
[architecture.md](architecture.md#source-of-truth-gitea-or-github).

---

## `lab.secrets` variables

`lab.secrets` is gitignored. All entries are optional.

| Variable | Purpose |
|---|---|
| `ARGOCD_ADMIN_PASSWORD` | Custom Argo CD admin password (bcrypt-hashed at install). |
| `ARGOCD_REPO_USERNAME` | Git username for a **private** `origin` repo (PAT auth ignores it; default `git`). |
| `ARGOCD_REPO_PASSWORD` | Git token/password for a **private** `origin` repo (a GitHub PAT with read access). |
| `GITEA_ADMIN_PASSWORD` | Gitea admin password (used to create the repo and push). |
| `NGINX_JWT`, `BIGIP_*`, `DOCKERHUB_*` | Placeholders for future modules. |

> A **public** Gitea repo needs no credential. `ARGOCD_REPO_USERNAME/PASSWORD` are
> only for a private `origin` (e.g. a private GitHub repo).

---

## Tasks

Run `task --list` for the live list. Grouped here by area.

### Lifecycle
| Task | Description |
|---|---|
| `task up` | Full bring-up (idempotent): cluster → CNI → cert-manager → Argo CD → apps. |
| `task down` | Delete the cluster (registry, CA, Gitea preserved). |
| `task reset` | `down` + `up` (rebuild the cluster). |
| `task cluster:only` | Cluster + CNI only (no apps). |
| `task cluster:reset` | Rebuild cluster + CNI only. |
| `task health` | Verify nodes, CNI, app rollouts, NodePort reachability. |
| `task test` | Curl smoke tests against exposed app endpoints. |

### Setup
| Task | Description |
|---|---|
| `task install` | Install prerequisites (sudo). |
| `task check` | Verify tools + `lab.env`/`lab.secrets` exist. |
| `task ca:init` | Create the local root CA. |
| `task cluster` | Create the k3d cluster (skips if it exists). |
| `task cni:install` / `cni:status` / `cni:hubble` | Install / status / Hubble UI (Cilium). |
| `task pre-deploy` | Bootstrap cert-manager + CA + ClusterIssuer. |

### Argo CD
| Task | Description |
|---|---|
| `task argocd:install` | Install Argo CD via Helm (NodePort UI). |
| `task argocd:bootstrap` | Resolve repo + apply the root app-of-apps. |
| `task argocd:wait` | Block until all Applications are Synced/Healthy. |
| `task argocd:apps` | List Applications with sync/health. |
| `task argocd:sync` | Force a hard refresh/sync of all Applications. |
| `task argocd:password` | Print the initial admin password. |
| `task argocd:ui` | Print the UI URL. |

### Gitea (self-hosted Git)
| Task | Description |
|---|---|
| `task gitea:setup` | Start Gitea, create the repo, push, wire `lab.env`. |
| `task gitea:push` | Push the current branch to Gitea. |
| `task gitea:status` / `gitea:ui` | Container/repo status; print UI URL. |
| `task gitea:stop` / `gitea:rm` | Stop (keep data) / remove container + volume. |

### Registry
| Task | Description |
|---|---|
| `task registry:setup` | Start the registry container (once). |
| `task registry:status` / `ls` | State + counts / list images. |
| `task registry:cache` | Pull all lab images → local registry. |
| `task registry:flush` | Delete all images (prompts). |
| `task registry:stop` / `rm` | Stop (keep data) / remove container + volume. |

### crAPI helpers
| Task | Description |
|---|---|
| `task crapi:mail` | Port-forward MailHog UI to `localhost:8025`. |
| `task crapi:logs` | Tail the identity service logs. |
| `task crapi:chart:update` | Re-vendor the upstream chart (re-applies lab patch). |

---

## Ports

| Service | Default NodePort | Notes |
|---|---|---|
| crAPI HTTP | `30080` | |
| crAPI HTTPS | `30443` | crAPI always serves both. |
| Juice Shop HTTP | `30081` | |
| Juice Shop HTTPS | `30444` | when TLS enabled. |
| DVGA HTTP | `30082` | |
| DVGA HTTPS | `30445` | when TLS enabled. |
| VAmPI HTTP | `30083` | |
| VAmPI HTTPS | `30446` | when TLS enabled. |
| Argo CD UI | `30090` | HTTP (insecure, lab only). |

All of the above fall inside the default `NODEPORT_RANGES`
(`30080-30099 30440-30459`). A ClusterIP app publishes **no** NodePort. Per-app
port assignments are in `argocd/lab-apps/values.yaml`.

---

## Exposure profiles

Selected by `LAB_PROFILE`; files in `argocd/lab-apps/profiles/`.

| Profile | Service type | Scheme | Reachable on host? |
|---|---|---|---|
| `mixed` | per-app (the committed mix) | per-app | per-app |
| `nodeport-http` | NodePort | HTTP | yes |
| `nodeport-https` | NodePort | HTTPS | yes |
| `clusterip-http` | ClusterIP | HTTP | no (ingress-prep) |
| `clusterip-https` | ClusterIP | HTTPS | no (ingress-prep) |

---

## `INGRESS_KIND` options

The lab **renders** these manifests; the controller that consumes them is run by
a **separate project**.

| Value | Renders (per app) | Requires (elsewhere) |
|---|---|---|
| `none` | nothing | — |
| `nginx` | `networking.k8s.io/v1` Ingress | an NGINX ingress controller |
| `cis` | `cis.f5.com/v1` VirtualServer | F5 CIS CRDs + controller + BIG-IP |
| `gateway` | `gateway.networking.k8s.io/v1` Gateway + HTTPRoute | Gateway API CRDs + controller |

Per-controller settings: `argocd/exposure/values.yaml`.

---

## App inventory

| App | Namespace | Service / Deployment | Container port | Chart |
|---|---|---|---|---|
| crAPI | `crapi` | `crapi-web` | 80 / 443 | vendored OWASP (`apps/crapi/chart`) |
| Juice Shop | `juice-shop` | `juice-shop` | 3000 | `apps/juiceshop/chart` |
| DVGA | `dvga` | `dvga` | 5013 | `apps/dvga/chart` |
| VAmPI | `vampi` | `vampi` | 5000 | `apps/vampi/chart` |

Descriptive metadata (display name, ready timeout, extra test paths) is in the
`APP_META` table in `scripts/lib.sh`. Ports and Service types are **not** there —
they're read live from the cluster by `health`/`test`.

---

## Repository layout

```
k3d-app-delivery-fabric/
├── README.md                 entry point
├── docs/                     this documentation
├── Taskfile.yaml             task automation
├── lab.env.example           host/infra config template
├── lab.secrets.example       credentials template (gitignored when copied)
├── scripts/                  bootstrap + lifecycle + helpers
│   ├── lib.sh                shared helpers + APP_META metadata
│   ├── create-cluster.sh     k3d cluster + NodePort ranges
│   ├── pre-deploy.sh         cert-manager + CA + ClusterIssuer
│   ├── install-argocd.sh / argocd-bootstrap.sh / argocd-wait.sh
│   ├── health-check.sh / test-endpoints.sh   (read the live cluster)
│   ├── registry-*.sh / gitea-*.sh            (host-side services)
│   └── crapi-chart-update.sh
├── apps/
│   ├── crapi/                vendored chart + values.yaml + lab-chart.patch
│   ├── juiceshop/chart/      per-app Helm chart
│   ├── dvga/chart/
│   └── vampi/chart/
└── argocd/
    ├── root-app.yaml         the app-of-apps entrypoint
    ├── lab-apps/             renders the AppProject + one Application per app
    │   ├── values.yaml       app set + per-app defaults (ports, namespaces)
    │   └── profiles/         LAB_PROFILE scenario files
    └── exposure/             routing manifests (INGRESS_KIND)
```
