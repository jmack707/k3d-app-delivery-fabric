# cni-net-lab

A standalone Kubernetes CNI/network testing lab built on k3d. No ingress controller — direct NodePort access only. Designed for CNI comparison (Calico vs Cilium), network policy testing, and BIG-IP/NGINX integration work later.

## What you get

- A k3d cluster with **no Klipper LB**, **no Traefik**, no default CNI
- Your choice of **Calico** or **Cilium** installed post-cluster
- **Argo CD** managing every app via GitOps — an app-of-apps that reconciles each workload from this git repo
- Up to four intentionally vulnerable demo apps reachable via **NodePort** on `LAB_HOST_IP`
- Per-app **HTTP or HTTPS** and **NodePort or ClusterIP** — declared in `argocd/lab-apps/values.yaml`
- A **Docker registry v2** container running independently on the host — not coupled to the cluster lifecycle

## Component lifecycle

The three host-side components are intentionally independent of the cluster:

```
Registry ──── long-lived host container, started once, never torn down with the cluster
CA       ──── files on disk (root_ca.crt / root_ca.key), created once
Cluster  ──── ephemeral, task up / task down / task reset as needed
```

Inside the cluster, **Argo CD owns the apps**. You don't `kubectl apply` or `helm
install` workloads directly — you edit manifests in git and Argo CD reconciles
them. `task up` bootstraps the cluster, CNI, cert-manager, and Argo CD, then
hands app deployment over to Argo.

`task down` and `task reset` never touch the registry or CA.

## Prerequisites

All tools are installed by `sudo bash scripts/install-prereqs.sh` (Ubuntu 22.04 / 24.04).

| Tool | Purpose | Installed by script |
|---|---|---|
| Docker CE | Runs k3d nodes and the registry container | Yes |
| kubectl | Cluster management | Yes |
| k3d v5.7.4 | Kubernetes-in-Docker | Yes |
| Helm | CNI and cert-manager installs | Yes |
| Helmfile | Multi-chart orchestration (future use) | Yes |
| helm-diff | Helmfile dependency | Yes |
| Task | Taskfile automation | Yes |
| curl, python3, openssl, envsubst | Script dependencies | Yes (via apt) |

Run `task check` at any time to verify all tools are present.

## Quick start

```bash
# 1. Install prerequisites (once, requires sudo)
sudo bash scripts/install-prereqs.sh
# Log out and back in after this step (docker group membership)

# 2. Copy and edit config
cp lab.env.example lab.env          # set LAB_HOST_IP, CNI, LAB_APPS, HTTPS_APPS
cp lab.secrets.example lab.secrets  # fill in credentials when needed

# 3. Verify tools
task check

# 4. Start the registry (once — survives everything)
task registry:setup
task registry:cache    # optional: pre-pull all images while online

# 5. Bring up the lab
task up

# 6. Verify
task health
task test
```

For a cluster-only bring-up (no apps, pure network testing):

```bash
task cluster:only
```

## lab.env key settings

| Variable | Default | Notes |
|---|---|---|
| `LAB_HOST_IP` | — | Your Ubuntu VM's IP. Run: `ip route get 1.1.1.1 \| grep -oP 'src \K[\d.]+'` |
| `CNI` | `cilium` | `calico` or `cilium`. Change requires `task reset`. |
| `LAB_AGENTS` | `2` | k3d agent count. Change requires `task reset`. |
| `LAB_APPS` | all four | Space-separated: `crapi juiceshop dvga vampi` |
| `HTTPS_APPS` | `"crapi juiceshop"` | Subset of `LAB_APPS`. Others get HTTP only. |

## App endpoints

| App | HTTP | HTTPS (if in HTTPS_APPS) |
|---|---|---|
| crAPI | `http://LAB_HOST_IP:30080` | `https://LAB_HOST_IP:30443` |
| Juice Shop | `http://LAB_HOST_IP:30081` | `https://LAB_HOST_IP:30444` |
| DVGA | `http://LAB_HOST_IP:30082` | `https://LAB_HOST_IP:30445` |
| VAmPI | `http://LAB_HOST_IP:30083` | `https://LAB_HOST_IP:30446` |
| **Argo CD UI** | `http://LAB_HOST_IP:30090` | — (insecure/HTTP, lab only) |

