#!/bin/bash

# --- Helper Functions ---
echo_info() { echo -e "\e[34m[INFO]\e[0m $1"; }
echo_success() { echo -e "\e[32m[SUCCESS]\e[0m $1"; }
echo_error() { echo -e "\e[31m[ERROR]\e[0m $1"; exit 1; }

# --- NEW: Sanitization Gate ---
validate_input() {
    local val="$1"
    local name="$2"
    if [[ ! "$val" =~ ^[a-zA-Z0-9._/-]+$ ]]; then
        echo_error "Invalid input for $name. Only alphanumeric, '.', '_', and '-' allowed."
    fi
}

# ==============================================================================
# PHASE 1: IDENTITY & GITOPS VALIDATION
# ==============================================================================
echo_info "--- Initializing Secure CI Factory (Hardened CI v4.3) ---"

# Prompt for credentials with sanitization
if [ -z "$GIT_USER" ]; then
    read -p "Enter GitHub Username: " u; validate_input "$u" "GitHub User"; GIT_USER=$u
fi
GIT_TOKEN=${GIT_TOKEN:-$(read -s -p "Enter GitHub PAT: " t && echo $t)}
echo ""
if [ -z "$REPO_NAME" ]; then
    read -p "Enter Target Repository (e.g., user/project): " r; validate_input "$r" "Repo Name"; REPO_NAME=$r
fi

echo "::add-mask::$GIT_TOKEN" 2>/dev/null || true

echo_info "Verifying GitHub Access..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -u "$GIT_USER:$GIT_TOKEN" "https://api.github.com/repos/$REPO_NAME")
[ "$HTTP_CODE" -ne 200 ] && echo_error "GitHub Access Denied (HTTP $HTTP_CODE)."

if [ -z "$DOCKER_USER" ]; then
    read -p "Enter Docker Hub Username: " du; validate_input "$du" "Docker User"; DOCKER_USER=$du
fi
DOCKER_PASS=${DOCKER_PASS:-$(read -s -p "Enter Docker Hub Password: " dp && echo $dp)}
echo "::add-mask::$DOCKER_PASS" 2>/dev/null || true
echo ""
echo_success "Identity Verified."

# ==============================================================================
# PHASE 2: RESOURCE BUDGETING & PSA COMPLIANCE
# ==============================================================================
NAMESPACE=${NAMESPACE:-tekton-tasks}
PVC_SIZE=10Gi
CLOUD_CHOICE=${CLOUD_CHOICE:-1}

case $CLOUD_CHOICE in 2) SC="gp3" ;; 3) SC="premium-rwo" ;; 4) SC="managed-csi-premium" ;; *) SC="standard" ;; esac

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
echo_info "Enforcing Baseline Pod Security Standards on $NAMESPACE..."
kubectl label --overwrite ns "$NAMESPACE" pod-security.kubernetes.io/enforce=baseline

# ==============================================================================
# PHASE 3: ENGINE & TOOL INSTALLATION
# ==============================================================================
echo_info "Installing Engines & CLIs..."
[ ! -x "$(command -v tkn)" ] && { curl -LO https://github.com/tektoncd/cli/releases/download/v0.43.0/tkn_0.43.0_Linux_x86_64.tar.gz && sudo tar xvzf tkn_0.43.0_Linux_x86_64.tar.gz -C /usr/local/bin/ tkn && rm tkn_0.43.0_Linux_x86_64.tar.gz; }
[ ! -x "$(command -v cosign)" ] && { curl -LO https://github.com/sigstore/cosign/releases/latest/download/cosign-linux-amd64 && sudo install cosign-linux-amd64 /usr/local/bin/cosign && rm cosign-linux-amd64; }
[ ! -x "$(command -v kubeseal)" ] && { curl -L "https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.33.1/kubeseal-0.33.1-linux-amd64.tar.gz" | tar xz && sudo install -m 755 kubeseal /usr/local/bin/kubeseal && rm kubeseal; }
[ ! -x "$(command -v yq)" ] && { curl -L "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64" -o /usr/local/bin/yq && chmod +x /usr/local/bin/yq; }

kubectl apply -f https://storage.googleapis.com/tekton-releases/pipeline/latest/release.yaml

# ==============================================================================
# PHASE 4: THE HARDENED CI REGISTRY (Rootless Task Configuration)
# ==============================================================================
echo_info "Provisioning Quality & Security Gates..."

LANG_CHOICE=${LANG_CHOICE:-1}
case $LANG_CHOICE in
    1) TASKS_L1=("flake8" "pylint"); SPECIFIC_LINTER="flake8" ;;
    2) TASKS_L1=("eslint"); SPECIFIC_LINTER="eslint" ;;
    3) TASKS_L1=("golangci-lint"); SPECIFIC_LINTER="golangci-lint" ;;
    4) TASKS_L1=("ruby-linter"); SPECIFIC_LINTER="ruby-linter" ;;
    5) TASKS_L1=("shellcheck"); SPECIFIC_LINTER="shellcheck" ;;
esac

