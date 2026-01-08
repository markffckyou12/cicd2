#!/bin/bash
set -euo pipefail 

# Helpers for clean output
echo_info() { echo -e "\e[34m[INFO]\e[0m ${1:-}"; }
echo_success() { echo -e "\e[32m[SUCCESS]\e[0m ${1:-}"; }
echo_warn() { echo -e "\e[33m[WARN]\e[0m ${1:-}"; }

# ==============================================================================
# PHASE 1: CONFIG
# ==============================================================================
NAMESPACE=${NAMESPACE:-"tekton-tasks"}
GIT_USER=${GIT_USER:-"markffckyou12"}
DOCKER_USER=${DOCKER_USER:-"ffckyou123"}
TRIVY_SERVER="http://host.minikube.internal:8080"
REKOR_URL="http://rekor-server.rekor-system.svc.cluster.local"
FULCIO_URL="http://fulcio-server.fulcio-system.svc.cluster.local"

# ==============================================================================
# PHASE 2: PRE-FLIGHT (Tekton, Chains & CLI Check)
# ==============================================================================
# 1. Tekton Pipelines
if ! kubectl get ns tekton-pipelines >/dev/null 2>&1; then
    echo_info "Installing Tekton Pipelines..."
    kubectl apply -f https://storage.googleapis.com/tekton-releases/pipeline/latest/release.yaml
    echo_info "Waiting for API to recognize Tekton Resources..."
    until kubectl get crd pipelines.tekton.dev >/dev/null 2>&1; do sleep 2; done
    kubectl wait --for condition=established --timeout=120s crd/pipelines.tekton.dev
fi

# 2. Tekton Chains (Installation & Config)
if ! kubectl get ns tekton-chains >/dev/null 2>&1; then
    echo_info "Installing Tekton Chains..."
    kubectl apply -f https://storage.googleapis.com/tekton-releases/chains/latest/release.yaml
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/component=controller -n tekton-chains --timeout=120s
    
    echo_info "Configuring Chains for Keyless Signing..."
    kubectl patch configmap chains-config -n tekton-chains --type merge -p='{"data":{
      "artifacts.taskrun.format": "in-toto",
      "artifacts.taskrun.storage": "oci",
      "artifacts.oci.storage": "oci",
      "signers.x509.fulcio.enabled": "true",
      "signers.x509.fulcio.address": "'$FULCIO_URL'",
      "signers.x509.rekor.address": "'$REKOR_URL'",
      "transparency.enabled": "true"
    }}'
    kubectl rollout restart deployment tekton-chains-controller -n tekton-chains
    kubectl wait --for=condition=available deployment/tekton-chains-controller -n tekton-chains --timeout=120s
fi

# 3. Tekton CLI
echo_info "Checking for Tekton CLI (tkn)..."
if ! command -v tkn &> /dev/null; then
    echo_info "Installing tkn CLI..."
    curl -LO https://github.com/tektoncd/cli/releases/download/v0.43.0/tkn_0.43.0_Linux_x86_64.tar.gz
    sudo tar xvzf tkn_0.43.0_Linux_x86_64.tar.gz -C /usr/local/bin/ tkn > /dev/null
    rm tkn_0.43.0_Linux_x86_64.tar.gz
fi

# ==============================================================================
# PHASE 3: IDENTITY, SECRETS & STORAGE
# ==============================================================================
[ -z "${GIT_TOKEN:-}" ] && { read -s -p "Enter GitHub PAT: " GIT_TOKEN; echo ""; }
[ -z "${DOCKER_PASS:-}" ] && { read -s -p "Enter Docker Hub Password: " DOCKER_PASS; echo ""; }

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

echo_info "Creating Shared Workspace Storage..."
cat <<EOF | kubectl apply -n "$NAMESPACE" -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: shared-data-pvc
spec:
  accessModes: [ "ReadWriteOnce" ]
  resources:
    requests:
      storage: 500Mi
EOF

kubectl create secret docker-registry docker-hub-creds \
  --docker-username="$DOCKER_USER" --docker-password="$DOCKER_PASS" \
  --docker-server="https://index.docker.io/v1/" -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl annotate secret docker-hub-creds "tekton.dev/docker-0=https://index.docker.io/v1/" --overwrite -n "$NAMESPACE"

