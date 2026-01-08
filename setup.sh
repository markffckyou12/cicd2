#!/bin/bash
set -euo pipefail 

# --- Helper Functions ---
echo_info() { echo -e "\e[34m[INFO]\e[0m ${1:-}"; }
echo_success() { echo -e "\e[32m[SUCCESS]\e[0m ${1:-}"; }
echo_warn() { echo -e "\e[33m[WARN]\e[0m ${1:-}"; }
echo_error() { echo -e "\e[31m[ERROR]\e[0m ${1:-}"; exit 1; }

# ==============================================================================
# PHASE 1: CONFIG & DISCOVERY
# ==============================================================================
NAMESPACE=${NAMESPACE:-"tekton-tasks"}
GIT_USER=${GIT_USER:-"markffckyou12"}
DOCKER_USER=${DOCKER_USER:-"ffckyou123"}
TRIVY_SERVER="http://host.minikube.internal:8080"

# Sigstore Internal URLs (Keyless Infrastructure)
REKOR_URL="http://rekor-server.rekor-system.svc.cluster.local"
FULCIO_URL="http://fulcio-server.fulcio-system.svc.cluster.local"

# ==============================================================================
# PHASE 2: IDENTITY & SECRETS
# ==============================================================================
[ -z "${GIT_TOKEN:-}" ] && { read -s -p "Enter GitHub PAT: " GIT_TOKEN; echo ""; }
[ -z "${DOCKER_PASS:-}" ] && { read -s -p "Enter Docker Hub Password: " DOCKER_PASS; echo ""; }

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

echo_info "Configuring Credentials..."
# Docker Hub
kubectl create secret docker-registry docker-hub-creds \
  --docker-username="$DOCKER_USER" --docker-password="$DOCKER_PASS" \
  --docker-server="https://index.docker.io/v1/" -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl annotate secret docker-hub-creds "tekton.dev/docker-0=https://index.docker.io/v1/" --overwrite -n "$NAMESPACE"

# GitHub
kubectl create secret generic github-creds --from-literal=username="$GIT_USER" --from-literal=password="$GIT_TOKEN" --type=kubernetes.io/basic-auth -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl annotate secret github-creds "tekton.dev/git-0=https://github.com" --overwrite -n "$NAMESPACE"

# Service Account
kubectl create serviceaccount build-bot -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl patch serviceaccount build-bot -n "$NAMESPACE" -p "{\"secrets\": [{\"name\": \"docker-hub-creds\"}, {\"name\": \"github-creds\"}]}"

# ==============================================================================
# PHASE 3: THE KEYLESS PIPELINE
# ==============================================================================
echo_info "Deploying Keyless DevSecOps Pipeline..."

cat <<EOF | kubectl apply -n "$NAMESPACE" -f -
apiVersion: tekton.dev/v1
kind: Pipeline
metadata:
  name: devsecops-pipeline
spec:
  params:
    - name: repo-url
    - name: image-full-name
  workspaces:
    - name: shared-data
  tasks:
    - name: fetch-repo
      taskRef: { resolver: hub, params: [{ name: kind, value: task }, { name: name, value: git-clone }, { name: version, value: "0.9" }] }
      workspaces: [ { name: output, workspace: shared-data } ]
      params: [ { name: url, value: "\$(params.repo-url)" } ]

    - name: build-and-push
      runAfter: ["fetch-repo"]
      workspaces: [ { name: source, workspace: shared-data } ]
      params: [ { name: image-full-name, value: "\$(params.image-full-name)" } ]
      taskSpec:
        params: [ { name: image-full-name } ]
        workspaces: [ { name: source } ]
        results:
          - name: IMAGE_DIGEST
        steps:
          - name: build-and-push
            image: quay.io/buildah/stable:v1.30
            env: [ { name: REGISTRY_AUTH_FILE, value: /tekton/creds/.docker/config.json } ]
            script: |
              set -e
              # Build image
              buildah bud --storage-driver=vfs -f \$(workspaces.source.path)/Dockerfile -t \$(params.image-full-name) \$(workspaces.source.path)
              # Push and capture digest (Crucial for Tekton Chains to trigger signing)
              buildah push --storage-driver=vfs --digestfile \$(results.IMAGE_DIGEST.path) \$(params.image-full-name)

    - name: image-scan
      runAfter: ["build-and-push"]
      params: [ { name: image-full-name, value: "\$(params.image-full-name)" } ]
      taskSpec:
        params: [ { name: image-full-name } ]
        steps:
          - name: trivy-scan
            image: aquasec/trivy:latest
            script: |
              trivy image --server $TRIVY_SERVER --severity HIGH,CRITICAL \$(params.image-full-name)

    - name: verify-gate
      runAfter: ["image-scan"]
      params: [ { name: image-full-name, value: "\$(params.image-full-name)" } ]
      taskSpec:
        params: [ { name: image-full-name } ]
        steps:
          - name: verify
            image: alpine:3.18
            script: |
              apk add --no-cache curl
              curl -LO https://github.com/sigstore/cosign/releases/latest/download/cosign-linux-amd64
              chmod +x cosign-linux-amd64
              mv cosign-linux-amd64 /usr/local/bin/cosign

              # Fetch roots for verification
              curl -s $REKOR_URL/api/v1/log/publicKey > /tmp/rekor.pub
              curl -s $FULCIO_URL/api/v1/rootCert > /tmp/fulcio_root.pem
              export SIGSTORE_REKOR_PUBLIC_KEY=/tmp/rekor.pub

              echo "Waiting 30s for signature to be generated by Tekton Chains..."
              sleep 30
              
              cosign verify \
                --rekor-url $REKOR_URL \
                --allow-insecure-registry \
                --cert-chain /tmp/fulcio_root.pem \
                --insecure-ignore-sct \
                --certificate-identity="https://kubernetes.io/namespaces/tekton-chains/serviceaccounts/tekton-chains-controller" \
                --certificate-oidc-issuer="https://kubernetes.default.svc.cluster.local" \
                \$(params.image-full-name)
EOF

echo_success "ALL SYSTEMS READY (KEYLESS MODE)."
echo "------------------------------------------------------------------------"
echo "RUN THIS COMMAND TO START:"
echo "------------------------------------------------------------------------"
echo "tkn pipeline start devsecops-pipeline \\
  --param repo-url=\"https://github.com/$GIT_USER/cicd2.git\" \\
  --param image-full-name=\"docker.io/$DOCKER_USER/cicd-test:latest\" \\
  --workspace name=shared-data,volumeClaimTemplateFile=workspace-template.yaml \\
  --serviceaccount build-bot \\
  --namespace $NAMESPACE \\
  --showlog"
