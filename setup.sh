#!/bin/bash

# --- Helper Functions ---
echo_info() { echo -e "\e[34m[INFO]\e[0m $1"; }
echo_success() { echo -e "\e[32m[SUCCESS]\e[0m $1"; }
echo_error() { echo -e "\e[31m[ERROR]\e[0m $1"; exit 1; }

# ==============================================================================
# PHASE 1: GITOPS & CREDENTIAL VALIDATION (FAIL-FAST)
# ==============================================================================
echo_info "--- Initializing GitOps-Ready CI Factory ---"
echo "------------------------------------------------------------"

CONFIG_FILE=".factory_config"

# 1. GitHub Check (Validation of Identity + Repo Write Access)
read -p "Enter GitHub Username: " GIT_USER
read -s -p "Enter GitHub PAT: " GIT_TOKEN; echo ""
read -p "Enter Target Repository (e.g., username/project): " REPO_NAME

echo_info "Verifying GitHub Access & Write Permissions..."
# Fetching repo metadata to check 'permissions' object
REPO_DATA=$(curl -s -u "$GIT_USER:$GIT_TOKEN" "https://api.github.com/repos/$REPO_NAME")
CAN_PUSH=$(echo "$REPO_DATA" | grep -o '"push": true')

if [[ -z "$REPO_DATA" || "$REPO_DATA" == *"Not Found"* ]]; then
    echo_error "Repository not found or Access Denied. Check your Token/Repo name."
elif [[ -z "$CAN_PUSH" ]]; then
    echo_error "You have READ access, but GITOPS requires WRITE access to update manifests/tags. Check PAT scopes."
else
    echo_success "GitHub Verified: Full Write Access detected for $REPO_NAME."
fi

# 2. Docker Hub Check
read -p "Enter Docker Hub Username: " DOCKER_USER
read -s -p "Enter Docker Hub Password: " DOCKER_PASS; echo ""
echo_info "Verifying Docker Hub Credentials..."
DOCKER_CHECK=$(curl -s -H "Content-Type: application/json" -X POST -d '{"username": "'${DOCKER_USER}'", "password": "'${DOCKER_PASS}'"}' https://hub.docker.com/v2/users/login/)
if [[ $DOCKER_CHECK == *"detail"* ]]; then
    echo_error "Docker Hub Authentication failed."
fi
echo_success "Docker Hub Verified."

# 3. Environment Config
read -p "Enter Namespace [default: tekton-tasks]: " NAMESPACE
NAMESPACE=${NAMESPACE:-tekton-tasks}
read -p "Enter Service Account name [default: build-bot]: " SA_NAME
SA_NAME=${SA_NAME:-build-bot}

# Save context for future Pipeline steps
echo "DOCKER_USER=$DOCKER_USER" > "$CONFIG_FILE"
echo "NAMESPACE=$NAMESPACE" >> "$CONFIG_FILE"
echo "SA_NAME=$SA_NAME" >> "$CONFIG_FILE"
echo "REPO_NAME=$REPO_NAME" >> "$CONFIG_FILE"

read -p "Install and Auto-Open Tekton UI? (y/n) [default: n]: " INSTALL_UI
INSTALL_UI=${INSTALL_UI:-n}

echo -e "\nSelect Environment:\n1) Local/Minikube/Codespace\n2) AWS (gp3)\n3) GCP (premium-rwo)\n4) Azure (managed-csi-premium)"
read -p "Selection [1-4, default: 1]: " CLOUD_CHOICE
case $CLOUD_CHOICE in
    2) SC="gp3" ;; 3) SC="premium-rwo" ;; 4) SC="managed-csi-premium" ;; *) SC="standard" ;;
esac

# ==============================================================================
# PHASE 2: STRUCTURED FOLDER SETUP
# ==============================================================================
BASE_DIR="./tekton-bootstrap"
INFRA_DIR="$BASE_DIR/infrastructure"
TASK_DIR="$BASE_DIR/tasks"
SEC_DIR="$BASE_DIR/security"
mkdir -p "$INFRA_DIR" "$TASK_DIR" "$SEC_DIR"

# ==============================================================================
# PHASE 3: CONTROLLER & TOOL INSTALLATION
# ==============================================================================
kubectl cluster-info > /dev/null 2>&1 || echo_error "Cluster unreachable."

