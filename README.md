# First Kubernetes Using Helm and ArgoCD

A hands-on lab that builds a small multi-node Kubernetes cluster with **kind**, installs **ArgoCD** using **Helm**, deploys an app the **GitOps** way, performs a **node drain**, and takes (and restores) an **etcd snapshot**.

## What you will learn

| Skill | Why it matters |
|---|---|
| kind multi-node cluster | Local, disposable cluster that behaves like a real one |
| Helm | The standard package manager for Kubernetes |
| ArgoCD / GitOps | Git becomes the source of truth; the cluster is kept in sync automatically |
| PodDisruptionBudget + node drain | Safe maintenance without downtime |
| etcd snapshot / restore | Backup and disaster recovery of the cluster's brain |

## Architecture

```
Docker host
 └── kind cluster "lab"
      ├── lab-control-plane  (API server, etcd, scheduler, controller-manager)
      ├── lab-worker
      ├── lab-worker2
      └── lab-worker3
           └── ArgoCD (installed by Helm) ──watches──> Git repo ──deploys──> guestbook app (3 replicas)
```

## Repository layout

```
.
├── README.md
├── kind-config.yaml            # cluster definition (1 control-plane, 3 workers)
├── argocd/guestbook-app.yaml   # ArgoCD Application (GitOps definition)
├── manifests/pdb.yaml          # PodDisruptionBudget for safe drains
├── scripts/etcd-snapshot.sh    # snapshot helper
├── scripts/cleanup.sh          # deletes the cluster
└── .gitignore
```

## Prerequisites

