#!/bin/bash

# --- Helper Functions ---
echo_info() { echo -e "\e[34m[INFO]\e[0m $1"; }
echo_success() { echo -e "\e[32m[SUCCESS]\e[0m $1"; }
echo_error() { echo -e "\e[31m[ERROR]\e[0m $1"; exit 1; }

# ==============================================================================
# PHASE 1: ALL USER INPUTS (UX OPTIMIZATION)
# ==============================================================================
echo_info "--- Welcome to the Ultimate CI Factory Bootstrap ---"
echo "------------------------------------------------------------"

# 1. Environment & UI Toggle
read -p "Enter Namespace for CI [default: tekton-tasks]: " NAMESPACE
NAMESPACE=${NAMESPACE:-tekton-tasks}

read -p "Enter Service Account name [default: build-bot]: " SA_NAME
SA_NAME=${SA_NAME:-build-bot}

read -p "Install and AUTO-OPEN Tekton Dashboard UI? (y/n) [default: n]: " INSTALL_UI
INSTALL_UI=${INSTALL_UI:-n}

# 2. Cloud & Storage Selection
echo -e "\nSelect Environment (Sets StorageClass):"
echo "1) Minikube / Local / Codespaces (standard)"
echo "2) AWS (gp3)"
echo "3) Google Cloud (premium-rwo)"
echo "4) Azure (managed-csi-premium)"
read -p "Selection [1-4, default: 1]: " CLOUD_CHOICE

case $CLOUD_CHOICE in
    2) SC="gp3" ;; 3) SC="premium-rwo" ;; 4) SC="managed-csi-premium" ;; *) SC="standard" ;;
esac

read -p "Enter PVC size in GB [default: 5]: " STORAGE_SIZE
STORAGE_SIZE=${STORAGE_SIZE:-5}

# 3. Credentials
echo ""
read -p "Enter GitHub Username: " GIT_USER
read -s -p "Enter GitHub PAT: " GIT_TOKEN; echo ""
read -p "Enter Docker Hub Username: " DOCKER_USER
read -s -p "Enter Docker Hub Password: " DOCKER_PASS; echo ""

echo "------------------------------------------------------------"
echo_success "Inputs recorded. Moving to automated installation..."
echo "------------------------------------------------------------"

# ==============================================================================
# PHASE 2: FOLDER ORGANIZATION (The Blueprints Desk)
# ==============================================================================
BASE_DIR="./tekton-bootstrap"
INFRA_DIR="$BASE_DIR/infrastructure"
TASK_DIR="$BASE_DIR/tasks"
SEC_DIR="$BASE_DIR/security"
mkdir -p "$INFRA_DIR" "$TASK_DIR" "$SEC_DIR"

# ==============================================================================
# PHASE 3: TOOLING & CONTROLLERS
# ==============================================================================

# Check Kubernetes Connection
kubectl cluster-info > /dev/null 2>&1 || echo_error "Cluster unreachable."

