#!/bin/bash

# --- Helper Functions ---
echo_info() { echo -e "\e[34m[INFO]\e[0m $1"; }
echo_success() { echo -e "\e[32m[SUCCESS]\e[0m $1"; }
echo_error() { echo -e "\e[31m[ERROR]\e[0m $1"; exit 1; }

# ==============================================================================
# PHASE 1: GITOPS & CREDENTIAL VALIDATION (FAIL-FAST)
# ==============================================================================
echo_info "--- Initializing Comprehensive GitOps Factory (2026 Edition) ---"
echo "------------------------------------------------------------"

CONFIG_FILE=".factory_config"

# 1. GitHub Check
read -p "Enter GitHub Username: " GIT_USER
read -s -p "Enter GitHub PAT: " GIT_TOKEN; echo ""
read -p "Enter Target Repository (e.g., username/project): " REPO_NAME

echo_info "Verifying GitHub Access & Write Permissions..."
REPO_DATA=$(curl -s -u "$GIT_USER:$GIT_TOKEN" "https://api.github.com/repos/$REPO_NAME")
CAN_PUSH=$(echo "$REPO_DATA" | grep -o '"push": true')

if [[ -z "$REPO_DATA" || "$REPO_DATA" == *"Not Found"* ]]; then
    echo_error "Repository not found or Access Denied. Check your Token/Repo name."
elif [[ -z "$CAN_PUSH" ]]; then
    echo_error "You have READ access, but GITOPS requires WRITE access. Check PAT scopes."
else
    echo_success "GitHub Verified: Full Write Access detected."
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

# 3. Polyglot Language Selection (Layer 1)
echo -e "\nSelect Primary Language for Layer 1 Quality Gates:"
echo "1) Python    (Black, Flake8, Pylint, Mypy)"
echo "2) Node.js   (ESLint)"
echo "3) Go        (Golangci-lint)"
echo "4) Ruby      (Ruby-linter)"
echo "5) Shell     (Shellcheck)"
read -p "Selection [1-5, default: 1]: " LANG_CHOICE
LANG_CHOICE=${LANG_CHOICE:-1}

# 4. Environment Config
read -p "Enter Namespace [default: tekton-tasks]: " NAMESPACE
NAMESPACE=${NAMESPACE:-tekton-tasks}
read -p "Enter Service Account name [default: build-bot]: " SA_NAME
SA_NAME=${SA_NAME:-build-bot}

echo -e "\nSelect Environment:\n1) Local/Minikube\n2) AWS (gp3)\n3) GCP (premium-rwo)\n4) Azure (managed-csi-premium)"
read -p "Selection [1-4, default: 1]: " CLOUD_CHOICE
case $CLOUD_CHOICE in
    2) SC="gp3" ;; 3) SC="premium-rwo" ;; 4) SC="managed-csi-premium" ;; *) SC="standard" ;;
esac

# Save context
echo "DOCKER_USER=$DOCKER_USER" > "$CONFIG_FILE"
echo "NAMESPACE=$NAMESPACE" >> "$CONFIG_FILE"
echo "LANG_CHOICE=$LANG_CHOICE" >> "$CONFIG_FILE"

# ==============================================================================
# PHASE 2: STRUCTURED FOLDER SETUP
# ==============================================================================
BASE_DIR="./tekton-bootstrap"
mkdir -p "$BASE_DIR/infrastructure" "$BASE_DIR/tasks" "$BASE_DIR/security"

# ==============================================================================
# PHASE 3: CONTROLLER & TOOL INSTALLATION
# ==============================================================================
kubectl cluster-info > /dev/null 2>&1 || echo_error "Cluster unreachable."

# Install CLI Tools
[ ! -x "$(command -v helm)" ] && { echo_info "Installing Helm..."; curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash; }
[ ! -x "$(command -v tkn)" ] && { echo_info "Installing Tekton CLI..."; curl -LO https://github.com/tektoncd/cli/releases/download/v0.43.0/tkn_0.43.0_Linux_x86_64.tar.gz && sudo tar xvzf tkn_0.43.0_Linux_x86_64.tar.gz -C /usr/local/bin/ tkn && rm tkn_0.43.0_Linux_x86_64.tar.gz; }
[ ! -x "$(command -v kubeseal)" ] && { echo_info "Installing kubeseal..."; curl -L "https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.33.1/kubeseal-0.33.1-linux-amd64.tar.gz" | tar xz && sudo install -m 755 kubeseal /usr/local/bin/kubeseal && rm kubeseal; }

# Install Tekton Core
if ! kubectl get namespace tekton-pipelines &> /dev/null; then
    echo_info "Installing Tekton Pipeline Engine..."
    kubectl apply -f https://storage.googleapis.com/tekton-releases/pipeline/latest/release.yaml
    kubectl wait --for=condition=Available deployment/tekton-pipelines-controller -n tekton-pipelines --timeout=180s
fi

# Sealed Secrets Controller
if ! kubectl get pods -A -l app.kubernetes.io/name=sealed-secrets | grep -q "Running"; then
    echo_info "Installing Sealed Secrets Controller..."
    helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets && helm repo update
    helm install sealed-secrets-controller sealed-secrets/sealed-secrets --namespace kube-system
    kubectl rollout status deployment/sealed-secrets-controller -n kube-system --timeout=120s
fi

# ==============================================================================
# PHASE 4: QUALITY GATE PROVISIONING (ARTIFACT HUB 2026)
# ==============================================================================
echo_info "Provisioning 5-Layer Quality Gates from Artifact Hub..."

# Layer 1: Language Specific
case $LANG_CHOICE in
    1) TASKS_L1=("flake8" "pylint" "mypy-lint" "python-black") ;;
    2) TASKS_L1=("eslint") ;;
    3) TASKS_L1=("golangci-lint") ;;
    4) TASKS_L1=("ruby-linter") ;;
    5) TASKS_L1=("shellcheck") ;;