All ports are configurable in `lab.env`. Changing them requires `task reset`.

Argo CD login: user `admin`. By default Argo CD generates a random password —
read it with `task argocd:password`. To set your own instead, put it in
`lab.secrets`:

```bash
# lab.secrets
ARGOCD_ADMIN_PASSWORD=your-password-here
```

`task argocd:install` bcrypt-hashes it before passing it to Helm (the plaintext
never lands in the cluster), and re-applies it on every install — so it always
wins over a password changed in the UI. When set, `task argocd:password` no
longer applies (Argo CD skips the random initial-admin secret).

## Common tasks

```bash
# Lab lifecycle
task up                    # cluster + CNI + cert-manager + Argo CD + GitOps apps
task cluster:only          # cluster + CNI only (no Argo CD, no apps)
task down                  # destroy cluster (registry and CA untouched)
task reset                 # destroy + rebuild cluster
task cluster:reset         # destroy + rebuild cluster only (no apps)

# Health & tests
task health                # verify cluster, CNI, and app pods
task test                  # curl smoke tests against all NodePorts

# Argo CD / GitOps
task argocd:install        # install Argo CD via Helm (run by 'task up')
task argocd:bootstrap      # register the root app-of-apps (run by 'task up')
task argocd:apps           # list Applications with sync/health status
task argocd:wait           # block until all Applications are Synced + Healthy
task argocd:sync           # force a hard refresh/sync of all Applications
task argocd:password       # print the initial admin password
task argocd:ui             # print the Argo CD UI URL

# CNI
task cni:status            # show CNI pod status
task cni:hubble            # Hubble UI → http://localhost:12000 (Cilium only)

# Registry (independent of cluster)
task registry:setup        # start registry container (run once)
task registry:status       # show container state and image count
task registry:ls           # list all images and tags
task registry:cache        # pull all lab images from internet → registry
task registry:flush        # delete all registry images (with confirmation)
task registry:stop         # stop registry container (preserves data volume)
task registry:rm           # remove container + data volume (irreversible)
```

## Switching CNI

Edit `lab.env`:
```bash
CNI=calico   # or cilium
```
Then:
```bash
task reset   # required — CNI is installed at cluster creation time
```

## GitOps with Argo CD

Apps are managed declaratively. Argo CD watches this repo and reconciles the
cluster to match it — there is no `task apps:up`/`apps:down` any more.

### Layout

```
argocd/
  root-app.yaml                 # the "app of apps" entrypoint (bootstrapped once)
  lab-apps/                     # Helm chart that renders one Argo Application per app
    values.yaml                 # ← which apps deploy, and how they're exposed
    templates/
      appproject.yaml           # the cni-net-lab AppProject
      applications.yaml         # one Application per enabled app
apps/
  crapi/chart  + values.yaml    # vendored upstream OWASP chart + lab overrides
  juiceshop/chart               # per-app Helm chart (deployment, service, TLS sidecar, cert)
  dvga/chart
  vampi/chart
```

### How it flows

1. `task argocd:install` installs Argo CD (UI on `LAB_HOST_IP:30090`).
2. `task argocd:bootstrap` renders `argocd/root-app.yaml` — filling in the repo
   URL (your `origin` remote), the target revision (your current branch), and
   `LAB_HOST_IP`/`LAB_DOMAIN` — and applies it.
3. The root app syncs `argocd/lab-apps`, which creates the `cni-net-lab`
   AppProject and one `Application` per app.
4. Each app Application syncs its Helm chart into the app's namespace
   (`CreateNamespace=true`, `prune`, `selfHeal` all on).

`task up` runs steps 1–2 for you, then `task argocd:wait` blocks until every
Application reports **Synced / Healthy** before the final `task health`.

### Changing what's deployed

Edit `argocd/lab-apps/values.yaml`, commit, and push. Argo CD picks the change
up automatically (or run `task argocd:sync` to force an immediate refresh):

```yaml
apps:
  juiceshop:
    enabled: true        # set false to remove the app entirely
    tls: true            # HTTP-only when false (drops the nginx TLS sidecar + cert)
    serviceType: NodePort  # or ClusterIP to hide it from the host (e.g. behind an ingress)
```

> Keep `HTTPS_APPS` / `CLUSTERIP_APPS` in `lab.env` in sync with this file —
> `task health` and `task test` read those lists to decide what to probe.

