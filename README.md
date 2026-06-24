# cni-net-lab

A self-contained, **GitOps-driven** Kubernetes lab built on [k3d](https://k3d.io).
It runs a set of intentionally-vulnerable demo apps (crAPI, Juice Shop, DVGA,
VAmPI) on a cluster with **no ingress controller, no LoadBalancer, and a CNI of
your choice** — purpose-built for CNI comparison (Calico vs Cilium), network-policy
testing, and as a stable backend for ingress / load-balancer integration work
done in a **separate** project.

The cluster's desired state lives in Git. [Argo CD](https://argo-cd.readthedocs.io)
reconciles it. You change YAML and push — you don't `kubectl apply` apps by hand.

> ⚠️ The demo apps are **deliberately vulnerable**. Run this on an isolated lab
> network, never on anything reachable from the internet.

---

## What you get

- A **k3d** cluster with no Klipper ServiceLB, no Traefik, and no default CNI.
- Your choice of **Cilium** (default) or **Calico**, installed post-cluster.
- **Argo CD** managing every app via an app-of-apps, reconciled from Git.
- **Self-hosted Gitea** (optional) as Argo's source of truth — no GitHub
  dependency, fully air-gappable. (GitHub also works.)
- A host-side **Docker registry** for fast, offline image pulls.
- One-switch **exposure profiles** (NodePort/ClusterIP × HTTP/HTTPS) and an
  optional **routing layer** that emits `Ingress` / F5 `VirtualServer` /
  Gateway API `HTTPRoute` manifests for an externally-managed controller.

---

## Architecture at a glance

```
   HOST (long-lived)        ┌─ registry ──┐  ┌─ local CA ─┐  ┌─ Gitea (Git repo) ─┐
                            └──────┬──────┘  └─────┬──────┘  └─────────┬──────────┘
                                   │ images        │ certs             │ Argo clones
   ─────────────────────────────────────────────────────────────────────────────
   BOOTSTRAP (task up)   ca:init → k3d cluster → CNI → cert-manager → Argo CD
   ─────────────────────────────────────────────────────────────────────────────
   GITOPS (Argo CD)      root app ─▶ app-of-apps ─▶ crapi · juiceshop · dvga · vampi
                                                  └▶ exposure (optional routing)
```

Everything above the lines is bootstrapped **imperatively** (it must exist before
GitOps can run). Everything below is **declarative** — Argo CD watches Git and
makes the cluster match. Full detail in
[docs/architecture.md](docs/architecture.md).

---

## Prerequisites

Ubuntu 22.04 / 24.04. `sudo bash scripts/install-prereqs.sh` (or `task install`)
installs everything:

| Tool | Purpose |
|---|---|
| Docker CE | Runs k3d nodes, the registry, and Gitea |
| kubectl | Cluster management |
| k3d v5.7.4 | Kubernetes-in-Docker |
| Helm | CNI, cert-manager, Argo CD, app charts |
| Task | Taskfile automation |
| jq, python3, apache2-utils, openssl, curl | Script dependencies |

Run `task check` any time to verify tooling and that `lab.env` / `lab.secrets`
exist.

---

## Quick start

```bash
# 1. Install prerequisites (once; log out/in afterwards for the docker group)
task install

# 2. Configure — set LAB_HOST_IP (your VM's IP) at minimum
cp lab.env.example lab.env
cp lab.secrets.example lab.secrets        # optional credentials

# 3. Start the host registry (survives cluster rebuilds)
task registry:setup
task registry:cache                        # optional: pre-pull images

# 4. (Recommended) self-hosted Git as Argo's source
task gitea:setup                           # creates the repo, wires lab.env for you

# 5. Bring the lab up, then verify
task up
task health
task test
```

`task up` is **idempotent** — re-run it any time to converge. To rebuild the
cluster from scratch, use `task reset`.

Cluster-only (pure network testing, no apps):

```bash
task cluster:only
```

---

## App endpoints

Defaults (NodePort on `LAB_HOST_IP`; a ClusterIP app is reachable only via
port-forward):

| App | HTTP | HTTPS (when its profile enables TLS) |
|---|---|---|
| crAPI | `http://LAB_HOST_IP:30080` | `https://LAB_HOST_IP:30443` |
| Juice Shop | `http://LAB_HOST_IP:30081` | `https://LAB_HOST_IP:30444` |
| DVGA | `http://LAB_HOST_IP:30082` | `https://LAB_HOST_IP:30445` |
| VAmPI | `http://LAB_HOST_IP:30083` | `https://LAB_HOST_IP:30446` |
| **Argo CD UI** | `http://LAB_HOST_IP:30090` | — (insecure HTTP, lab only) |

Argo CD login: `admin` / `task argocd:password`. Per-app ports live in
`argocd/lab-apps/values.yaml` (not `lab.env`) and can change via GitOps as long
as they stay within `NODEPORT_RANGES`.

---

## The GitOps loop

The core day-2 workflow — never `kubectl apply` apps directly:

```bash
# edit YAML (an app chart, lab-apps values, or a profile) → commit → publish → reconcile
git commit -am "tweak exposure"
task gitea:push          # push to Argo's source of truth (Gitea)
task argocd:sync         # nudge Argo (it auto-refreshes anyway)
task argocd:apps         # watch SYNC / HEALTH
```

**Switch the whole lab's exposure** with one line in `lab.env`:

```bash
LAB_PROFILE=clusterip-http      # mixed | nodeport-http | nodeport-https | clusterip-http | clusterip-https
# then: task argocd:bootstrap && task argocd:wait
```

See [docs/operations.md](docs/operations.md) for changing a single app, adding
/removing apps, and the routing layer.

---

## Ingress / load balancer — out of scope (by design)

This lab **does not install or run** an ingress controller or load balancer. It
*can* emit the routing manifests for one:

```bash
INGRESS_KIND=nginx       # none | nginx | cis | gateway
# then: task argocd:bootstrap && task argocd:wait
```

…which renders an `Ingress` / F5 `VirtualServer` / Gateway API `HTTPRoute` per
app, pointing at the existing Services. **Installing and operating** NGINX
Ingress, F5 BIG-IP CIS, or NGINX Gateway Fabric is the job of a **separate
project** — those objects only carry traffic once that controller is present.
Details in
[docs/architecture.md](docs/architecture.md#the-exposure-layer-ingress_kind).

---

## Configuration

`lab.env` holds **host/infra** settings only (IP, CNI, NodePort ranges, profile
and routing selectors, registry/Gitea/Argo ports). **What deploys and how it's
exposed lives entirely in Git** (`argocd/lab-apps/`), and `task health`/`test`
read the live cluster — so there are no app lists to keep in sync. Credentials go
in `lab.secrets` (gitignored). Full tables in
[docs/reference.md](docs/reference.md).

---

## Documentation

| Doc | What's in it |
|---|---|
| [docs/architecture.md](docs/architecture.md) | How it all fits: bootstrap vs GitOps, app-of-apps, Gitea source, profiles, exposure layer, NodePort ranges, the vendored crAPI chart. |
| [docs/operations.md](docs/operations.md) | Day-2 runbook: lifecycle, the GitOps loop, switching profiles/exposure, adding apps, host services, TLS trust. |
| [docs/reference.md](docs/reference.md) | Lookup tables: `lab.env`/`lab.secrets`, tasks, ports, profiles, `INGRESS_KIND`, app inventory, repo layout. |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Real failure modes and fixes. |

---

## Repository layout

```
apps/        per-app Helm charts (+ vendored crAPI chart)
argocd/      root app-of-apps, lab-apps chart + profiles, exposure layer
scripts/     bootstrap, lifecycle, registry/Gitea helpers, verification
docs/        architecture · operations · reference · troubleshooting
Taskfile.yaml · lab.env.example · lab.secrets.example
```