esac

# Layers 2-5: Universal Factory Tools
TASKS_INFRA=("yaml-lint" "kube-linter" "datree")
TASKS_PKG=("hadolint" "valint")
TASKS_MAINT=("markdown-lint")
TASKS_SEC=("rhacs-image-scan" "rhacs-image-check" "rhacs-deployment-check")
TASKS_CORE=("git-clone" "git-version" "buildah")

ALL_TASKS=("${TASKS_L1[@]}" "${TASKS_INFRA[@]}" "${TASKS_PKG[@]}" "${TASKS_MAINT[@]}" "${TASKS_SEC[@]}" "${TASKS_CORE[@]}")

# Use the --type artifact flag to bypass deprecated Tekton Hub
for TASK in "${ALL_TASKS[@]}"; do
    echo_info "Installing Task: $TASK"
    tkn hub install task "$TASK" --type artifact -n "$NAMESPACE" 2>/dev/null
done

# ==============================================================================
# PHASE 5: MANIFESTS & SECURITY MAPPING
# ==============================================================================
echo_info "Generating Security Manifests..."

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml > "$BASE_DIR/namespace.yaml"
kubectl apply -f "$BASE_DIR/namespace.yaml"

# 1. Infrastructure (PVC)
cat <<EOF > "$BASE_DIR/infrastructure/pvc.yaml"
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
cat <<EOF > "$BASE_DIR/tasks/cleanup-workspace.yaml"
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
      script: rm -rf /workspace/source/*
EOF

# 3. Sealed Secrets Logic
echo_info "Sealing Credentials..."
kubeseal --controller-name=sealed-secrets-controller --controller-namespace=kube-system --fetch-cert > public-cert.pem

kubectl create serviceaccount "$SA_NAME" -n "$NAMESPACE" --dry-run=client -o yaml > "$BASE_DIR/security/service-account.yaml"

kubectl create secret docker-registry docker-hub-creds --docker-username="$DOCKER_USER" --docker-password="$DOCKER_PASS" --docker-server="https://index.docker.io/v1/" --dry-run=client -o yaml | \
kubeseal --format=yaml --cert=public-cert.pem --namespace "$NAMESPACE" > "$BASE_DIR/security/docker-hub-sealed.yaml"

kubectl create secret generic git-creds --from-literal=username="$GIT_USER" --from-literal=password="$GIT_TOKEN" --type=kubernetes.io/basic-auth --dry-run=client -o yaml | \
kubeseal --format=yaml --cert=public-cert.pem --namespace "$NAMESPACE" > "$BASE_DIR/security/git-creds-sealed.yaml"

rm public-cert.pem

# Apply all generated manifests
kubectl apply -f "$BASE_DIR/infrastructure/"
kubectl apply -f "$BASE_DIR/security/"
kubectl apply -f "$BASE_DIR/tasks/"

# Patching for Buildah Privilege (Required for K8s)
kubectl patch task buildah -n "$NAMESPACE" --type='json' -p='[{"op": "add", "path": "/spec/steps/0/securityContext", "value": {"privileged": true}}]'

# Service Account Wiring
kubectl annotate secret docker-hub-creds -n "$NAMESPACE" --overwrite tekton.dev/docker-0=https://index.docker.io/v1/
kubectl annotate secret git-creds -n "$NAMESPACE" --overwrite tekton.dev/git-0=https://github.com
kubectl create rolebinding "${SA_NAME}-edit" --clusterrole=edit --serviceaccount="${NAMESPACE}:${SA_NAME}" -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl patch serviceaccount "$SA_NAME" -n "$NAMESPACE" -p "{\"secrets\": [{\"name\": \"docker-hub-creds\"}, {\"name\": \"git-creds\"}]}"

echo "------------------------------------------------------------"
echo_success "COMPREHENSIVE FACTORY BOOTSTRAP COMPLETE!"
echo_info "All 5 Layers of Linters & Security tools are ready."
echo_info "Secrets are sealed and decryping in $NAMESPACE."
echo "------------------------------------------------------------"
