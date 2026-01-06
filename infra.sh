#!/bin/bash
set -euo pipefail

INFRA_NS="trivy-system"

echo "--- Initializing Persistent Infrastructure (Cluster-Native) ---"

# 1. ENSURE NAMESPACE EXISTS
kubectl create namespace ${INFRA_NS} --dry-run=client -o yaml | kubectl apply -f -

# 2. DEPLOY TRIVY & LOKI AS K8S SERVICES
# We use Pods + Services to ensure stable internal DNS
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: trivy-server
  namespace: ${INFRA_NS}
  labels:
    app: trivy-server
spec:
  containers:
  - name: trivy
    image: aquasec/trivy:latest
    args: ["server", "--listen", "0.0.0.0:8080"]
    ports:
    - containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: trivy-server
  namespace: ${INFRA_NS}
spec:
  selector:
    app: trivy-server
  ports:
    - protocol: TCP
      port: 8080
      targetPort: 8080
---
apiVersion: v1
kind: Pod
metadata:
  name: loki-server
  namespace: ${INFRA_NS}
  labels:
    app: loki-server
spec:
  containers:
  - name: loki
    image: grafana/loki:latest
    ports:
    - containerPort: 3100
---
apiVersion: v1
kind: Service
metadata:
  name: loki-server
  namespace: ${INFRA_NS}
spec:
  selector:
    app: loki-server
  ports:
    - protocol: TCP
      port: 3100
      targetPort: 3100
EOF

# 3. HEALTH CHECK (Internal Probing)
echo "Waiting for pods to be ready..."
kubectl wait --for=condition=Ready pod/trivy-server -n ${INFRA_NS} --timeout=60s
kubectl wait --for=condition=Ready pod/loki-server -n ${INFRA_NS} --timeout=60s

echo "Waiting for Trivy Database initialization..."
until kubectl run probe -n ${INFRA_NS} --rm -i --image=alpine --restart=Never -- nc -z trivy-server 8080; do
  echo "Trivy is still downloading DB... sleeping 5s"
  sleep 5
done

echo "--- INFRASTRUCTURE IS UP AND READY ---"
echo "Scanner (Internal): http://trivy-server.${INFRA_NS}.svc.cluster.local:8080"
echo "Log Vault (Internal): http://loki-server.${INFRA_NS}.svc.cluster.local:3100"

# CLEANUP: Remove any old local Docker containers to avoid port confusion
docker rm -f trivy-server-local loki-server-local 2>/dev/null || true