- Docker (running)
- [kind](https://kind.sigs.k8s.io/), [kubectl](https://kubernetes.io/docs/tasks/tools/), [Helm](https://helm.sh/docs/intro/install/)
- About 4 GB of free RAM

Verify: `docker version && kind version && kubectl version --client && helm version`

---

## Step 1: Create the cluster

```bash
kind create cluster --name lab --config kind-config.yaml
kubectl get nodes
```

**What it means:** kind runs each Kubernetes node as a Docker container. The config file asks for one control-plane and three workers. `kubectl get nodes` should show 4 nodes in `Ready` state. Multiple workers are needed so a drain has somewhere to move pods.

## Step 2: Install ArgoCD with Helm

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
helm install argocd argo/argo-cd -n argocd --create-namespace
kubectl -n argocd rollout status deploy/argocd-server
```

**What it means:**
- `helm repo add/update` registers the chart repository and refreshes its index.
- `helm install` renders the chart into Kubernetes manifests and creates a *release* named `argocd` in the `argocd` namespace.
- `rollout status` waits until the ArgoCD server is actually ready.

Get the admin password and open the UI:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d; echo

kubectl -n argocd port-forward svc/argocd-server 8080:443
```

Open https://localhost:8080 (accept the self-signed certificate), username `admin`.

**What it means:** ArgoCD generates a random initial password and stores it in a Secret. `port-forward` tunnels your local port 8080 to the in-cluster service so you can reach the UI.

## Step 3: Deploy an app through ArgoCD (GitOps)

```bash
kubectl apply -f argocd/guestbook-app.yaml
kubectl -n argocd get applications
kubectl -n guestbook get pods -o wide
```

**What it means:** An `Application` object tells ArgoCD: "take the Helm chart at this Git path and make the cluster match it."

- `automated` sync: ArgoCD applies changes without you clicking Sync.
- `prune: true`: resources deleted from Git are deleted from the cluster.
- `selfHeal: true`: manual changes in the cluster are reverted to match Git.
- `CreateNamespace=true`: creates the `guestbook` namespace for you.

**Try it, see `selfHeal` work:**

```bash
kubectl -n guestbook scale deploy/guestbook-helm-guestbook --replicas=1
kubectl -n guestbook get pods -w     # ArgoCD scales it back to 3
```

(Check the real deployment name first with `kubectl -n guestbook get deploy`.)

**Stretch goal:** fork `argocd-example-apps`, point `repoURL` at your fork, change `replicaCount` in Git, and watch ArgoCD sync it.

## Step 4: Node drain with a PodDisruptionBudget

```bash
kubectl -n guestbook get pods --show-labels     # confirm label app=helm-guestbook
kubectl apply -f manifests/pdb.yaml
kubectl -n guestbook get pods -o wide           # find a worker running guestbook pods
```

**What it means:** The PodDisruptionBudget guarantees at least 2 guestbook pods stay up during voluntary disruptions like a drain.

Now drain a worker (replace the name with one that runs pods):

```bash
NODE=lab-worker
kubectl drain $NODE --ignore-daemonsets --delete-emptydir-data
kubectl get nodes                       # node shows Ready,SchedulingDisabled
kubectl -n guestbook get pods -o wide   # pods moved to other nodes
kubectl -n argocd get pods -o wide      # ArgoCD pods recover too
```

**What it means:**
- `drain` first **cordons** the node (no new pods scheduled), then **evicts** its pods so they restart elsewhere.
- `--ignore-daemonsets`: DaemonSet pods (like kindnet) run on every node and can't be moved.
- `--delete-emptydir-data`: allows evicting pods that use temporary `emptyDir` storage (that data is lost).
- The PDB makes the drain wait rather than take the app below 2 pods.

Bring the node back:

```bash
kubectl uncordon $NODE
```

**What it means:** `uncordon` makes the node schedulable again. Existing pods do **not** move back automatically.

## Step 5: Take an etcd snapshot

```bash
./scripts/etcd-snapshot.sh lab
```

Or manually:

```bash
ETCD_POD=$(kubectl -n kube-system get pod -l component=etcd -o name)

kubectl -n kube-system exec $ETCD_POD -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save /var/lib/etcd/snapshot.db

kubectl -n kube-system exec $ETCD_POD -- etcdctl snapshot status /var/lib/etcd/snapshot.db -w table
docker cp lab-control-plane:/var/lib/etcd/snapshot.db ./etcd-snapshot.db
```

**What it means:** etcd is the key-value database holding all cluster state (every Deployment, Secret, Service, etc.). `snapshot save` writes a consistent point-in-time copy. etcd requires TLS, so the command passes the CA, certificate and key. `snapshot status` checks the file's hash, revision and size. `docker cp` copies it off the node, because a backup that lives only on the machine it protects is not a backup.

## Step 6 (optional): Restore the snapshot

**Warning:** this briefly takes the control plane down. Do it only on the lab cluster.

1. Delete something to prove the restore works:
   ```bash
   kubectl create namespace restore-test
   ./scripts/etcd-snapshot.sh lab       # snapshot taken AFTER creating the namespace
   kubectl delete namespace restore-test
   ```
2. Restore the snapshot into a new data directory, using the same etcd image the cluster runs (it includes `etcdutl`):
   ```bash
   IMAGE=$(kubectl -n kube-system get pod -l component=etcd -o jsonpath='{.items[0].spec.containers[0].image}')
   docker run --rm -v "$PWD":/backup $IMAGE \
     etcdutl snapshot restore /backup/etcd-snapshot.db --data-dir /backup/restored
   ```
3. Stop etcd, swap in the restored data, start etcd:
   ```bash
   docker exec lab-control-plane mv /etc/kubernetes/manifests/etcd.yaml /tmp/etcd.yaml
   sleep 15
   docker exec lab-control-plane mv /var/lib/etcd /var/lib/etcd.old
   docker cp ./restored lab-control-plane:/var/lib/etcd
   docker exec lab-control-plane mv /tmp/etcd.yaml /etc/kubernetes/manifests/etcd.yaml
   ```
4. Wait about a minute for the API server, then check:
   ```bash
   kubectl get ns     # restore-test should be back
   ```

**What it means:** kubelet runs etcd as a *static pod* from `/etc/kubernetes/manifests`. Moving the manifest out stops etcd; moving it back starts it again, now reading the restored data.

> The restore flow is the trickiest part of this lab. If your kind or etcd version behaves differently, check `docker logs lab-control-plane` and the etcd container logs.

## Step 7: Clean up

```bash
./scripts/cleanup.sh lab
```

**What it means:** deletes all kind node containers, removing the whole cluster.

## Troubleshooting

| Problem | Fix |
|---|---|
| `drain` hangs | The PDB is blocking it; check `kubectl get pdb -n guestbook` and that enough replicas are Ready |
| ArgoCD app `OutOfSync` or `Unknown` | `kubectl -n argocd describe application guestbook`; check internet access to GitHub |
| Port 8080 already in use | Use `8081:443` in the port-forward |
| `etcdctl: not found` on the node | Run it via `kubectl exec` into the etcd pod, as shown, not on the node |

## Portfolio checklist

- [ ] Screenshot: ArgoCD UI showing guestbook *Synced / Healthy*
- [ ] Output of `kubectl get pods -o wide` before and after the drain
- [ ] Snapshot status table
- [ ] Short note on what `selfHeal` and the PDB each protect against

## Ideas to extend

- App-of-Apps pattern to manage many apps from one ArgoCD Application
- Ingress controller installed through Helm
- Replace the example repo with your own chart repo
- Script the whole lab as a `make` target

## License

MIT
