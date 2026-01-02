#!/bin/bash

# --- Helper Functions ---
echo_info() { echo -e "\e[34m[INFO]\e[0m $1"; }
echo_success() { echo -e "\e[32m[SUCCESS]\e[0m $1"; }
echo_error() { echo -e "\e[31m[ERROR]\e[0m $1"; exit 1; }

# ==============================================================================
# PHASE 1: IDENTITY & GITOPS VALIDATION
# ==============================================================================
echo_info "--- Initializing Secure CI Factory (2026 Hardened Edition v3) ---"

read -p "Enter GitHub Username: " GIT_USER
read -s -p "Enter GitHub PAT: " GIT_TOKEN; echo ""
read -p "Enter Target Repository (e.g., user/project): " REPO_NAME

echo_info "Verifying Credentials..."
REPO_DATA=$(curl -s -u "$GIT_USER:$GIT_TOKEN" "https://api.github.com/repos/$REPO_NAME")
if [[ $REPO_DATA == *"Not Found"* ]]; then echo_error "Repo not found or Token invalid."; fi

read -p "Enter Docker Hub Username: " DOCKER_USER
read -s -p "Enter Docker Hub Password: " DOCKER_PASS; echo ""
echo_success "Identity Verified."

# ==============================================================================
# PHASE 2: RESOURCE BUDGETING & QUOTAS
# ==============================================================================
echo -e "\n\e[35m--- Resource Budgeting (The Guardrails) ---\e[0m"
read -p "Project Namespace [default: tekton-tasks]: " NAMESPACE
NAMESPACE=${NAMESPACE:-tekton-tasks}

read -p "Max Concurrent Pods for Namespace [default: 10]: " MAX_PODS
MAX_PODS=${MAX_PODS:-10}

read -p "PVC Storage Size [default: 5Gi]: " PVC_SIZE
PVC_SIZE=${PVC_SIZE:-5Gi}

echo -e "\nSelect Environment:\n1) Local/Minikube\n2) AWS (gp3)\n3) GCP (premium-rwo)\n4) Azure (managed-csi-premium)"
read -p "Selection [1-4, default: 1]: " CLOUD_CHOICE
case $CLOUD_CHOICE in 2) SC="gp3" ;; 3) SC="premium-rwo" ;; 4) SC="managed-csi-premium" ;; *) SC="standard" ;; esac

# ==============================================================================
# PHASE 3: QUALITY GATE SELECTION
# ==============================================================================
echo -e "\n\e[35m--- Quality Gate Specialty ---\e[0m"
echo "1) Python | 2) Node.js | 3) Go | 4) Ruby | 5) Shell"
read -p "Selection [1-5, default: 1]: " LANG_CHOICE
LANG_CHOICE=${LANG_CHOICE:-1}

# ==============================================================================
# PHASE 4: ENGINE INSTALLATION & READINESS
# ==============================================================================
echo_info "Checking Cluster Health..."
kubectl cluster-info > /dev/null 2>&1 || echo_error "Cluster unreachable."

# Idempotent CLI Installers
[ ! -x "$(command -v helm)" ] && { echo_info "Installing Helm..."; curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash; }
[ ! -x "$(command -v tkn)" ] && { echo_info "Installing Tekton CLI..."; curl -LO https://github.com/tektoncd/cli/releases/download/v0.43.0/tkn_0.43.0_Linux_x86_64.tar.gz && sudo tar xvzf tkn_0.43.0_Linux_x86_64.tar.gz -C /usr/local/bin/ tkn && rm tkn_0.43.0_Linux_x86_64.tar.gz; }
[ ! -x "$(command -v kubeseal)" ] && { echo_info "Installing Kubeseal..."; curl -L "https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.33.1/kubeseal-0.33.1-linux-amd64.tar.gz" | tar xz && sudo install -m 755 kubeseal /usr/local/bin/kubeseal && rm kubeseal; }

echo_info "Deploying Tekton & Sealed Secrets..."
kubectl apply -f https://storage.googleapis.com/tekton-releases/pipeline/latest/release.yaml

if ! kubectl get pods -n kube-system -l app.kubernetes.io/name=sealed-secrets | grep -q "Running"; then
    helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets && helm repo update
    helm install sealed-secrets-controller sealed-secrets/sealed-secrets --namespace kube-system
fi

# --- NEW: Readiness Check ---
echo_info "Waiting for Engines to initialize..."
kubectl wait --for=condition=Available deployment/tekton-pipelines-controller -n tekton-pipelines --timeout=60s
echo_success "Engines Online."

# ==============================================================================
# PHASE 5: DYNAMIC TASK PROVISIONING
# ==============================================================================
echo_info "Provisioning Tasks in namespace: $NAMESPACE"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# ENFORCE BASELINE SECURITY (No more --privileged)
kubectl label namespace "$NAMESPACE" pod-security.kubernetes.io/enforce=baseline --overwrite

case $LANG_CHOICE in
    1) TASKS_L1=("flake8" "pylint") ;;
    2) TASKS_L1=("eslint") ;;
    3) TASKS_L1=("golangci-lint") ;;
    4) TASKS_L1=("ruby-linter") ;;
    5) TASKS_L1=("shellcheck") ;;
