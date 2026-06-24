# Operations

Day-2 runbook. For the design behind these commands see
[architecture.md](architecture.md); for full lookup tables see
[reference.md](reference.md); for fixes see
[troubleshooting.md](troubleshooting.md).

---

## First-time setup

```bash
# 1. Install prerequisites (once, needs sudo). Log out/in afterwards for the docker group.
task install            # or: sudo bash scripts/install-prereqs.sh

# 2. Configure
cp lab.env.example lab.env          # set LAB_HOST_IP at minimum
cp lab.secrets.example lab.secrets  # optional credentials

# 3. Verify tooling
task check

# 4. Start the host-side registry (once — it survives cluster rebuilds)
task registry:setup
task registry:cache     # optional: pre-pull all images while you have internet

# 5. (Recommended) self-hosted Git as Argo's source
task gitea:setup        # starts Gitea, creates the repo, writes ARGOCD_REPO_URL into lab.env

# 6. Bring the lab up
task up

# 7. Verify
task health
task test
```

`LAB_HOST_IP` is the one value you must set — your VM's primary IP
(`ip route get 1.1.1.1 | grep -oP 'src \K[\d.]+'`).

---

## Lifecycle

```bash
task up             # full bring-up (idempotent — safe to re-run; it converges)
task down           # delete the cluster (registry, CA, and Gitea are preserved)
task reset          # down + up (rebuild the cluster from scratch)
task cluster:only   # cluster + CNI only, no apps (pure network testing)
task cluster:reset  # rebuild cluster + CNI only
```

Because `task up` is idempotent, you can re-run it to reconcile after changing
infra settings; it skips cluster creation if the cluster already exists. To
actually rebuild the cluster (e.g. after changing `CNI`, `LAB_AGENTS`, or
`NODEPORT_RANGES`), use `task reset`.

What survives a `down`/`reset`: the **registry**, the **local CA**, and the
**Gitea** container — all host-side and independent of the cluster. The apps
themselves come back automatically because Argo re-syncs them from Git.

---

## The GitOps loop (the core day-2 workflow)

You never `kubectl apply` or `helm install` apps directly. You edit YAML, push to
Argo's source repo, and let Argo reconcile:

```bash
# 1. edit manifests/values (e.g. an app chart, lab-apps values, or a profile)
vim argocd/lab-apps/profiles/mixed.yaml

# 2. commit
git commit -am "tweak exposure"

# 3. publish to Argo's source of truth
task gitea:push          # push the current branch to Gitea
#   (if you also use GitHub: git push  — keeps the remotes in sync)

# 4. let Argo reconcile (it auto-refreshes; this forces it now)
task argocd:sync

# 5. watch
task argocd:apps         # SYNC STATUS / HEALTH STATUS per Application
```

