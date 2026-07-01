# Troubleshooting

Common failure modes, each as **symptom → cause → fix**. For how the pieces fit
together see [architecture.md](architecture.md).

First stop for almost anything:

```bash
task argocd:apps                 # per-Application SYNC / HEALTH
kubectl get pods -A | grep -v -E 'Running|Completed'
task cni:status
```

---

## Root app stuck `Sync = Unknown` (`authentication required`)

**Symptom.** The Argo `Application` conditions show:

```
ComparisonError: Failed to load target state: failed to generate manifest for
source 1 of 1: rpc error: code = Unknown desc = authentication required
```

and no child apps are ever created.

**Cause.** Argo CD's repo-server can't clone the source repo — almost always
because `ARGOCD_REPO_URL` resolved to a **private** Git remote (e.g. private
GitHub) with no credential. This commonly happens when `lab.env` is recreated
blank and the bootstrap falls back to the git `origin`.

**Fix — preferred: use the public Gitea source.**

```bash
# in lab.env
ARGOCD_REPO_URL=http://host.k3d.internal:3000/giteaadmin/k3d-app-delivery-fabric.git
ARGOCD_TARGET_REVISION=<your branch>
```
```bash
task argocd:bootstrap && task argocd:wait
```

(With a running Gitea, leaving `ARGOCD_REPO_URL` blank also works — the bootstrap
auto-detects Gitea. `task gitea:setup` writes these for you.)

**Fix — alternative: give Argo a credential for the private repo.** Put a
read-scoped token in `lab.secrets`, then re-bootstrap:

```bash
# lab.secrets
ARGOCD_REPO_USERNAME=git
ARGOCD_REPO_PASSWORD=ghp_your_token
```

**Verify the repo-server can reach the source:**

```bash
kubectl -n argocd exec deploy/argocd-repo-server -- \
  git ls-remote http://host.k3d.internal:3000/giteaadmin/k3d-app-delivery-fabric.git | head
```