ClusterIP apps are **not** reachable on `LAB_HOST_IP`; port-forward to reach one:

```bash
kubectl port-forward -n dvga svc/dvga 8082:5013   # then browse http://localhost:8082
```

### Private repositories

Argo CD clones this repo to read the manifests. If the repo is **private**,
anonymous cloning fails and the root Application stays stuck at
**Sync = Unknown** with no child apps ever appearing. Give Argo CD a read
credential in `lab.secrets` (a GitHub Personal Access Token with read access):

```bash
# lab.secrets
ARGOCD_REPO_USERNAME=git          # ignored for PAT auth; any value works
ARGOCD_REPO_PASSWORD=ghp_your_token
```

Then re-run `task argocd:bootstrap` — it registers an Argo CD repository Secret
before applying the root app. (Making the repo public also works and needs no
credential.)

### Self-hosted Git (Gitea)

To drop the GitHub dependency entirely, run **Gitea** as a host container — the
same independent, long-lived pattern as the registry. Argo CD then pulls from
Gitea over the cluster-internal `host.k3d.internal` address, so the lab is fully
self-contained and air-gappable.

```bash
task gitea:setup     # start Gitea, create the lab repo (public), push current branch
```

It prints the exact lines to put in `lab.env`:

```bash
ARGOCD_REPO_URL=http://host.k3d.internal:3000/giteaadmin/cni-net-lab.git
ARGOCD_TARGET_REVISION=<your branch>
```

Then re-point Argo CD at it:

```bash
task argocd:bootstrap && task argocd:wait
```

The repo is created **public**, so Argo needs no credential. Day-to-day GitOps
loop once it's wired up:

```bash
# edit manifests → commit → publish to Gitea → let Argo reconcile
git commit -am "tweak juiceshop"
task gitea:push
task argocd:sync          # optional; Argo auto-refreshes anyway
```

Gitea lifecycle (independent of `task up/down/reset`, like the registry):

```bash
task gitea:setup     # start + create repo + push (idempotent)
task gitea:status    # container state, API, repo URL
task gitea:push      # push current branch after commits
task gitea:stop      # pause (keeps data volume)
task gitea:rm        # remove container + data volume (irreversible)
```

The Gitea admin user is `GITEA_ADMIN_USER` (default `giteaadmin`); set
`GITEA_ADMIN_PASSWORD` in `lab.secrets`. Web UI: `http://LAB_HOST_IP:3000`.

### Pointing Argo CD at a fork or fixed branch

By default the bootstrap tracks your `origin` remote and current branch. To pin
it, set these in `lab.env` and re-run `task argocd:bootstrap`:

```bash
ARGOCD_REPO_URL=https://github.com/<you>/cni-net-lab.git
ARGOCD_TARGET_REVISION=main
```

## Registry

The registry is a plain Docker v2 container that runs on the host outside any cluster. It is bound to both `127.0.0.1:5000` and `LAB_HOST_IP:5000` so it's reachable from the host itself, from cluster nodes (via `host.k3d.internal`), and from other machines on the LAN.

It is not started or stopped by `task up/down/reset`. Manage it separately:

```bash
task registry:setup    # create and start (idempotent)
task registry:status   # quick health check
task registry:stop     # pause without losing data
task registry:rm       # full removal including data volume
```

k3d nodes are pre-configured with registry mirrors pointing at
`host.k3d.internal:5000`, so image pulls resolve to the local registry
automatically when an image is present there.

## TLS trust

When any app is in `HTTPS_APPS`, a local root CA (`root_ca.crt`) is created and used by cert-manager. Install it in your OS/browser to avoid TLS warnings:

```bash
# macOS
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain root_ca.crt

# Ubuntu / Debian
sudo cp root_ca.crt /usr/local/share/ca-certificates/cni-net-lab.crt
sudo update-ca-certificates
```

## Adding an ingress controller later

The cluster has no ingress controller by design. When you're ready to add NGINX or BIG-IP CIS:

1. Install the controller into the cluster normally (Helm or kubectl)
2. Update app Services from `NodePort` to `ClusterIP` if routing through ingress
3. Add Ingress or VirtualServer resources per app

The NodePort bindings in `create-cluster.sh` can coexist with an LB/ingress — no cluster rebuild required for that change.