`task argocd:wait` blocks until everything is `Synced`/`Healthy` if you want a
gate (it's part of `task up`).

---

## Switching the exposure profile (all apps at once)

Pick a scenario with one switch, then re-point Argo:

```bash
# lab.env
LAB_PROFILE=clusterip-http      # mixed | nodeport-http | nodeport-https | clusterip-http | clusterip-https
```
```bash
task argocd:bootstrap && task argocd:wait
```

The profile is a committed file (`argocd/lab-apps/profiles/<name>.yaml`) that
Argo layers over the base values. See the
[profile matrix](reference.md#exposure-profiles).

---

## Changing one app's exposure

Profiles set every app at once; to change a single app, edit its entry in the
**active profile** (the one `LAB_PROFILE` selects — its values win over the
base). Example: put Juice Shop on ClusterIP while leaving the rest alone:

```bash
# argocd/lab-apps/profiles/mixed.yaml
apps:
  juiceshop:
    serviceType: ClusterIP     # was NodePort
    tls: true
```
```bash
git commit -am "juiceshop: ClusterIP"
task gitea:push
task argocd:sync
```

Argo updates the Service in place (dropping the NodePort) and frees those ports.
`task health`/`test` read the live cluster, so they'll correctly start skipping
the host probe for Juice Shop with no other edits.

A ClusterIP app isn't reachable on `LAB_HOST_IP`; reach it with a port-forward:

```bash
kubectl -n juice-shop port-forward svc/juice-shop 8081:3000   # http://localhost:8081
```

---

## Changing an app's port

Per-app NodePorts live in `argocd/lab-apps/values.yaml`
(`httpNodePort` / `httpsNodePort`). Edit, push, sync — **no cluster rebuild**, as
long as the new port stays inside `NODEPORT_RANGES`:

```yaml
# argocd/lab-apps/values.yaml
apps:
  dvga:
    httpNodePort: 30085      # must be within NODEPORT_RANGES
```

---

## Adding or removing an app

- **Disable an app:** set `enabled: false` for it in
  `argocd/lab-apps/values.yaml`, push, sync. Argo prunes it (namespace and all).
- **Re-enable:** set `enabled: true`, push, sync.
- **Add a brand-new app:** create `apps/<name>/chart` (copy one of the existing
  per-app charts), add an `apps.<name>` entry to `argocd/lab-apps/values.yaml`
  and the profile files, and add a row to the `APP_META` table in
  `scripts/lib.sh` (namespace, service name, display name, ready timeout, extra
  test paths) so `health`/`test` recognise it.

---

## North-south routing (`INGRESS_KIND`)

The lab can **emit** routing manifests for an ingress/LB controller, but it does
**not** install the controller — that's a separate project (see
[architecture.md](architecture.md#the-exposure-layer-ingress_kind)).

```bash
# lab.env
INGRESS_KIND=nginx       # none | nginx | cis | gateway
```
```bash
task argocd:bootstrap && task argocd:wait
```

An `exposure` Application appears and renders one routing object per app
(`Ingress` / `VirtualServer` / `HTTPRoute`) pointing at each app's Service.
Per-controller settings are in `argocd/exposure/values.yaml`. Set
`INGRESS_KIND=none` and re-bootstrap to prune the whole layer.

> Expect the `exposure` Application to sit at `Synced / Progressing` until a
> matching controller (run elsewhere) programs the routing objects. That's
> normal, not a failure — see
> [troubleshooting.md](troubleshooting.md#exposure-app-stuck-progressing).

---

## Argo CD access

```bash
task argocd:ui          # print the UI URL (http://LAB_HOST_IP:30090)
task argocd:password    # print the initial admin password
task argocd:apps        # list Applications + sync/health
task argocd:sync        # force a hard refresh/sync of all Applications
```

Set a fixed admin password by putting `ARGOCD_ADMIN_PASSWORD` in `lab.secrets`
(it's bcrypt-hashed at install time and re-applied on every `task argocd:install`).

---

## Switching CNI

```bash
# lab.env
CNI=calico       # or cilium
```
```bash
task reset       # CNI is installed at cluster-create time, so this needs a rebuild
```

---

## Host services (independent of the cluster)

### Registry

```bash
task registry:setup     # start (idempotent)
task registry:status    # state + image/tag count
task registry:cache     # pull all lab images and push to the local registry
task registry:ls        # list images/tags
task registry:flush     # delete all images (prompts)
task registry:stop      # stop (keeps data volume)
task registry:rm        # remove container + volume (irreversible)
```

k3d nodes are pre-configured to mirror `host.k3d.internal:5000`, so pulls resolve
to the local registry when an image is cached there.

### Gitea

```bash
task gitea:setup        # start + create repo + push current branch + wire lab.env
task gitea:status       # container state, API, repo URL
task gitea:push         # push the current branch after committing
task gitea:stop         # stop (keeps data volume)
task gitea:rm           # remove container + volume (irreversible)
```

The Gitea repo is created **public**, so Argo needs no credential to read it.
Admin user is `GITEA_ADMIN_USER` (default `giteaadmin`); set
`GITEA_ADMIN_PASSWORD` in `lab.secrets`. Web UI: `http://LAB_HOST_IP:3000`.

---

## crAPI maintenance

```bash
task crapi:mail              # port-forward MailHog UI to localhost:8025
task crapi:logs              # tail the identity service logs
task crapi:chart:update      # re-vendor the upstream chart (re-applies lab patch)
```

After `crapi:chart:update`, review the diff, then commit + `task gitea:push`.
If upstream changed the two Service templates the lab patches, the script warns
that `lab-chart.patch` didn't apply — re-add the `type` overrides by hand and
regenerate the patch (the script prints the one-liner).

---

## TLS trust

When an app has TLS enabled, cert-manager issues its certificate from the local
CA. Install `root_ca.crt` in your OS/browser to avoid warnings:

```bash
# Ubuntu / Debian
sudo cp root_ca.crt /usr/local/share/ca-certificates/k3d-app-delivery-fabric.crt
sudo update-ca-certificates

# macOS
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain root_ca.crt
```