# Install Tools
[ ! -x "$(command -v helm)" ] && { echo_info "Installing Helm..."; curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash; }
[ ! -x "$(command -v tkn)" ] && { echo_info "Installing Tekton CLI..."; curl -LO https://github.com/tektoncd/cli/releases/download/v0.43.0/tkn_0.43.0_Linux_x86_64.tar.gz && sudo tar xvzf tkn_0.43.0_Linux_x86_64.tar.gz -C /usr/local/bin/ tkn && rm tkn_0.43.0_Linux_x86_64.tar.gz; }
[ ! -x "$(command -v kubeseal)" ] && { echo_info "Installing kubeseal..."; curl -L "https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.33.1/kubeseal-0.33.1-linux-amd64.tar.gz" | tar xz && sudo install -m 755 kubeseal /usr/local/bin/kubeseal && rm kubeseal; }

# Install Tekton & Dashboard
if ! kubectl get namespace tekton-pipelines &> /dev/null; then
    echo_info "Installing Tekton..."
    kubectl apply -f https://storage.googleapis.com/tekton-releases/pipeline/latest/release.yaml
    kubectl wait --for=condition=Available deployment/tekton-pipelines-controller -n tekton-pipelines --timeout=180s
fi

if [[ "$INSTALL_UI" =~ ^[Yy]$ ]]; then
    echo_info "Installing Dashboard..."
    kubectl apply -f https://storage.googleapis.com/tekton-releases/dashboard/latest/release.yaml
    kubectl wait --for=condition=Available deployment/tekton-dashboard -n tekton-pipelines --timeout=120s
fi

# Sealed Secrets
if ! kubectl get pods -A -l app.kubernetes.io/name=sealed-secrets | grep -q "Running"; then
    echo_info "Installing Sealed Secrets..."
    helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets && helm repo update
    helm install sealed-secrets-controller sealed-secrets/sealed-secrets --namespace kube-system
    kubectl rollout status deployment/sealed-secrets-controller -n kube-system --timeout=120s
fi

# ==============================================================================
# PHASE 4: MANIFEST GENERATION & APPLICATION
# ==============================================================================
echo_info "Generating organized manifests..."

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
      storage: 5Gi
EOF

# 2. Cleanup Task
cat <<EOF > "$TASK_DIR/cleanup-workspace.yaml"
apiVersion: tekton.dev/v1beta1
kind: Task
metadata:
  name: cleanup-workspace
  namespace: $NAMESPACE
spec:
  workspaces: [{name: source}]
  steps:
    - name: clean
      image: alpine
      script: |
        echo "Cleaning source workspace..."
        rm -rf /workspace/source/*
EOF

# 3. Security (Sealing Validated Credentials)
echo_info "Fetching current Sealed Secrets certificate..."
kubeseal --controller-name=sealed-secrets-controller --controller-namespace=kube-system --fetch-cert > public-cert.pem

kubectl create serviceaccount "$SA_NAME" -n "$NAMESPACE" --dry-run=client -o yaml > "$SEC_DIR/service-account.yaml"

kubectl create secret docker-registry docker-hub-creds --docker-username="$DOCKER_USER" --docker-password="$DOCKER_PASS" --docker-server="https://index.docker.io/v1/" --dry-run=client -o yaml | \
kubeseal --format=yaml --cert=public-cert.pem --namespace "$NAMESPACE" > "$SEC_DIR/docker-hub-sealed.yaml"

kubectl create secret generic git-creds --from-literal=username="$GIT_USER" --from-literal=password="$GIT_TOKEN" --type=kubernetes.io/basic-auth --dry-run=client -o yaml | \
kubeseal --format=yaml --cert=public-cert.pem --namespace "$NAMESPACE" > "$SEC_DIR/git-creds-sealed.yaml"

rm public-cert.pem

# Apply Manifests
kubectl apply -f "$INFRA_DIR/"
kubectl apply -f "$SEC_DIR/"
kubectl apply -f "$TASK_DIR/"

# Install Hub Tasks (The Versioning Toolbox)
echo_info "Installing Tekton Hub Tasks..."
tkn hub install task git-clone -n "$NAMESPACE" 2>/dev/null
tkn hub install task git-version -n "$NAMESPACE" 2>/dev/null
tkn hub install task buildah -n "$NAMESPACE" 2>/dev/null

# Patches for Buildah & Security
kubectl patch task buildah -n "$NAMESPACE" --type='json' -p='[{"op": "add", "path": "/spec/steps/0/securityContext", "value": {"privileged": true}}]'

# Wait for decryption logic
echo_info "Waiting for Secrets to decrypt..."
for i in {1..12}; do
    if kubectl get secret docker-hub-creds -n "$NAMESPACE" &>/dev/null; then
        echo_success "Secrets ready."
        break
    fi
    echo -n "."
    sleep 5
done

kubectl annotate secret docker-hub-creds -n "$NAMESPACE" --overwrite tekton.dev/docker-0=https://index.docker.io/v1/
kubectl annotate secret git-creds -n "$NAMESPACE" --overwrite tekton.dev/git-0=https://github.com
kubectl label namespace "$NAMESPACE" pod-security.kubernetes.io/enforce=privileged --overwrite
kubectl create rolebinding "${SA_NAME}-edit" --clusterrole=edit --serviceaccount="${NAMESPACE}:${SA_NAME}" -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl patch serviceaccount "$SA_NAME" -n "$NAMESPACE" -p "{\"secrets\": [{\"name\": \"docker-hub-creds\"}, {\"name\": \"git-creds\"}]}"

# ==============================================================================
# PHASE 5: UI AUTO-LAUNCH
# ==============================================================================
echo "------------------------------------------------------------"
echo_success "BOOTSTRAP COMPLETE!"
echo_info "Versioning Task: Ready"
echo_info "GitOps Write-Access: Verified"

if [[ "$INSTALL_UI" =~ ^[Yy]$ ]]; then
    kubectl port-forward -n tekton-pipelines service/tekton-dashboard 9097:8080 --address 0.0.0.0 > /dev/null 2>&1 &
    UI_PID=$!
    sleep 3
    echo_info "Dashboard Port 9097 (PID: $UI_PID)"
fi
echo "------------------------------------------------------------"
