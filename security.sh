#!/bin/bash
set -euo pipefail

echo "--- Phase 1: Deploying Full Sigstore Stack ---"
helm repo add sigstore https://sigstore.github.io/helm-charts > /dev/null 2>&1
helm repo update

# Using --take-ownership to handle pre-existing namespaces in Codespaces
helm upgrade --install scaffold sigstore/scaffold \
  -n sigstore --create-namespace \
  --set copy-secrets.enabled=true \
  --take-ownership \
  --wait --timeout 5m

echo "Waiting for deployments..."
kubectl wait --for=condition=available deployment/rekor-server -n rekor-system --timeout=120s
kubectl wait --for=condition=available deployment/fulcio-server -n fulcio-system --timeout=120s

# Wait for the specific Fulcio Root CA secret
echo "Waiting for Fulcio Root CA secret to be ready..."
until kubectl get secret fulcio-server-secret -n fulcio-system > /dev/null 2>&1; do
  sleep 5
done

echo "--- Phase 2: Installing & Configuring Chains ---"
# Re-apply Chains to ensure it's fresh
kubectl apply -f https://storage.googleapis.com/tekton-releases/chains/latest/release.yaml
kubectl wait --for=condition=available deployment/tekton-chains-controller -n tekton-chains --timeout=120s

# Configure Chains for Keyless Local Signing
kubectl patch configmap chains-config -n tekton-chains -p='{"data":{
  "artifacts.taskrun.format": "in-toto",
  "artifacts.taskrun.storage": "tekton",
  "artifacts.oci.storage": "oci",
  "signers.x509.fulcio.enabled": "true",
  "signers.x509.fulcio.address": "http://fulcio-server.fulcio-system.svc.cluster.local",
  "signers.x509.rekor.address": "http://rekor-server.rekor-system.svc.cluster.local",
  "transparency.enabled": "true"
}}'

# Force restart to pick up the patch
kubectl delete pod -n tekton-chains -l app=tekton-chains-controller
echo "--- Infrastructure Ready ---"
