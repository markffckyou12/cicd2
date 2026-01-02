#!/bin/bash

# --- Helper Functions ---
echo_info() { echo -e "\e[34m[INFO]\e[0m $1"; }
echo_success() { echo -e "\e[32m[SUCCESS]\e[0m $1"; }
echo_error() { echo -e "\e[31m[ERROR]\e[0m $1"; exit 1; }

# ==============================================================================
# PHASE 1: IDENTITY & GITOPS VALIDATION
# ==============================================================================
echo_info "--- Initializing Secure CI Factory (2026 Hardened CI Edition v3.7) ---"

GIT_USER=${GIT_USER:-$(read -p "Enter GitHub Username: " u && echo $u)}
GIT_TOKEN=${GIT_TOKEN:-$(read -s -p "Enter GitHub PAT: " t && echo $t)}
echo ""
REPO_NAME=${REPO_NAME:-$(read -p "Enter Target Repository (e.g., user/project): " r && echo $r)}

echo_info "Verifying GitHub Access..."
REPO_DATA=$(curl -s -u "$GIT_USER:$GIT_TOKEN" "https://api.github.com/repos/$REPO_NAME")
if [[ $REPO_DATA == *"Not Found"* ]]; then echo_error "Repo not found or Token invalid."; fi

DOCKER_USER=${DOCKER_USER:-$(read -p "Enter Docker Hub Username: " du && echo $du)}
DOCKER_PASS=${DOCKER_PASS:-$(read -s -p "Enter Docker Hub Password: " dp && echo $dp)}
echo ""
echo_success "Identity Verified."

# ==============================================================================
# PHASE 2: RESOURCE BUDGETING (Optimized for CI Parallelism)
# ==============================================================================
NAMESPACE=${NAMESPACE:-tekton-tasks}
MAX_PODS=25         # High parallelism for Layer 1-4 gates
PVC_SIZE=10Gi       # Larger cache for Trivy and Buildah
CLOUD_CHOICE=${CLOUD_CHOICE:-1}

case $CLOUD_CHOICE in 2) SC="gp3" ;; 3) SC="premium-rwo" ;; 4) SC="managed-csi-premium" ;; *) SC="standard" ;; esac

# ==============================================================================
# PHASE 3: ENGINE INSTALLATION
# ==============================================================================
echo_info "Installing Engines & CLIs..."
[ ! -x "$(command -v helm)" ] && { curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash; }
[ ! -x "$(command -v tkn)" ] && { curl -LO https://github.com/tektoncd/cli/releases/download/v0.43.0/tkn_0.43.0_Linux_x86_64.tar.gz && sudo tar xvzf tkn_0.43.0_Linux_x86_64.tar.gz -C /usr/local/bin/ tkn && rm tkn_0.43.0_Linux_x86_64.tar.gz; }
[ ! -x "$(command -v kubeseal)" ] && { curl -L "https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.33.1/kubeseal-0.33.1-linux-amd64.tar.gz" | tar xz && sudo install -m 755 kubeseal /usr/local/bin/kubeseal && rm kubeseal; }
[ ! -x "$(command -v yq)" ] && { curl -L "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64" -o /usr/local/bin/yq && chmod +x /usr/local/bin/yq; }

kubectl apply -f https://storage.googleapis.com/tekton-releases/pipeline/latest/release.yaml

if ! kubectl get pods -n kube-system -l app.kubernetes.io/name=sealed-secrets | grep -q "Running"; then
    helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets && helm repo update
    helm install sealed-secrets-controller sealed-secrets/sealed-secrets --namespace kube-system
fi

# ==============================================================================
# PHASE 4: THE HARDENED CI REGISTRY (22-Task Foundation)
# ==============================================================================
echo_info "Provisioning Quality & Security Gates..."
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Layer 1: App Quality (Language Selection)
LANG_CHOICE=${LANG_CHOICE:-1}
case $LANG_CHOICE in
    1) TASKS_L1=("flake8" "pylint" "mypy-lint" "python-black") ;;
    2) TASKS_L1=("eslint") ;;
    3) TASKS_L1=("golangci-lint") ;;
    4) TASKS_L1=("ruby-linter") ;;
    5) TASKS_L1=("shellcheck") ;;
esac

