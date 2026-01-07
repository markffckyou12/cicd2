#!/bin/bash
set -euo pipefail

INFRA_NS="trivy-system"
echo "--- Initializing Persistent Infrastructure (Cluster-Native) ---"

kubectl create namespace ${INFRA_NS} --dry-run=client -o yaml | kubectl apply -f -

# Deploy Services (Loki and Trivy)
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: trivy-server
  namespace: ${INFRA_NS}
  labels: { app: trivy-server }
spec:
  containers:
  - name: trivy
    image: aquasec/trivy:latest
    args: ["server", "--listen", "0.0.0.0:8080"]
    ports: [{ containerPort: 8080 }]
---
apiVersion: v1
kind: Service
metadata:
  name: trivy-server
  namespace: ${INFRA_NS}
spec:
  selector: { app: trivy-server }
  ports: [{ protocol: TCP, port: 8080, targetPort: 8080 }]
---
apiVersion: v1
kind: Pod
metadata:
  name: loki-server
  namespace: ${INFRA_NS}
  labels: { app: loki-server }
spec:
  containers:
  - name: loki
    image: grafana/loki:latest
    ports: [{ containerPort: 3100 }]
---
apiVersion: v1
kind: Service
metadata:
  name: loki-server
  namespace: ${INFRA_NS}
spec:
  selector: { app: loki-server }
  ports: [{ protocol: TCP, port: 3100, targetPort: 3100 }]
EOF

echo "Waiting for pods to pull images (Timeout 300s)..."
kubectl wait --for=condition=Ready pod -l app=trivy-server -n ${INFRA_NS} --timeout=300s
kubectl wait --for=condition=Ready pod -l app=loki-server -n ${INFRA_NS} --timeout=300s

echo "Waiting for Loki API readiness..."
until kubectl run probe-loki -n ${INFRA_NS} --rm -i --image=curlimages/curl:latest --restart=Never -- curl -s http://loki-server:3100/ready | grep "ready" > /dev/null; do
  echo "Loki is still initializing... sleeping 5s"
  sleep 5
done

echo "Waiting for Trivy Database initialization..."
until kubectl run probe-trivy -n ${INFRA_NS} --rm -i --image=alpine --restart=Never -- nc -z trivy-server 8080; do
  echo "Trivy is still downloading DB... sleeping 5s"
  sleep 5
done

echo -e "\e[32m--- INFRASTRUCTURE IS FULLY READY ---\e[0m"c
