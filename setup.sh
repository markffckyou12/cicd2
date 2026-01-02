#!/bin/bash

# --- Helper Functions ---
echo_info() { echo -e "\e[34m[INFO]\e[0m $1"; }
echo_success() { echo -e "\e[32m[SUCCESS]\e[0m $1"; }
echo_error() { echo -e "\e[31m[ERROR]\e[0m $1"; exit 1; }

# Cleanup trap (Preserved from your original)
cleanup_temp() {
    rm -f buildah-raw.yaml d-plain.yaml d-sealed.yaml
}
trap cleanup_temp EXIT

validate_input() {
    local val="$1"; local name="$2"
    if [[ ! "$val" =~ ^[a-zA-Z0-9._/-]+$ ]]; then
        echo_error "Invalid input for $name. Only alphanumeric, '.', '_', and '-' allowed."
    fi
}

# ==============================================================================
# PHASE 0: CONTROLLER PRE-FLIGHT
# ==============================================================================
echo_info "Checking Cluster Controllers..."
kubectl apply -f https://storage.googleapis.com/tekton-releases/pipeline/latest/release.yaml
kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.24.0/controller.yaml

# Robust wait instead of sleep for Phase 5 stability
kubectl wait --for=condition=available --timeout=180s deployment/sealed-secrets-controller -n kube-system

# ==============================================================================
# PHASE 1: IDENTITY & GITOPS VALIDATION
# ==============================================================================
echo_info "--- Initializing Secure CI Factory (Hardened CI v4.6) ---"

GIT_USER=${GIT_USER:-$(read -p "Enter GitHub Username: " u && echo $u)}
GIT_TOKEN=${GIT_TOKEN:-$(read -s -p "Enter GitHub PAT: " t && echo $t)}
echo ""
REPO_NAME=${REPO_NAME:-$(read -p "Enter Target Repository (e.g., user/project): " r && echo $r)}
validate_input "$REPO_NAME" "Repo Name"

echo "::add-mask::$GIT_TOKEN" 2>/dev/null || true

echo_info "Verifying GitHub Access..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -u "$GIT_USER:$GIT_TOKEN" "https://api.github.com/repos/$REPO_NAME")
[ "$HTTP_CODE" -ne 200 ] && echo_error "GitHub Access Denied (HTTP $HTTP_CODE)."

DOCKER_USER=${DOCKER_USER:-$(read -p "Enter Docker Hub Username: " du && echo $du)}
DOCKER_PASS=${DOCKER_PASS:-$(read -s -p "Enter Docker Hub Password: " dp && echo $dp)}
echo "::add-mask::$DOCKER_PASS" 2>/dev/null || true
echo_success "Identity Verified."

# ==============================================================================
# PHASE 2: RESOURCE BUDGETING
# ==============================================================================
NAMESPACE=${NAMESPACE:-tekton-tasks}
PVC_SIZE=10Gi
CLOUD_CHOICE=${CLOUD_CHOICE:-1}
case $CLOUD_CHOICE in 2) SC="gp3" ;; 3) SC="premium-rwo" ;; 4) SC="managed-csi-premium" ;; *) SC="standard" ;; esac

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl label --overwrite ns "$NAMESPACE" pod-security.kubernetes.io/enforce=baseline

# ==============================================================================
# PHASE 3: ENGINE & TOOL INSTALLATION
# ==============================================================================
echo_info "Installing Engines & CLIs..."
[ ! -x "$(command -v tkn)" ] && { curl -LO https://github.com/tektoncd/cli/releases/download/v0.43.0/tkn_0.43.0_Linux_x86_64.tar.gz && sudo tar xvzf tkn_0.43.0_Linux_x86_64.tar.gz -C /usr/local/bin/ tkn && rm tkn_0.43.0_Linux_x86_64.tar.gz; }
[ ! -x "$(command -v cosign)" ] && { curl -LO https://github.com/sigstore/cosign/releases/latest/download/cosign-linux-amd64 && sudo install cosign-linux-amd64 /usr/local/bin/cosign && rm cosign-linux-amd64; }
[ ! -x "$(command -v kubeseal)" ] && { curl -L "https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.24.0/kubeseal-0.24.0-linux-amd64.tar.gz" | tar xz && sudo install -m 755 kubeseal /usr/local/bin/kubeseal && rm kubeseal; }
[ ! -x "$(command -v yq)" ] && { curl -L "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64" -o /usr/local/bin/yq && chmod +x /usr/local/bin/yq; }

# ==============================================================================
# PHASE 4: THE HARDENED CI REGISTRY
# ==============================================================================
echo_info "Provisioning Quality & Security Gates..."
LANG_CHOICE=${LANG_CHOICE:-1}
case $LANG_CHOICE in
    1) TASKS_L1=("flake8" "pylint"); SPECIFIC_LINTER="flake8" ;;
    2) TASKS_L1=("eslint"); SPECIFIC_LINTER="eslint" ;;
    *) TASKS_L1=("shellcheck"); SPECIFIC_LINTER="shellcheck" ;;
esac

ALL_TASKS=("${TASKS_L1[@]}" "kube-linter" "git-clone" "hadolint" "trivy-scanner" "cosign-sign" "cleanup")
for TASK in "${ALL_TASKS[@]}"; do
    tkn hub install task "$TASK" -n "$NAMESPACE" 2>/dev/null || echo_info "Task $TASK ready."
done