# Install CLI Tools if missing
[ ! -x "$(command -v helm)" ] && { echo_info "Installing Helm..."; curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash; }
[ ! -x "$(command -v tkn)" ] && { echo_info "Installing Tekton CLI..."; curl -LO https://github.com/tektoncd/cli/releases/download/v0.43.0/tkn_0.43.0_Linux_x86_64.tar.gz && sudo tar xvzf tkn_0.43.0_Linux_x86_64.tar.gz -C /usr/local/bin/ tkn && rm tkn_0.43.0_Linux_x86_64.tar.gz; }
[ ! -x "$(command -v kubeseal)" ] && { echo_info "Installing kubeseal..."; curl -L "https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.33.1/kubeseal-0.33.1-linux-amd64.tar.gz" | tar xz && sudo install -m 755 kubeseal /usr/local/bin/kubeseal && rm kubeseal; }

# Install Tekton Pipelines
if ! kubectl get namespace tekton-pipelines &> /dev/null; then
    echo_info "Installing Tekton Pipelines..."
    kubectl apply -f https://storage.googleapis.com/tekton-releases/pipeline/latest/release.yaml
    kubectl wait --for=condition=Available deployment/tekton-pipelines-controller -n tekton-pipelines --timeout=180s
fi

# OPTIONAL: Install Tekton Dashboard
if [[ "$INSTALL_UI" =~ ^[Yy]$ ]]; then
    if ! kubectl get pods -n tekton-pipelines -l app.kubernetes.io/component=dashboard | grep -q "Running"; then
        echo_info "Installing Tekton Dashboard..."
        kubectl apply -f https://storage.googleapis.com/tekton-releases/dashboard/latest/release.yaml
        kubectl wait --for=condition=Available deployment/tekton-dashboard -n tekton-pipelines --timeout=120s
    fi
fi

# Install Sealed Secrets Controller
if ! kubectl get pods -A -l app.kubernetes.io/name=sealed-secrets | grep -q "Running"; then
    echo_info "Installing Sealed Secrets..."
    helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets && helm repo update
    helm install sealed-secrets-controller sealed-secrets/sealed-secrets --namespace kube-system
    kubectl rollout status deployment/sealed-secrets-controller -n kube-system --timeout=120s
fi

# ==============================================================================
# PHASE 4: MANIFEST GENERATION (Blueprints)
# ==============================================================================

echo_info "Generating Blueprints..."

# 0. Namespace
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml > "$BASE_DIR/namespace.yaml"
kubectl apply -f "$BASE_DIR/namespace.yaml"

# 1. Infrastructure (PVC)
cat <<EOF > "$INFRA_DIR/pvc.yaml"
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: tekton-pvc
  namespace: $NAMESPACE
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: $SC
  resources:
    requests:
      storage: ${STORAGE_SIZE}Gi
EOF

# 2. Tasks (Cleanup)
cat <<EOF > "$TASK_DIR/cleanup-workspace.yaml"
apiVersion: tekton.dev/v1beta1
kind: Task
metadata:
  name: cleanup-workspace
  namespace: $NAMESPACE
spec:
  workspaces:
    - name: source
  steps:
    - name: clean
      image: alpine
      script: |
        echo "Clearing source code from workspace..."
        rm -rf /workspace/source/*
EOF

# 3. Security (SA & Sealed Secrets)
kubectl create serviceaccount "$SA_NAME" -n "$NAMESPACE" --dry-run=client -o yaml > "$SEC_DIR/service-account.yaml"

kubectl create secret docker-registry docker-hub-creds \
  --docker-username="$DOCKER_USER" --docker-password="$DOCKER_PASS" \
  --docker-server="https://index.docker.io/v1/" \
  --dry-run=client -o yaml | kubeseal --format=yaml > "$SEC_DIR/docker-hub-sealed.yaml"

kubectl create secret generic git-creds \
  --from-literal=username="$GIT_USER" --from-literal=password="$GIT_TOKEN" \
  --type=kubernetes.io/basic-auth \
  --dry-run=client -o yaml | kubeseal --format=yaml > "$SEC_DIR/git-creds-sealed.yaml"

# ==============================================================================
# PHASE 5: APPLY & PATCH
# ==============================================================================

echo_info "Applying resources..."
kubectl apply -f "$INFRA_DIR/"
kubectl apply -f "$SEC_DIR/"
kubectl apply -f "$TASK_DIR/"

# Install Official Tasks
tkn hub install task git-clone -n "$NAMESPACE"
tkn hub install task buildah -n "$NAMESPACE"

# Critical Buildah Patch
kubectl patch task buildah -n "$NAMESPACE" --type='json' -p='[{"op": "add", "path": "/spec/steps/0/securityContext", "value": {"privileged": true}}]'

# Final Permissions and Linking
sleep 10 # Wait for Sealing
kubectl annotate secret docker-hub-creds -n "$NAMESPACE" --overwrite tekton.dev/docker-0=https://index.docker.io/v1/
kubectl annotate secret git-creds -n "$NAMESPACE" --overwrite tekton.dev/git-0=https://github.com
kubectl label namespace "$NAMESPACE" pod-security.kubernetes.io/enforce=privileged --overwrite
kubectl create rolebinding "${SA_NAME}-edit" --clusterrole=edit --serviceaccount="${NAMESPACE}:${SA_NAME}" -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl patch serviceaccount "$SA_NAME" -n "$NAMESPACE" -p "{\"secrets\": [{\"name\": \"docker-hub-creds\"}, {\"name\": \"git-creds\"}]}"

# ==============================================================================
# PHASE 6: UI AUTO-LAUNCHER
# ==============================================================================

echo "------------------------------------------------------------"
echo_success "BOOTSTRAP COMPLETE!"
echo_info "Blueprints organized in: $BASE_DIR"

if [[ "$INSTALL_UI" =~ ^[Yy]$ ]]; then
    echo_info "Launching Tekton Dashboard tunnel in the background..."
    
    # Port-forward in background
    kubectl port-forward -n tekton-pipelines service/tekton-dashboard 9097:8080 > /dev/null 2>&1 &
    UI_PID=$!
    
    sleep 3
    URL="http://localhost:9097"
    
    # OS-Specific Browser Open
    if command -v xdg-open > /dev/null; then xdg-open "$URL";
    elif command -v open > /dev/null; then open "$URL";
    elif command -v start > /dev/null; then start "$URL";
    fi
    
    echo_success "Dashboard tunnel running (PID: $UI_PID)"
    echo_info "Access it at: $URL"
    echo "To stop the tunnel later, run: kill $UI_PID"
fi

echo "------------------------------------------------------------"