Refs printed → reachable. If it hangs, see
[repo-server can't reach Gitea](#repo-server-cant-reach-gitea).

---

## Bootstrap banner shows the wrong repo

**Symptom.** `task argocd:bootstrap` prints `Repo: https://github.com/...` when
you expected Gitea (or vice-versa).

**Cause.** `ARGOCD_REPO_URL` is empty in `lab.env`, so the bootstrap fell back
through the [resolution order](architecture.md#repo-url-resolution-order). A
blank value falls back to a running Gitea, then to git `origin`.

**Fix.** Set `ARGOCD_REPO_URL` explicitly in `lab.env` and re-bootstrap. Always
**read the banner** — `Repo:` shows exactly what Argo will clone.

---

## An app stuck `OutOfSync / Missing` — `provided port is already allocated`

**Symptom.** One app won't sync; its operation message says e.g.:

```
Service "crapi-web" is invalid: spec.ports[1].nodePort: Invalid value: 30443:
provided port is already allocated
```

**Cause.** Two Services want the same host NodePort. (Argo CD's own server
defaults its HTTPS NodePort to `30443`, which collides with crAPI — the lab pins
it to `30091` to avoid this, but a stale/leftover Service can also hold a port.)

**Diagnose — find the holder:**

```bash
kubectl get svc -A | grep 30443
```

**Fix.**

- If a **leftover/duplicate** Service holds it, delete it and let Argo recreate:
  ```bash
  kubectl -n <ns> delete svc <name> --force --grace-period=0
  kubectl -n argocd annotate app <app> argocd.argoproj.io/refresh=hard --overwrite
  ```
- If it's **Argo's own** `argocd-server` on `30443`, re-install picks up the
  pinned `30091`; or patch the running Service:
  ```bash
  kubectl -n argocd patch svc argocd-server -p '{"spec":{"ports":[{"port":443,"nodePort":30091}]}}'
  ```

A `refresh=hard` only re-*compares*; if auto-sync is in backoff, force a sync
from the UI (**SYNC**) or:

```bash
kubectl -n argocd patch app <app> --type merge \
  -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"prune":true,"syncStrategy":{"apply":{}}}}}'
```

---

## crAPI stuck `Synced / Progressing` forever

**Symptom.** Every crAPI pod is `Running`, but the Application never reaches
`Healthy`; the not-healthy resource is `Service/mailhog-web-ingress`
(`Progressing`).

**Cause.** A Service of type `LoadBalancer` never gets an external IP in this
cluster (k3s ServiceLB is disabled), so Argo reports it `Progressing` forever.

**Fix (already in the lab).** The lab patches the crAPI chart so
`mailhog-web-ingress` (and `crapi-web`) are non-LoadBalancer; MailHog is reached
via `task crapi:mail`. If you re-vendored the chart and lost the patch, re-apply
it — see [stale crAPI patch](#crapi-chart-update-lost-the-lab-patch). More
generally, any `LoadBalancer` Service will hang `Progressing` here; use NodePort
or ClusterIP instead.

---

## `exposure` app stuck `Progressing`

**Symptom.** With `INGRESS_KIND != none`, the `exposure` Application is `Synced`
but stays `Progressing`.

**Cause.** This is **expected** when no matching controller is present. The lab
only *emits* the routing objects (`Ingress`/`VirtualServer`/`HTTPRoute`); Argo
judges their health by whether a controller has accepted/addressed them, and the
controller is run by a **separate project**.

**Fix / options.**

- Leave it — the objects are correct; they go `Healthy` once a controller (run
  elsewhere) programs them.
- Or set `INGRESS_KIND=none` and re-bootstrap to prune the layer (and let
  `task argocd:wait`/`task up` pass).

For `cis`/`gateway`, if Argo reports `no matches for kind VirtualServer/HTTPRoute`,
the controller's **CRDs aren't installed** — that's the separate project's job.

---

## `task up` fails: cluster already exists

**Symptom.**

```
FATA Failed to create cluster 'k3d-app-delivery-fabric' because a cluster with that name already exists
```

**Cause.** You ran `task cluster:only` (or `task cluster`) and then `task up`,
which tries to create the cluster again.

**Fix.** `task up` is idempotent and now **skips** creation when the cluster
exists, converging the rest. If you hit this on an older checkout, either run the
post-cluster steps directly, or `task reset` to rebuild cleanly. To rebuild from
scratch, always use `task reset` (or `task down` first).

---

## repo-server can't reach Gitea

**Symptom.** The root app stays `Unknown`, and the in-cluster `git ls-remote`
against the Gitea URL hangs or errors (but Gitea is up on the host).

**Cause.** Argo's repo-server is a **pod** and reaches Gitea via the cluster
gateway alias `host.k3d.internal:3000`. That path only works if Gitea is
published on all interfaces (it is, by default) and the alias resolves.

**Fix.** Use the host-IP form of the URL instead and re-bootstrap:

```bash
# lab.env
ARGOCD_REPO_URL=http://<LAB_HOST_IP>:3000/giteaadmin/k3d-app-delivery-fabric.git
```
```bash
task argocd:bootstrap
```

Confirm Gitea has your latest commit with `task gitea:status` (and `task
gitea:push` if not).

---

## crAPI chart-update lost the lab patch

**Symptom.** After `task crapi:chart:update`, the script warns:

```
lab-chart.patch did NOT apply — upstream changed these files
```

**Cause.** Re-vendoring overwrites `apps/crapi/chart/`; the lab re-applies
`apps/crapi/lab-chart.patch` automatically, but upstream changed the two Service
templates enough that the patch no longer fits.

**Fix.** Re-add the `type` overrides by hand in
`apps/crapi/chart/templates/web/ingress.yaml` and
`apps/crapi/chart/templates/mailhog/ingress.yaml` (make `type` come from a value,
default `LoadBalancer`; omit `nodePort` when `ClusterIP`), then regenerate the
patch (the script prints the exact `git diff … > apps/crapi/lab-chart.patch`
command).

---

## `task health` / `task test` report nothing

**Symptom.** No apps listed.

**Cause.** `health`/`test` derive the app list from Argo Applications
(`kubectl get applications -n argocd`). If Argo isn't installed/bootstrapped yet,
there's nothing to enumerate.

**Fix.** Finish the bring-up (`task argocd:bootstrap && task argocd:wait`), or run
`task up`. For a cluster with no apps by design, use `task cluster:only` (which
skips the app checks).

---

## Apps pull images slowly / from the internet

**Symptom.** `create-cluster.sh` warns `Registry not running — pods will pull
images from the public internet`, and first sync is slow.

**Cause.** The host registry isn't running or isn't primed.

**Fix.**

```bash
task registry:setup
task registry:cache     # pre-pull all lab images into the local registry
```

k3d mirrors `host.k3d.internal:5000`, so cached images are used automatically.

---

## ipvlan mode — nodes on the LAN for an external load balancer

Set `LAB_NET_MODE=ipvlan` in `lab.env` to put the k3d nodes **directly on your
LAN** (from `LAB_NET_RANGE`) instead of a private Docker bridge, so an external
device (e.g. F5 BIG-IP) reaches node NodePorts at L2 with no host route. Applying
it requires a rebuild:

```bash
task down        # or task reset
task up
kubectl get nodes -o wide     # INTERNAL-IP should now be on LAB_NET_SUBNET
```

**How it works.** `create-cluster.sh` pre-creates an ipvlan-L2 Docker network on
the NIC that holds `LAB_HOST_IP` (override with `LAB_NET_PARENT`), runs k3d with
`--network … --no-lb`, and adds a **host shim** interface (`k3dshim0`,
`LAB_NET_SHIM_IP`) so the host and node→host services (registry, Gitea) can reach
the otherwise-isolated nodes. `task config` shows the resolved Gitea/registry
address (the shim IP under ipvlan).

**ipvlan (not macvlan)** so it needs **no promiscuous mode / MAC-spoofing** on the
hypervisor. On Proxmox/KVM, still make sure the VM NIC's firewall **IP/MAC filter
is off**, or the container IPs are dropped.

**The shim is not reboot-persistent.** Re-running `task up` recreates it, or make
it permanent (example for the `172.16.20.0/24` lab; adjust to your values):

```bash
# /etc/systemd/system/k3dshim0.service
[Unit]
After=network-online.target docker.service
Wants=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/ip link add k3dshim0 link eth0 type ipvlan mode l2
ExecStart=/sbin/ip addr add 172.16.20.250/32 dev k3dshim0
ExecStart=/sbin/ip link set k3dshim0 up
ExecStart=/sbin/ip route replace 172.16.20.192/27 dev k3dshim0
ExecStop=/sbin/ip link del k3dshim0
[Install]
WantedBy=multi-user.target
```

**BIG-IP pool members go green with no route.** CIS now advertises the nodes'
LAN IPs (`172.16.20.x:NodePort`), directly reachable from the BIG-IP self-IP on
the same subnet. The static route from the bridge workaround is no longer needed —
delete it.

**Symptom: `kubectl` can't reach the API after switching.** On ipvlan the API
port isn't published to the host; `create-cluster.sh` rewrites the kubeconfig to
the server node's LAN IP (reached via the shim). If it still fails, confirm the
shim is up (`ip addr show k3dshim0`) and the route exists
(`ip route get <server-LAN-IP>`).

**Revert to the default.** Set `LAB_NET_MODE=bridge`, `task reset`. The leftover
ipvlan network and shim are harmless, but you can remove them:
`docker network rm <cluster>-lan` and `sudo ip link del k3dshim0`.
