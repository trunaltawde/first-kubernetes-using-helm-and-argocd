#!/usr/bin/env bash
# Takes an etcd snapshot from the kind control-plane and copies it to the current directory.
set -euo pipefail
CLUSTER=${1:-lab}
ETCD_POD=$(kubectl -n kube-system get pod -l component=etcd -o name)

kubectl -n kube-system exec "$ETCD_POD" -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save /var/lib/etcd/snapshot.db

kubectl -n kube-system exec "$ETCD_POD" -- etcdctl snapshot status /var/lib/etcd/snapshot.db -w table
docker cp "${CLUSTER}-control-plane:/var/lib/etcd/snapshot.db" ./etcd-snapshot.db
echo "Saved ./etcd-snapshot.db"
