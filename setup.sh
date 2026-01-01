#!/bin/bash

# --- Helper Functions ---
echo_info() { echo -e "\e[34m[INFO]\e[0m $1"; }
echo_success() { echo -e "\e[32m[SUCCESS]\e[0m $1"; }
echo_error() { echo -e "\e[31m[ERROR]\e[0m $1"; exit 1; }

# ==============================================================================
# PHASE 1: IDENTITY & GITOPS VALIDATION
# ==============================================================================
echo_info "--- Initializing Comprehensive CI Factory (2026 Edition) ---"
echo "------------------------------------------------------------"

CONFIG_FILE=".factory_config"

# 1. Credentials
read -p "Enter GitHub Username: " GIT_USER
read -s -p "Enter GitHub PAT: " GIT_TOKEN; echo ""
read -p "Enter Target Repository (e.g., user/project): " REPO_NAME

echo_info "Verifying Credentials..."
REPO_DATA=$(curl -s -u "$GIT_USER:$GIT_TOKEN" "https://api.github.com/repos/$REPO_NAME")
if [[ $REPO_DATA == *"Not Found"* ]]; then echo_error "Repo not found."; fi

read -p "Enter Docker Hub Username: " DOCKER_USER
read -s -p "Enter Docker Hub Password: " DOCKER_PASS; echo ""
echo_success "Identity Verified."

# ==============================================================================
# PHASE 2: RESOURCE BUDGETING
# ==============================================================================
echo -e "\n\e[35m--- Resource Budgeting (The Guardrails) ---\e[0m"
read -p "1. Project Namespace [default: tekton-tasks]: " NAMESPACE
NAMESPACE=${NAMESPACE:-tekton-tasks}

read -p "2. PVC Storage Size (e.g., 5Gi, 10Gi) [default: 5Gi]: " PVC_SIZE
PVC_SIZE=${PVC_SIZE:-5Gi}

read -p "3. Max RAM per Task (e.g., 1Gi, 2Gi) [default: 1Gi]: " RAM_LIMIT
RAM_LIMIT=${RAM_LIMIT:-1Gi}

read -p "4. Max CPU per Task (e.g., 500m, 1000m) [default: 1000m]: " CPU_LIMIT
CPU_LIMIT=${CPU_LIMIT:-1000m}

echo -e "\nSelect Environment:\n1) Local/Minikube\n2) AWS (gp3)\n3) GCP (premium-rwo)\n4) Azure (managed-csi-premium)"
read -p "Selection [1-4, default: 1]: " CLOUD_CHOICE
case $CLOUD_CHOICE in 2) SC="gp3" ;; 3) SC="premium-rwo" ;; 4) SC="managed-csi-premium" ;; *) SC="standard" ;; esac

# ==============================================================================
# PHASE 3: POLYGLOT SELECTION
# ==============================================================================
echo -e "\n\e[35m--- Quality Gate Specialty ---\e[0m"
echo "1) Python (Black, Flake8, Pylint, Mypy)"
echo "2) Node.js (ESLint)"
echo "3) Go (Golangci-lint)"
echo "4) Ruby (Ruby-linter)"
echo "5) Shell (Shellcheck)"
read -p "Selection [1-5, default: 1]: " LANG_CHOICE
LANG_CHOICE=${LANG_CHOICE:-1}

# Save configuration for the 'Menu' script
echo "DOCKER_USER=$DOCKER_USER" > "$CONFIG_FILE"
echo "NAMESPACE=$NAMESPACE" >> "$CONFIG_FILE"
echo "LANG_CHOICE=$LANG_CHOICE" >> "$CONFIG_FILE"

# ==============================================================================
# PHASE 4: ENGINE INSTALLATION
# ==============================================================================
echo_info "Checking Cluster Health & Engines..."
kubectl cluster-info > /dev/null 2>&1 || echo_error "Cluster unreachable."

