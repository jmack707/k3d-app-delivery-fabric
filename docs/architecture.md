# Architecture

This document explains how **cni-net-lab** is put together and the reasoning
behind the main design decisions. For commands see
[operations.md](operations.md); for lookup tables see
[reference.md](reference.md).

---

## Design goals

- **A reproducible Kubernetes lab** for CNI / network-policy testing and as a
  stable home for a set of intentionally-vulnerable demo apps.
- **GitOps first.** The desired state of every workload lives in Git; Argo CD
  continuously reconciles the cluster to match it. You change YAML and push —
  you don't `kubectl apply` or `helm install` apps by hand.
- **A clean boundary** between the *imperative bootstrap* (things that must exist
  before GitOps can run) and the *declarative workloads* (everything Argo owns).
- **Self-contained / air-gappable.** A local image registry and an optional
  self-hosted Git server (Gitea) let the lab run with no dependency on GitHub or
  the public internet.
- **Config lives in Git, not in your head.** `lab.env` holds only host/infra
  settings; what deploys and how it's exposed is entirely in the Git repo.

### Non-goals (scope boundary)

- **The lab does not run an ingress controller or load balancer.** It can
  *emit* the routing manifests (an `Ingress`, an F5 `VirtualServer`, or a Gateway
  API `HTTPRoute`) that point at the apps, but installing and operating NGINX
  Ingress, F5 BIG-IP CIS, or NGINX Gateway Fabric is the responsibility of a
  **separate project**. See [The exposure layer](#the-exposure-layer-ingress_kind).
- It is not hardened or production-grade — the apps are deliberately vulnerable.

---

## The two halves: bootstrap vs GitOps

```
            HOST (long-lived, independent of the cluster)
            ┌───────────────────────────────────────────────┐
            │  Docker registry      local CA       Gitea     │
            │  (image cache)        (root_ca.*)    (Git repo) │
            └───────┬───────────────────┬─────────────┬──────┘
                    │ image pulls        │ TLS certs   │ git clone (Argo)
                    ▼                    ▼             ▼
   IMPERATIVE BOOTSTRAP  ───────────────────────────────────────────────┐
   (task up, idempotent)                                                 │
     ca:init → cluster(k3d) → CNI(cilium/calico) → cert-manager          │
                                          → Argo CD → register root app  │
   ──────────────────────────────────────────────────────────────────── ┘
                    │ from here on, Git is the source of truth
                    ▼
   GITOPS (Argo CD reconciles continuously)
     root app ─▶ argocd/lab-apps ─▶ AppProject
                                  ├▶ Application: crapi      ─▶ apps/crapi/chart
                                  ├▶ Application: juiceshop  ─▶ apps/juiceshop/chart
                                  ├▶ Application: dvga       ─▶ apps/dvga/chart
                                  ├▶ Application: vampi      ─▶ apps/vampi/chart
                                  └▶ Application: exposure   ─▶ argocd/exposure   (if INGRESS_KIND != none)
```

Everything **above** the dividing line is run once, imperatively, by `task up`.
Everything **below** it is declarative: Argo CD watches the Git repo and makes
the cluster match. The split matters because some things (the cluster itself,
the CNI, cert-manager, Argo CD) have to exist *before* Argo can manage anything —
you can't GitOps the thing that runs GitOps.

---

## Component lifecycle

Three pieces are intentionally **independent of the cluster** and survive
`task down` / `task reset`:

| Component | What it is | Lifecycle |
|---|---|---|
| **Registry** | Docker registry v2 in a host container | Started once (`task registry:setup`); long-lived |
| **Local CA** | `root_ca.crt` / `root_ca.key` on disk | Created once (`task ca:init`); reused |
| **Gitea** | Self-hosted Git in a host container | Optional (`task gitea:setup`); long-lived |

The **cluster** is ephemeral — destroy and rebuild it freely. Because the apps'
desired state is in Git (Gitea or GitHub) and images are cached in the registry,
a rebuilt cluster reconverges to exactly the same state.

---

## Imperative bootstrap (`task up`)

`task up` runs this chain; each step is idempotent, so `task up` is safe to
re-run (it converges rather than failing):

1. **`ca:init`** — create the local root CA if absent.
2. **`cluster`** — create the k3d cluster: 1 server + N agents, **no** Klipper
   ServiceLB, **no** Traefik, **no** default CNI (flannel disabled). Publishes
   the NodePort ranges (see [below](#nodeport-ranges)). Skips creation if the
   cluster already exists.
3. **`cni:install`** — install Cilium (default) or Calico via Helm.
4. **`pre-deploy`** — install cert-manager, import the local CA as a TLS secret,
   and apply a `ClusterIssuer` (`local-ca`) that signs lab certificates.
5. **`argocd:install`** — install Argo CD via Helm; expose its UI as a NodePort,
   run it in insecure (HTTP) mode, optionally set the admin password.
6. **`argocd:bootstrap`** — resolve the repo URL/revision and apply the **root
   Application**.
7. **`argocd:wait`** — block until every Application is `Synced`/`Healthy`.
8. **`health`** — verify nodes, CNI, app rollouts, and NodePort reachability.

Why cert-manager and Argo CD are bootstrapped imperatively rather than via
GitOps: cert-manager's CRDs and the CA secret (which holds a private key, so it's
gitignored) need to exist before any app that requests a certificate syncs; and
Argo CD obviously can't deploy itself. Keeping them in the bootstrap is the
standard "GitOps needs a seed" pattern.

---

## GitOps: the app-of-apps

The entrypoint is a single **root Application** (`argocd/root-app.yaml`,
rendered with your repo URL/revision at bootstrap). It points at the
**`argocd/lab-apps`** Helm chart, which renders:

- a **`cni-net-lab` AppProject** (permissive — it's a lab), and
- **one Argo `Application` per app**, plus
- the **`exposure` Application** when `INGRESS_KIND != none`.

```
root-app.yaml  (applied by task argocd:bootstrap)
   │  source: argocd/lab-apps  (Helm)
   │  params: global.repoURL / targetRevision / labHostIp / labDomain
   │          global.ingressKind, + valueFiles: profiles/<LAB_PROFILE>.yaml
   ▼
argocd/lab-apps/templates/applications.yaml
   ├─ AppProject  cni-net-lab
   ├─ Application crapi      → apps/crapi/chart      (+ apps/crapi/values.yaml via $values)
   ├─ Application juiceshop  → apps/juiceshop/chart  (helm params: serviceType, tls, ports, host)
   ├─ Application dvga       → apps/dvga/chart
   ├─ Application vampi      → apps/vampi/chart
   └─ Application exposure   → argocd/exposure       (only if INGRESS_KIND != none)
```

Each child Application has `automated` sync with `prune: true` and `selfHeal:
true`, `CreateNamespace=true`, and `ServerSideApply=true`. So:

- removing an app from Git **prunes** it from the cluster,
- manual drift is **self-healed** back to Git,
- namespaces are created automatically.

**Why app-of-apps** rather than one giant Application: each app reconciles,
reports health, and can be synced independently, and you add/remove an app by
toggling one `enabled:` flag in `argocd/lab-apps/values.yaml`.

### The apps

| App | What it is | Chart | Notes |
|---|---|---|---|
| **crAPI** | OWASP *Completely Ridiculous API* | vendored upstream OWASP chart | multi-service (postgres, mongo, identity, community, workshop, web, mailhog…); always serves HTTP **and** HTTPS |
| **Juice Shop** | OWASP Juice Shop | per-app chart (`apps/juiceshop/chart`) | TLS via an nginx sidecar when enabled |
| **DVGA** | Damn Vulnerable GraphQL App | per-app chart | TLS via nginx sidecar |
| **VAmPI** | Vulnerable API | per-app chart | extra smoke-test path `/ui/` |

The three non-crAPI apps share an almost identical small Helm chart
(Deployment + Service + optional TLS sidecar + cert-manager `Certificate`),
parameterised by values. crAPI uses the upstream OWASP chart, *vendored* into
the repo (see [crAPI](#crapi-vendored-chart--patch)).

---

## Source of truth: Gitea (or GitHub)

Argo CD's repo-server clones a Git repo to read manifests. That repo is the
**source of truth**. It can be any Git host; the lab supports two patterns:

- **Self-hosted Gitea** (recommended for a self-contained lab) — a host
  container, created public, reached from inside the cluster via
  `host.k3d.internal`. No credentials, no GitHub dependency, air-gappable.
- **GitHub** (or any remote `origin`) — works too, but a **private** repo needs
  a read credential (a PAT in `lab.secrets`), or Argo can't clone it.

### Repo-URL resolution order

`argocd-bootstrap.sh` picks the repo in this order:

1. an **explicit** `ARGOCD_REPO_URL` in `lab.env` (always wins), else
2. a **running Gitea** with the lab repo (auto-detected), else
3. the git **`origin`** remote.

This ordering means that even if `lab.env` is recreated blank, the bootstrap
prefers your self-hosted Gitea over silently falling back to a (possibly
private) `origin`. As an extra belt-and-suspenders, `task gitea:setup` also
**writes** `ARGOCD_REPO_URL` / `ARGOCD_TARGET_REVISION` into `lab.env` (unless
you've pinned a non-Gitea value, which it leaves alone).

### Networking detail

Gitea is published on the host (all interfaces). Argo's repo-server is a **pod**,
so it reaches Gitea over the cluster gateway alias `host.k3d.internal:3000` —
which is why Gitea binds `0.0.0.0` rather than just loopback. If
`host.k3d.internal` can't be reached in a given environment, the lab also
accepts the `LAB_HOST_IP:3000` form of the URL.

---

## Exposure: per-app Service + the routing layer

### Apps always have a Service

Every app deploys a Kubernetes **Service** — the stable VIP + EndpointSlices
that any ingress/LB targets. The Service is either:

- **NodePort** — reachable on `LAB_HOST_IP:<port>` from outside the cluster, or
- **ClusterIP** — only reachable inside the cluster (use this when the app will
  sit behind an ingress, or for port-forward-only access).

The Service *type* and whether TLS is on are controlled per app by the active
**profile** (below). Apps stay on whichever type you choose — an ingress
controller routes to a Service's endpoints regardless of its type, so you never
have to change the app to put something in front of it.

### The exposure layer (`INGRESS_KIND`)

North-south routing is a **separate Argo Application** (`argocd/exposure`),
deliberately decoupled from the app charts so you can iterate on routing without
touching the workloads (and without re-patching the vendored crAPI chart). One
switch selects which flavour of routing object it renders:

| `INGRESS_KIND` | Renders (per app) | Consumed by (managed elsewhere) |
|---|---|---|
| `none` (default) | nothing | — |
| `nginx` | `networking.k8s.io/v1` **Ingress** | an NGINX ingress controller |
| `cis` | F5 **VirtualServer** (`cis.f5.com/v1`) | F5 BIG-IP CIS + a BIG-IP |
| `gateway` | a **Gateway** + per-app **HTTPRoute** | a Gateway API controller (e.g. NGINX Gateway Fabric) |

> **The lab only produces these manifests.** The controller that consumes them is
> **out of scope** and is expected to be installed and managed by a separate
> project. With `INGRESS_KIND != none` the routing objects are applied and tracked
> by Argo, but they only carry traffic once a matching controller exists. (For
> `cis`/`gateway`, the controller's CRDs must be present or Argo reports
> `no matches for kind …`.)

Per-controller settings (ingress class, BIG-IP virtual-server address / IPAM
label, GatewayClass, hostnames) live in `argocd/exposure/values.yaml`.

---

## Profiles (`LAB_PROFILE`)

A **profile** is a committed values file (`argocd/lab-apps/profiles/<name>.yaml`)
that sets `serviceType` and `tls` for every app at once. The root Application
layers the selected profile *over* the base `argocd/lab-apps/values.yaml`:

```
argocd/lab-apps/values.yaml         (base: namespaces, chart paths, ports, defaults)
            +  profiles/<LAB_PROFILE>.yaml   (overrides: per-app serviceType / tls)
            =  the rendered child Applications
```

| Profile | Service type | Scheme | On host? |
|---|---|---|---|
| `mixed` (default) | per-app | per-app | per-app (the lab's hand-tuned mix) |
| `nodeport-http` | NodePort | HTTP | yes |
| `nodeport-https` | NodePort | HTTPS | yes |
| `clusterip-http` | ClusterIP | HTTP | no (ingress-prep) |
| `clusterip-https` | ClusterIP | HTTPS | no (ingress-prep) |

Switching the whole lab between scenarios is one line in `lab.env` plus a
re-bootstrap. crAPI honours `serviceType` too, but always serves both HTTP and
HTTPS from its upstream chart.

---

## NodePort ranges

k3d publishes host ports **at cluster-create time** — before Argo or Gitea
exist — so the set of published ports is genuine "day -1" infrastructure.
Rather than binding each app's exact ports (which couples the cluster to the app
list and forces a rebuild whenever a port changes), the lab publishes **bands**:

```
NODEPORT_RANGES="30080-30099 30440-30459"     # in lab.env
```

Any app NodePort that falls inside a band is reachable on `LAB_HOST_IP` with **no
cluster rebuild**. The defaults cover app HTTP (`30080-30083`), Argo CD
(`30090`), and app HTTPS (`30443-30446`), with headroom. The per-app port
*assignments* live in Git (`argocd/lab-apps/values.yaml`), so changing an app's
port is a GitOps edit, not a `task reset`. Only changing the ranges themselves
(or `ARGOCD_HTTP_PORT`) requires a rebuild.

---

## crAPI: vendored chart + patch

crAPI is deployed from the **upstream OWASP Helm chart**, vendored into
`apps/crapi/chart/`. Vendoring (rather than pulling at deploy time) makes runs
reproducible and air-gappable, and means a bad upstream change can't silently
break the lab.

The lab needs two small edits to that chart — making the `crapi-web` and
`mailhog-web-ingress` Service **types** configurable (upstream hardcodes
`LoadBalancer`, which never gets an address in this no-ServiceLB cluster and
would leave Argo stuck `Progressing`). Those edits are captured as
`apps/crapi/lab-chart.patch`. When you refresh the chart
(`task crapi:chart:update`), the script re-applies the patch automatically and
**warns loudly** if upstream drifted enough that it no longer applies — so the
customisation can never be silently lost.

---

## Verification reads the live cluster

`task health` and `task test` discover what to check from the **cluster**, not
from `lab.env`:

- the **app list** comes from `kubectl get applications` (the Argo Applications),
- each app's **Service type** and **NodePorts** come from the live Service.

So there is no app list or per-app exposure to keep in sync in `lab.env`, and the
checks test *what was actually deployed* — they can't pass against stale intent.
(Drift between Git and the cluster is Argo's `OutOfSync` to report, which is a
separate concern from "is it reachable and healthy.")
