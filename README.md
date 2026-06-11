# cni-net-lab

A standalone Kubernetes CNI/network testing lab built on k3d. No ingress controller — direct NodePort access only. Designed for CNI comparison (Calico vs Cilium), network policy testing, and BIG-IP/NGINX integration work later.

## What you get

- A k3d cluster with **no Klipper LB**, **no Traefik**, no default CNI
- Your choice of **Calico** or **Cilium** installed post-cluster
- Up to four intentionally vulnerable demo apps reachable via **NodePort** on `LAB_HOST_IP`
- Per-app **HTTP or HTTPS** — listed in `HTTPS_APPS`, rest get plain HTTP
- A **Docker registry v2** container running independently on the host — not coupled to the cluster lifecycle
- Individual `task <app>:up` / `task <app>:down` for each app

## Component lifecycle

The three components are intentionally independent:

```
Registry ──── long-lived host container, started once, never torn down with the cluster
CA       ──── files on disk (root_ca.crt / root_ca.key), created once
Cluster  ──── ephemeral, task up / task down / task reset as needed
```

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

All ports are configurable in `lab.env`. Changing them requires `task reset`.

## Common tasks

```bash
# Lab lifecycle
task up                    # cluster + CNI + apps
task cluster:only          # cluster + CNI only (no apps)
task down                  # destroy cluster (registry and CA untouched)
task reset                 # destroy + rebuild cluster
task cluster:reset         # destroy + rebuild cluster only (no apps)

# Health & tests
task health                # verify cluster, CNI, and app pods
task test                  # curl smoke tests against all NodePorts

# Individual apps
task crapi:up              # start crAPI only
task crapi:down            # stop crAPI only
task apps:up               # start all LAB_APPS
task apps:down             # stop all LAB_APPS
APP=dvga task apps:up      # start a single app by name

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

## Switching HTTP ↔ HTTPS per app

Edit `lab.env`:
```bash
HTTPS_APPS="crapi"          # only crAPI gets TLS
# HTTPS_APPS=""             # all HTTP, skip cert-manager entirely
```
Then restart just the affected app:
```bash
APP=crapi task apps:down
APP=crapi task apps:up
```
Or for a full cert-manager re-sync: `task reset`.

## Switching NodePort ↔ ClusterIP per app

By default every app is exposed as a **NodePort** service, reachable at
`LAB_HOST_IP:<port>`. To put an app behind an in-cluster ingress instead
(BIG-IP CIS, NGINX Ingress), switch it to **ClusterIP** so it's only
reachable inside the cluster:

```bash
# In lab.env — apps listed here become ClusterIP, the rest stay NodePort
CLUSTERIP_APPS="dvga vampi"
# CLUSTERIP_APPS=""           # default: everything NodePort
```

Then restart the affected apps:
```bash
APP=dvga task apps:down && APP=dvga task apps:up
```

ClusterIP apps are **not** reachable on `LAB_HOST_IP`. To reach one for
testing, port-forward it:
```bash
kubectl port-forward -n dvga svc/dvga 8082:5013
# then browse http://localhost:8082
```

`task test`, `task health`, and `task apps:status` all detect ClusterIP
apps and skip the host-reachability checks for them automatically.

This works for crAPI too (its Helm chart's front-end service is switched
via `--set crapiWeb.service.type=ClusterIP` under the hood).

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