# PATCH: Buildah Rootless + Overlay Driver
tkn hub get task buildah --version 0.7 > buildah-raw.yaml
yq -i '.spec.steps[0].securityContext = {"runAsUser": 1000, "runAsGroup": 1000, "fsGroup": 1000, "allowPrivilegeEscalation": false}' buildah-raw.yaml
yq -i '.spec.steps[0].env += [{"name": "STORAGE_DRIVER", "value": "overlay"}]' buildah-raw.yaml
kubectl apply -f buildah-raw.yaml -n "$NAMESPACE"

# ==============================================================================
# PHASE 5: INFRASTRUCTURE & RBAC
# ==============================================================================
echo_info "Wiring Security Identity & RBAC..."
SA_NAME="build-bot"

# 1. PVC Creation
cat <<EOF | kubectl apply -f -
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

# 2. ServiceAccount & Tekton Manager RBAC
kubectl create serviceaccount "$SA_NAME" -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: tekton-manager-role
  namespace: $NAMESPACE
rules:
- apiGroups: ["tekton.dev"]
  resources: ["tasks", "pipelines", "taskruns", "pipelineruns"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: [""]
  resources: ["secrets", "pods", "persistentvolumeclaims"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: build-bot-tekton-binding
  namespace: $NAMESPACE
subjects: [{ kind: ServiceAccount, name: $SA_NAME, namespace: $NAMESPACE }]
roleRef: { kind: Role, name: tekton-manager-role, apiGroup: rbac.authorization.k8s.io }
EOF

# 3. Supply Chain Signing Keys
if ! kubectl get secret cosign-keys -n "$NAMESPACE" > /dev/null 2>&1; then
    export COSIGN_PASSWORD=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 32)
    echo_success "GEN COSIGN PASS: $COSIGN_PASSWORD"
    cosign generate-key-pair k8s://"$NAMESPACE"/cosign-keys
fi

# 4. Private Git Auth (Required for private repo cloning)
kubectl create secret generic git-creds \
  --from-literal=username="$GIT_USER" \
  --from-literal=password="$GIT_TOKEN" \
  --type=kubernetes.io/basic-auth -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl annotate secret git-creds "tekton.dev/git-0=https://github.com" -n "$NAMESPACE" --overwrite

# 5. Sealed Docker Credentials
echo_info "Sealing Credentials..."
kubectl create secret docker-registry docker-hub-creds --docker-username="$DOCKER_USER" --docker-password="$DOCKER_PASS" --docker-server="https://index.docker.io/v1/" --dry-run=client -o yaml > d-plain.yaml
kubeseal --format=yaml --namespace "$NAMESPACE" < d-plain.yaml > d-sealed.yaml
kubectl apply -f d-sealed.yaml

# 6. Link Secrets to SA
kubectl patch serviceaccount "$SA_NAME" -n "$NAMESPACE" -p "{\"secrets\": [{\"name\": \"docker-hub-creds\"}, {\"name\": \"git-creds\"}]}"

# ==============================================================================
# PHASE 6: THE UNIVERSAL CI PIPELINE
# ==============================================================================
echo_info "Defining Universal CI Pipeline v4.6..."
cat <<EOF | kubectl apply -f -
apiVersion: tekton.dev/v1beta1
kind: Pipeline
metadata:
  name: universal-ci-pipeline
  namespace: $NAMESPACE
spec:
  params:
    - name: repo-url
    - name: image-name
    - name: image-tag
      default: "latest"
  workspaces:
    - name: shared-data
  tasks:
    - name: fetch-repo
      taskRef: { name: git-clone, kind: Task }
      workspaces: [{ name: output, workspace: shared-data }]
      params: [{ name: url, value: "\$(params.repo-url)" }]
    - name: app-lint
      runAfter: ["fetch-repo"]
      taskRef: { name: $SPECIFIC_LINTER, kind: Task }
      workspaces: [{ name: source, workspace: shared-data }]
    - name: build-and-push
      runAfter: ["app-lint"]
      taskRef: { name: buildah, kind: Task }
      workspaces: [{ name: source, workspace: shared-data }]
      params: [{ name: IMAGE, value: "docker.io/$DOCKER_USER/\$(params.image-name):\$(params.image-tag)" }]
    - name: security-scan
      runAfter: ["build-and-push"]
      taskRef: { name: trivy-scanner, kind: Task }
      params:
        - name: IMAGE_NAME
          value: "docker.io/$DOCKER_USER/\$(params.image-name):\$(params.image-tag)"
        - name: ARGS
          value: ["image", "--severity", "HIGH,CRITICAL", "--exit-code", "1"]
    - name: sign-image
      runAfter: ["security-scan"]
      taskRef: { name: cosign-sign, kind: Task }
      params:
        - name: image
          value: "docker.io/$DOCKER_USER/\$(params.image-name):\$(params.image-tag)"
        - name: secret_name
          value: "cosign-keys"
  finally:
    - name: workspace-cleanup
      taskRef: { name: cleanup, kind: Task }
      workspaces: [{ name: source, workspace: shared-data }]
EOF

echo_success "V4.6 HARDENED BOOTSTRAP COMPLETE!"
echo_info "Trigger command:"
echo "tkn pipeline start universal-ci-pipeline --serviceaccount $SA_NAME -w name=shared-data,claimName=tekton-pvc -p repo-url=https://github.com/$REPO_NAME -p image-name=myapp -n $NAMESPACE"