kubectl create secret generic github-creds --from-literal=username="$GIT_USER" --from-literal=password="$GIT_TOKEN" --type=kubernetes.io/basic-auth -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl annotate secret github-creds "tekton.dev/git-0=https://github.com" --overwrite -n "$NAMESPACE"

kubectl create serviceaccount build-bot -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl patch serviceaccount build-bot -n "$NAMESPACE" -p "{\"secrets\": [{\"name\": \"docker-hub-creds\"}, {\"name\": \"github-creds\"}]}"

# ==============================================================================
# PHASE 4: THE GUARD (Kyverno Engine)
# ==============================================================================
echo_info "Updating Kyverno Admission Controller..."
helm repo add kyverno https://kyverno.github.io/kyverno/ > /dev/null 2>&1
helm repo update > /dev/null
helm upgrade --install kyverno kyverno/kyverno -n kyverno --create-namespace --set admissionController.replicas=1 --wait

# ==============================================================================
# PHASE 5: THE POLICY
# ==============================================================================
echo_info "Applying Signature Enforcement Policy..."
cat <<EOF | kubectl apply -f -
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: check-image-signature
spec:
  validationFailureAction: Audit 
  background: false
  rules:
    - name: verify-sigstore-signature
      match:
        any:
        - resources:
            namespaces: ["$NAMESPACE"]
            kinds: ["Pod"]
      verifyImages:
      - imageReferences: ["index.docker.io/$DOCKER_USER/*"]
        mutateDigest: false
        attestors:
        - entries:
          - keyless:
              issuer: "https://kubernetes.default.svc.cluster.local"
              subject: "https://kubernetes.io/namespaces/tekton-chains/serviceaccounts/tekton-chains-controller"
              rekor:
                url: "$REKOR_URL"
EOF

# ==============================================================================
# PHASE 6: PIPELINE DEFINITION
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
          - name: IMAGE_URL
        steps:
          - name: build-and-push
            image: quay.io/buildah/stable:v1.30
            env: [ { name: REGISTRY_AUTH_FILE, value: /tekton/creds/.docker/config.json } ]
            script: |
              set -e
              buildah bud --storage-driver=vfs -f \$(workspaces.source.path)/Dockerfile -t \$(params.image-full-name) \$(workspaces.source.path)
              buildah push --storage-driver=vfs --digestfile \$(results.IMAGE_DIGEST.path) \$(params.image-full-name)
              echo -n "\$(params.image-full-name)" > \$(results.IMAGE_URL.path)
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
              curl -s $REKOR_URL/api/v1/log/publicKey > /tmp/rekor.pub
              curl -s $FULCIO_URL/api/v1/rootCert > /tmp/fulcio_root.pem
              export SIGSTORE_REKOR_PUBLIC_KEY=/tmp/rekor.pub
              echo "Waiting 30s for Tekton Chains..."
              sleep 30
              cosign verify --rekor-url $REKOR_URL --allow-insecure-registry --cert-chain /tmp/fulcio_root.pem --insecure-ignore-sct --certificate-identity="https://kubernetes.io/namespaces/tekton-chains/serviceaccounts/tekton-chains-controller" --certificate-oidc-issuer="https://kubernetes.default.svc.cluster.local" \$(params.image-full-name)
EOF

echo_success "MASTER BLUEPRINT COMPLETE."

# ==============================================================================
# TRIGGER SECTION
# ==============================================================================
echo_info "To trigger a new build, run the following:"
echo "-----------------------------------------------------------------------"
echo "tkn pipeline start devsecops-pipeline \\"
echo "  -n $NAMESPACE \\"
echo "  --serviceaccount build-bot \\"
echo "  --param repo-url=https://github.com/$GIT_USER/cicd2 \\"
echo "  --param image-full-name=index.docker.io/$DOCKER_USER/demo-app:latest \\"
echo "  --workspace name=shared-data,claimName=shared-data-pvc \\"
echo "  --showlog"
echo "-----------------------------------------------------------------------"