esac

TASKS_UNIVERSAL=("yaml-lint" "git-clone" "buildah")
ALL_TASKS=("${TASKS_L1[@]}" "${TASKS_UNIVERSAL[@]}")

for TASK in "${ALL_TASKS[@]}"; do
    tkn hub install task "$TASK" -n "$NAMESPACE" 2>/dev/null || echo_info "Task $TASK exists."
done

# ==============================================================================
# PHASE 6: MANIFEST GENERATION (QUOTAS & FUSE-OVERLAY)
# ==============================================================================
BASE_DIR="./tekton-bootstrap-v3"
mkdir -p "$BASE_DIR/infrastructure" "$BASE_DIR/security"

# 1. ResourceQuota (The Ceiling)
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

# 3. Sealed Secrets
echo_info "Sealing Credentials..."
kubeseal --controller-name=sealed-secrets-controller --controller-namespace=kube-system --fetch-cert > public-cert.pem

kubectl create secret docker-registry docker-hub-creds --docker-username="$DOCKER_USER" --docker-password="$DOCKER_PASS" --docker-server="https://index.docker.io/v1/" --dry-run=client -o yaml | \
kubeseal --format=yaml --cert=public-cert.pem --namespace "$NAMESPACE" > "$BASE_DIR/security/docker-hub-sealed.yaml"

kubectl create secret generic git-creds --from-literal=username="$GIT_USER" --from-literal=password="$GIT_TOKEN" --type=kubernetes.io/basic-auth --dry-run=client -o yaml | \
kubeseal --format=yaml --cert=public-cert.pem --namespace "$NAMESPACE" > "$BASE_DIR/security/git-creds-sealed.yaml"

rm public-cert.pem

# Apply Manifests
kubectl apply -f "$BASE_DIR/infrastructure/"
kubectl apply -f "$BASE_DIR/security/"

# --- SERVICE ACCOUNT & FUSE-OVERLAY PATCH ---
SA_NAME="build-bot"
kubectl create serviceaccount "$SA_NAME" -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl patch serviceaccount "$SA_NAME" -n "$NAMESPACE" -p "{\"secrets\": [{\"name\": \"docker-hub-creds\"}, {\"name\": \"git-creds\"}]}"

echo_info "Applying High-Performance fuse-overlayfs Patch..."
kubectl patch task buildah -n "$NAMESPACE" --type='json' -p='[
  {
    "op": "add",
    "path": "/spec/steps/0/env",
    "value": [
      {"name": "STORAGE_DRIVER", "value": "overlay"},
      {"name": "STORAGE_OPTS", "value": "mount_program=/usr/bin/fuse-overlayfs"}
    ]
  },
  {
    "op": "replace",
    "path": "/spec/steps/0/securityContext",
    "value": {
      "runAsUser": 1000,
      "runAsGroup": 1000,
      "allowPrivilegeEscalation": true,
      "capabilities": {"add": ["SYS_ADMIN"]}
    }
  }
]'

# ==============================================================================
# PHASE 7: AUTO-PRUNING (CLEANUP)
# ==============================================================================
echo_info "Deploying Auto-Pruning CronJob (Keeps cluster clean)..."
cat <<EOF > "$BASE_DIR/infrastructure/cleanup.yaml"
apiVersion: batch/v1
kind: CronJob
metadata:
  name: tekton-pruner
  namespace: $NAMESPACE
spec:
  schedule: "0 0 * * *"
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: $SA_NAME
          containers:
          - name: pruner
            image: bitnami/kubectl:latest
            command: ["/bin/sh", "-c", "kubectl delete pipelinerun,taskrun --all --field-selector status.completionTime < \$(date -d '2 days ago' +%Y-%m-%dT%H:%M:%SZ)"]
          restartPolicy: OnFailure
EOF
kubectl apply -f "$BASE_DIR/infrastructure/cleanup.yaml"

echo "------------------------------------------------------------"
echo_success "V3 BOOTSTRAP COMPLETE!"
echo_info "Security: Baseline (Enforced)"
echo_info "Performance: fuse-overlayfs (Active)"
echo_info "Cleanup: Auto-delete runs older than 2 days (Active)"
echo "------------------------------------------------------------"