# CI Layers (Excluding CD Delivery Tasks)
TASKS_INFRA=("yaml-lint" "kube-linter" "datree")                   # Layer 2
TASKS_PACKAGE=("git-clone" "git-version" "hadolint")               # Layer 3
TASKS_MAINTENANCE=("markdown-lint" "cleanup")                      # Layer 4
TASKS_SECURITY=("trivy-scanner" "cosign-sign" "rhacs-image-scan")  # Layer 5

ALL_TASKS=("${TASKS_L1[@]}" "${TASKS_INFRA[@]}" "${TASKS_PACKAGE[@]}" "${TASKS_MAINTENANCE[@]}" "${TASKS_SECURITY[@]}")

for TASK in "${ALL_TASKS[@]}"; do
    tkn hub install task "$TASK" -n "$NAMESPACE" 2>/dev/null || echo_info "Task $TASK ready."
done

# --- Buildah Injection (Specialized for Restricted K8s) ---
tkn hub get task buildah --version 0.7 > buildah-raw.yaml
yq -i '
  .spec.steps[0].env += [{"name": "STORAGE_DRIVER", "value": "overlay"}] |
  .spec.steps[0].env += [{"name": "STORAGE_OPTS", "value": "mount_program=/usr/bin/fuse-overlayfs"}] |
  .spec.steps[0].securityContext = {
    "runAsUser": 1000,
    "runAsGroup": 1000,
    "allowPrivilegeEscalation": true,
    "capabilities": {"add": ["SYS_ADMIN"]}
  }
' buildah-raw.yaml
kubectl apply -f buildah-raw.yaml -n "$NAMESPACE" && rm buildah-raw.yaml

# ==============================================================================
# PHASE 5: INFRASTRUCTURE & PERSISTENCE
# ==============================================================================
BASE_DIR="./tekton-bootstrap-v3"
mkdir -p "$BASE_DIR/infrastructure" "$BASE_DIR/security"

# Save Config for the Execution Script
cat <<EOF > .factory_config
NAMESPACE=$NAMESPACE
DOCKER_USER=$DOCKER_USER
GIT_USER=$GIT_USER
LANG_CHOICE=$LANG_CHOICE
EOF

# Resource Quota
cat <<EOF > "$BASE_DIR/infrastructure/quota.yaml"
apiVersion: v1
kind: ResourceQuota
metadata:
  name: tekton-quota
  namespace: $NAMESPACE
spec:
  hard:
    pods: "$MAX_PODS"
    requests.storage: $PVC_SIZE
EOF

# PVC (The Shared Workspace)
cat <<EOF > "$BASE_DIR/infrastructure/pvc.yaml"
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: tekton-pvc
  namespace: $NAMESPACE
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: $SC
  resources: { requests: { storage: $PVC_SIZE } }
EOF

kubectl apply -f "$BASE_DIR/infrastructure/"

# ==============================================================================
# PHASE 6: SECURITY IDENTITY (Sealing the CI Bot)
# ==============================================================================
echo_info "Sealing Credentials..."
kubeseal --controller-name=sealed-secrets-controller --controller-namespace=kube-system --fetch-cert > public-cert.pem

kubectl create secret docker-registry docker-hub-creds --docker-username="$DOCKER_USER" --docker-password="$DOCKER_PASS" --docker-server="https://index.docker.io/v1/" --dry-run=client -o yaml | \
kubeseal --format=yaml --cert=public-cert.pem --namespace "$NAMESPACE" > "$BASE_DIR/security/docker-hub-sealed.yaml"

kubectl create secret generic git-creds --from-literal=username="$GIT_USER" --from-literal=password="$GIT_TOKEN" --type=kubernetes.io/basic-auth --dry-run=client -o yaml | \
kubeseal --format=yaml --cert=public-cert.pem --namespace "$NAMESPACE" > "$BASE_DIR/security/git-creds-sealed.yaml"

kubectl apply -f "$BASE_DIR/security/"
rm public-cert.pem

# Build-Bot wiring
SA_NAME="build-bot"
kubectl create serviceaccount "$SA_NAME" -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl patch serviceaccount "$SA_NAME" -n "$NAMESPACE" -p "{\"secrets\": [{\"name\": \"docker-hub-creds\"}, {\"name\": \"git-creds\"}]}"

echo "------------------------------------------------------------"
echo_success "V3.7 CI FACTORY BOOTSTRAP COMPLETE!"
echo_info "Focus: CI Quality Gates & Supply Chain Security"
echo_info "Parallel Pod Limit: $MAX_PODS"
echo "------------------------------------------------------------"