ALL_TASKS=("${TASKS_L1[@]}" "kube-linter" "datree" "git-clone" "hadolint" "trivy-scanner" "cosign-sign" "cleanup")

for TASK in "${ALL_TASKS[@]}"; do
    tkn hub install task "$TASK" -n "$NAMESPACE" 2>/dev/null || echo_info "Task $TASK ready."
done

# PATCH: Buildah Rootless Configuration
tkn hub get task buildah --version 0.7 > buildah-raw.yaml
yq -i '.spec.steps[0].securityContext = {"runAsUser": 1000, "runAsGroup": 1000, "fsGroup": 1000, "allowPrivilegeEscalation": false}' buildah-raw.yaml
yq -i '.spec.steps[0].env += [{"name": "STORAGE_DRIVER", "value": "vfs"}]' buildah-raw.yaml
kubectl apply -f buildah-raw.yaml -n "$NAMESPACE" && rm buildah-raw.yaml

# ==============================================================================
# PHASE 5: INFRASTRUCTURE, RBAC & SUPPLY CHAIN
# ==============================================================================
echo_info "Wiring Security Identity & RBAC..."
SA_NAME="build-bot"

if ! kubectl get secret cosign-keys -n "$NAMESPACE" > /dev/null 2>&1; then
    # NEW: Dynamic Passphrase Logic
    read -s -p "Enter Cosign Passphrase (Leave blank to auto-generate): " user_pass
    echo ""
    if [ -z "$user_pass" ]; then
        COSIGN_PASSWORD=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 32)
        echo_success "AUTO-GENERATED COSIGN PASS: $COSIGN_PASSWORD"
    else
        COSIGN_PASSWORD="$user_pass"
    fi
    export COSIGN_PASSWORD
    cosign generate-key-pair k8s://"$NAMESPACE"/cosign-keys
fi

# RBAC and Credentials
kubectl create secret docker-registry docker-hub-creds --docker-username="$DOCKER_USER" --docker-password="$DOCKER_PASS" --docker-server="https://index.docker.io/v1/" --dry-run=client -o yaml > docker-plain.yaml
kubeseal --format=yaml --namespace "$NAMESPACE" < docker-plain.yaml > docker-hub-sealed.yaml
kubectl apply -f docker-hub-sealed.yaml && rm docker-plain.yaml docker-hub-sealed.yaml

kubectl create serviceaccount "$SA_NAME" -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl patch serviceaccount "$SA_NAME" -n "$NAMESPACE" -p "{\"secrets\": [{\"name\": \"docker-hub-creds\"}]}"

# RBAC for Cosign
cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: cosign-key-reader
  namespace: $NAMESPACE
rules:
- apiGroups: [""]
  resources: ["secrets"]
  resourceNames: ["cosign-keys"]
  verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: build-bot-cosign-read
  namespace: $NAMESPACE
subjects:
- kind: ServiceAccount
  name: $SA_NAME
roleRef:
  kind: Role
  name: cosign-key-reader
  apiGroup: rbac.authorization.k8s.io
EOF

# ==============================================================================
# PHASE 6: THE UNIVERSAL CI PIPELINE (Optimized for Ephemeral Storage)
# ==============================================================================
echo_info "Defining Universal CI Pipeline v4.3..."

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
      taskRef:
        name: git-clone
      workspaces: [ { name: output, workspace: shared-data } ]
      params:
        - name: url
          value: \$(params.repo-url)

    - name: app-lint
      runAfter: ["fetch-repo"]
      taskRef:
        name: $SPECIFIC_LINTER
      workspaces: [ { name: source, workspace: shared-data } ]

    - name: infra-lint
      runAfter: ["fetch-repo"]
      taskRef:
        name: kube-linter
      workspaces: [ { name: source, workspace: shared-data } ]

    - name: build-and-push
      runAfter: ["app-lint", "infra-lint"]
      taskRef:
        name: buildah
      workspaces: [ { name: source, workspace: shared-data } ]
      params:
        - name: IMAGE
          value: docker.io/$DOCKER_USER/\$(params.image-name):\$(params.image-tag)

    - name: security-scan
      runAfter: ["build-and-push"]
      taskRef:
        name: trivy-scanner
      params:
        - name: IMAGE_NAME
          value: docker.io/$DOCKER_USER/\$(params.image-name):\$(params.image-tag)
        - name: ARGS
          value: ["image", "--severity", "HIGH,CRITICAL", "--exit-code", "1"]

    - name: sign-image
      runAfter: ["security-scan"]
      taskRef:
        name: cosign-sign
      params:
        - name: image
          value: docker.io/$DOCKER_USER/\$(params.image-name):\$(params.image-tag)
        - name: secret_name
          value: "cosign-keys"

  finally:
    - name: workspace-cleanup
      taskRef:
        name: cleanup
EOF

echo "------------------------------------------------------------"
echo_success "V4.3 HARDENED BOOTSTRAP COMPLETE!"
echo_info "Logic: Input Sanitization + Random Cosign Pass + Ephemeral Ready"
echo "------------------------------------------------------------"
