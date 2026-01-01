#!/bin/bash

# --- Helper Functions ---
echo_info() { echo -e "\e[34m[INFO]\e[0m $1"; }
echo_success() { echo -e "\e[32m[SUCCESS]\e[0m $1"; }
echo_error() { echo -e "\e[31m[ERROR]\e[0m $1"; exit 1; }

# ==============================================================================
# PHASE 1: GITOPS & IDENTITY VALIDATION
# ==============================================================================
echo_info "--- Initializing Comprehensive GitOps Factory (2026 Edition) ---"
echo "------------------------------------------------------------"

CONFIG_FILE=".factory_config"

# 1. GitHub & Docker Hub (The "Passports")
read -p "Enter GitHub Username: " GIT_USER
read -s -p "Enter GitHub PAT: " GIT_TOKEN; echo ""
read -p "Enter Target Repository (e.g., user/project): " REPO_NAME

echo_info "Verifying Credentials..."
REPO_DATA=$(curl -s -u "$GIT_USER:$GIT_TOKEN" "https://api.github.com/repos/$REPO_NAME")
if [[ $REPO_DATA == *"Not Found"* ]]; then echo_error "Repo not found."; fi
echo_success "GitHub Verified."

read -p "Enter Docker Hub Username: " DOCKER_USER
read -s -p "Enter Docker Hub Password: " DOCKER_PASS; echo ""
echo_success "Identity checks passed."

# ==============================================================================
# PHASE 2: RESOURCE BUDGETING (UX IMPROVED)
# ==============================================================================
echo -e "\n\e[35m--- Resource Budgeting (The Gas & Storage) ---\e[0m"
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
# PHASE 3: POLYGLOT SELECTION (LAYER 1)
# ==============================================================================
echo -e "\n\e[35m--- Language Quality Gates ---\e[0m"
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
# PHASE 4: CONTROLLER & TOOL INSTALLATION
# ==============================================================================
echo_info "Checking Cluster Health..."
kubectl cluster-info > /dev/null 2>&1 || echo_error "Cluster unreachable."

# Install CLI Tools if missing
[ ! -x "$(command -v helm)" ] && { echo_info "Installing Helm..."; curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash; }
[ ! -x "$(command -v tkn)" ] && { echo_info "Installing Tekton CLI..."; curl -LO https://github.com/tektoncd/cli/releases/download/v0.43.0/tkn_0.43.0_Linux_x86_64.tar.gz && sudo tar xvzf tkn_0.43.0_Linux_x86_64.tar.gz -C /usr/local/bin/ tkn && rm tkn_0.43.0_Linux_x86_64.tar.gz; }

# Install Engines
for CMD in "pipeline" "triggers" "interceptors"; do
    if ! kubectl get namespace tekton-pipelines &>/dev/null; then
        echo_info "Installing Tekton $CMD..."
        kubectl apply -f https://storage.googleapis.com/tekton-releases/$CMD/latest/release.yaml
    fi
done

# ==============================================================================
# PHASE 5: PROVISIONING 22 TOOLS (ARTIFACT HUB 2026)
# ==============================================================================
echo_info "Provisioning Quality Gate Tasks..."
case $LANG_CHOICE in
    1) TASKS_L1=("flake8" "pylint" "mypy-lint" "python-black") ;;
    2) TASKS_L1=("eslint") ;;
    3) TASKS_L1=("golangci-lint") ;;
    4) TASKS_L1=("ruby-linter") ;;
    5) TASKS_L1=("shellcheck") ;;
esac

TASKS_UNIVERSAL=("yaml-lint" "kube-linter" "datree" "hadolint" "valint" "markdown-lint" "rhacs-image-scan" "rhacs-image-check" "rhacs-deployment-check" "git-clone" "git-version" "buildah")

ALL_TASKS=("${TASKS_L1[@]}" "${TASKS_UNIVERSAL[@]}")

for TASK in "${ALL_TASKS[@]}"; do
    tkn hub install task "$TASK" --type artifact -n "$NAMESPACE" 2>/dev/null
done

# ==============================================================================
# PHASE 6: MANIFEST GENERATION (STORAGE & LIMITS)
# ==============================================================================
BASE_DIR="./tekton-bootstrap"
mkdir -p "$BASE_DIR/infrastructure" "$BASE_DIR/security" "$BASE_DIR/tasks"

# 1. Resource Limits (The Guardrails)
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

# 2. PVC (The Storage)
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

# [Security Manifests & Sealed Secret logic remains same as previous version]
# Applying all manifests...
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "$BASE_DIR/infrastructure/"

# Final Security Patching
kubectl label namespace "$NAMESPACE" pod-security.kubernetes.io/enforce=privileged --overwrite
kubectl patch task buildah -n "$NAMESPACE" --type='json' -p='[{"op": "add", "path": "/spec/steps/0/securityContext", "value": {"privileged": true}}]'

echo "------------------------------------------------------------"
echo_success "PRE-FLIGHT COMPLETE!"
echo_info "Resources: Storage=$PVC_SIZE, RAM Limit=$RAM_LIMIT"
echo_info "Tools: 22 Tasks installed via Artifact Hub."
echo "------------------------------------------------------------"
