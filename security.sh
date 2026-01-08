#!/bin/bash
set -euo pipefail

echo "--- Phase 1: Infrastructure Tools ---"
helm repo add sigstore https://sigstore.github.io/helm-charts > /dev/null 2>&1
helm repo update

echo "--- Phase 2: Deploying Full Sigstore Stack ---"
helm upgrade --install scaffold sigstore/scaffold \
  -n sigstore --create-namespace \
  --set fulcio.enabled=true \
  --set rekor.enabled=true \
  --set trillian.enabled=true \
  --set ctlog.enabled=true

echo "Waiting for components to stabilize..."
kubectl wait --for=condition=available deployment/rekor-server -n rekor-system --timeout=120s
kubectl wait --for=condition=available deployment/fulcio-server -n fulcio-system --timeout=120s

echo "--- Phase 3: Installing Tekton Chains ---"
kubectl apply -f https://storage.googleapis.com/tekton-releases/chains/latest/release.yaml
kubectl wait --for=condition=ready pod -l app.kubernetes.io/component=controller -n tekton-chains --timeout=90s

echo "--- Phase 4: Linking Chains to Local Infrastructure ---"
kubectl patch configmap chains-config -n tekton-chains -p='{"data":{
  "artifacts.taskrun.format": "in-toto",
  "artifacts.taskrun.storage": "tekton",
  "artifacts.oci.storage": "oci",
  "signers.x509.fulcio.enabled": "true",
  "signers.x509.fulcio.address": "http://fulcio-server.fulcio-system.svc.cluster.local",
  "signers.x509.rekor.address": "http://rekor-server.rekor-system.svc.cluster.local",
  "transparency.enabled": "true",
  "transparency.url": "http://rekor-server.rekor-system.svc.cluster.local"
}}'

kubectl rollout restart deployment tekton-chains-controller -n tekton-chains

echo "--- Phase 5: Persistent Background Port-Forwarding ---"
pkill -f "kubectl port-forward" || true
# Listening on 0.0.0.0 allows host.minikube.internal to resolve these ports
nohup kubectl port-forward --address 0.0.0.0 svc/rekor-server -n rekor-system 3000:80 > /dev/null 2>&1 &
nohup kubectl port-forward --address 0.0.0.0 svc/fulcio-server -n fulcio-system 3001:80 > /dev/null 2>&1 &
sleep 5

echo "--- Phase 6: Syncing Local Trust Roots ---"
curl -s http://localhost:3000/api/v1/log/publicKey > rekor_local.pub
curl -s http://localhost:3001/api/v1/rootCert > fulcio_root.pem

echo "--- Full Sigstore Infrastructure Ready ---"