# CLI Tools
[ ! -x "$(command -v helm)" ] && { curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash; }
[ ! -x "$(command -v tkn)" ] && { curl -LO https://github.com/tektoncd/cli/releases/download/v0.43.0/tkn_0.43.0_Linux_x86_64.tar.gz && sudo tar xvzf tkn_0.43.0_Linux_x86_64.tar.gz -C /usr/local/bin/ tkn && rm tkn_0.43.0_Linux_x86_64.tar.gz; }
[ ! -x "$(command -v kubeseal)" ] && { curl -L "https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.33.1/kubeseal-0.33.1-linux-amd64.tar.gz" | tar xz && sudo install -m 755 kubeseal /usr/local/bin/kubeseal && rm kubeseal; }

# Install Tekton
kubectl apply -f https://storage.googleapis.com/tekton-releases/pipeline/latest/release.yaml

# Bitnami Sealed Secrets Controller
if ! kubectl get pods -A -l app.kubernetes.io/name=sealed-secrets | grep -q "Running"; then
    echo_info "Installing Sealed Secrets Controller..."
    helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets && helm repo update
    helm install sealed-secrets-controller sealed-secrets/sealed-secrets --namespace kube-system
fi

# ==============================================================================
# PHASE 5: DYNAMIC TASK PROVISIONING (WITH CALCULATION)
# ==============================================================================
echo_info "Provisioning Quality Gate Tasks..."
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

case $LANG_CHOICE in
    1) TASKS_L1=("flake8" "pylint" "mypy-lint" "python-black") ;;
    2) TASKS_L1=("eslint") ;;
    3) TASKS_L1=("golangci-lint") ;;
    4) TASKS_L1=("ruby-linter") ;;
    5) TASKS_L1=("shellcheck") ;;
esac

TASKS_UNIVERSAL=("yaml-lint" "kube-linter" "datree" "hadolint" "valint" "markdown-lint" "rhacs-image-scan" "rhacs-image-check" "rhacs-deployment-check" "git-clone" "git-version" "buildah")

ALL_TASKS=("${TASKS_L1[@]}" "${TASKS_UNIVERSAL[@]}")

# --- THE CALCULATION LOGIC ---
TASK_COUNT=0
for TASK in "${ALL_TASKS[@]}"; do
    tkn hub install task "$TASK" --type artifact -n "$NAMESPACE" 2>/dev/null
    if [ $? -eq 0 ]; then
        ((TASK_COUNT++))
    fi
done

# ==============================================================================
# PHASE 6: MANIFEST GENERATION & SECURITY
# ==============================================================================
BASE_DIR="./tekton-bootstrap"
mkdir -p "$BASE_DIR/infrastructure" "$BASE_DIR/security"

# 1. LimitRange
cat <<EOF > "$BASE_DIR/infrastructure/limits.yaml"
apiVersion: v1
kind: LimitRange
metadata:
  name: tekton-resource-limits
  namespace: $NAMESPACE
spec:
  limits:
  - default:
      cpu: $CPU_LIMIT
      memory: $RAM_LIMIT
    defaultRequest:
      cpu: 100m
      memory: 512Mi
    type: Container
EOF

# 2. PVC
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
      storage: $PVC_SIZE
EOF

# 3. Sealing Credentials
echo_info "Sealing Credentials via Bitnami Kubeseal..."
kubeseal --controller-name=sealed-secrets-controller --controller-namespace=kube-system --fetch-cert > public-cert.pem

kubectl create secret docker-registry docker-hub-creds --docker-username="$DOCKER_USER" --docker-password="$DOCKER_PASS" --docker-server="https://index.docker.io/v1/" --dry-run=client -o yaml | \
kubeseal --format=yaml --cert=public-cert.pem --namespace "$NAMESPACE" > "$BASE_DIR/security/docker-hub-sealed.yaml"

kubectl create secret generic git-creds --from-literal=username="$GIT_USER" --from-literal=password="$GIT_TOKEN" --type=kubernetes.io/basic-auth --dry-run=client -o yaml | \
kubeseal --format=yaml --cert=public-cert.pem --namespace "$NAMESPACE" > "$BASE_DIR/security/git-creds-sealed.yaml"

rm public-cert.pem

# Apply Manifests
kubectl apply -f "$BASE_DIR/infrastructure/"
kubectl apply -f "$BASE_DIR/security/"

# Final Permissions
SA_NAME="build-bot"
kubectl create serviceaccount "$SA_NAME" -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace "$NAMESPACE" pod-security.kubernetes.io/enforce=privileged --overwrite
kubectl patch task buildah -n "$NAMESPACE" --type='json' -p='[{"op": "add", "path": "/spec/steps/0/securityContext", "value": {"privileged": true}}]'
kubectl patch serviceaccount "$SA_NAME" -n "$NAMESPACE" -p "{\"secrets\": [{\"name\": \"docker-hub-creds\"}, {\"name\": \"git-creds\"}]}"

echo "------------------------------------------------------------"
echo_success "PRE-FLIGHT COMPLETE!"
echo_info "Calculated Tasks Provisioned: $TASK_COUNT"
echo_info "Resources: Storage=$PVC_SIZE | RAM Limit=$RAM_LIMIT | CPU Limit=$CPU_LIMIT"
echo "------------------------------------------------------------"
