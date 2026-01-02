#!/bin/bash

# --- Helper Functions ---
echo_info() { echo -e "\e[34m[INFO]\e[0m $1"; }
echo_success() { echo -e "\e[32m[SUCCESS]\e[0m $1"; }
echo_error() { echo -e "\e[31m[ERROR]\e[0m $1"; exit 1; }

# Cleanup trap 
cleanup_temp() {
    rm -f buildah-raw.yaml d-plain.yaml d-sealed.yaml
    echo_info "Temporary manifests cleaned."
}
trap cleanup_temp EXIT

# ==============================================================================
# PHASE 0: TOOLING & CONTROLLERS
# ==============================================================================
echo_info "Initializing Infrastructure..."
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')

# Architecture-aware CLI install
[ ! -x "$(command -v tkn)" ] && { curl -LO "https://github.com/tektoncd/cli/releases/download/v0.32.0/tkn_0.32.0_${OS}_${ARCH}.tar.gz" && tar xvzf tkn*.tar.gz -C /usr/local/bin/ tkn && rm tkn*.tar.gz; }
[ ! -x "$(command -v cosign)" ] && { curl -LO "https://github.com/sigstore/cosign/releases/latest/download/cosign-${OS}-${ARCH}" && sudo install cosign-${OS}-${ARCH} /usr/local/bin/cosign && rm cosign-${OS}-${ARCH}; }
[ ! -x "$(command -v kubeseal)" ] && { curl -L "https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.24.0/kubeseal-0.24.0-${OS}-${ARCH}.tar.gz" | tar xz && sudo install -m 755 kubeseal /usr/local/bin/kubeseal && rm kubeseal; }
[ ! -x "$(command -v yq)" ] && { curl -L "https://github.com/mikefarah/yq/releases/latest/download/yq_${OS}_${ARCH}" -o /usr/local/bin/yq && chmod +x /usr/local/bin/yq; }

# Install Tekton Pipelines & Dashboard
kubectl apply -f https://storage.googleapis.com/tekton-releases/pipeline/latest/release.yaml
kubectl apply -f https://storage.googleapis.com/tekton-releases/dashboard/latest/release.yaml

# Install Sealed Secrets
kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.24.0/controller.yaml

# Install Kyverno (Policy Engine)
kubectl apply -f https://github.com/kyverno/kyverno/releases/download/v1.10.0/install.yaml

echo_info "Waiting for controllers to stabilize..."
kubectl wait --for=condition=available --timeout=180s deployment/sealed-secrets-controller -n kube-system
kubectl wait --for=condition=available --timeout=180s deployment/kyverno -n kyverno

# ==============================================================================
# PHASE 1: IDENTITY
# ==============================================================================
echo_info "--- Hardened CI Factory v5.0 ---"
GIT_USER=${GIT_USER:-$(read -p "GitHub Username: " u && echo $u)}
GIT_TOKEN=${GIT_TOKEN:-$(read -s -p "GitHub PAT: " t && echo $t)}
echo ""
DOCKER_USER=${DOCKER_USER:-$(read -p "Docker Hub Username: " du && echo $du)}
DOCKER_PASS=${DOCKER_PASS:-$(read -s -p "Docker Hub Password: " dp && echo $dp)}
echo ""

# ==============================================================================
# PHASE 2: DYNAMIC TASK SELECTION
# ==============================================================================
echo_info "Available Task Suites: python, nodejs, golang, java-maven, java-gradle, shellcheck, cpp"
read -p "Enter Primary Language/Suite [python]: " LANG_CHOICE
LANG_CHOICE=${LANG_CHOICE:-python}

case $LANG_CHOICE in
    python)      SPECIFIC_LINTER="flake8"; EXTRA_TASKS=("pylint") ;;
    nodejs)      SPECIFIC_LINTER="eslint"; EXTRA_TASKS=() ;;
    golang)      SPECIFIC_LINTER="golangci-lint"; EXTRA_TASKS=() ;;
    java-maven)  SPECIFIC_LINTER="maven"; EXTRA_TASKS=() ;;
    java-gradle) SPECIFIC_LINTER="gradle"; EXTRA_TASKS=() ;;
    cpp)          SPECIFIC_LINTER="cppcheck"; EXTRA_TASKS=() ;;
    *)           SPECIFIC_LINTER="shellcheck"; EXTRA_TASKS=() ;;
esac

NAMESPACE="tekton-tasks"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

echo_info "Installing Security & Core Tasks..."
CORE_TASKS=("git-clone" "trivy-scanner" "cosign-sign" "cleanup" "hadolint" "$SPECIFIC_LINTER" "${EXTRA_TASKS[@]}")
for TASK in "${CORE_TASKS[@]}"; do
    tkn hub install task "$TASK" -n "$NAMESPACE" 2>/dev/null || echo_info "Task $TASK is ready."
done

# PATCH: Buildah Rootless
tkn hub get task buildah --version 0.7 > buildah-raw.yaml
yq -i '.spec.steps[0].securityContext = {"runAsUser": 1000, "runAsGroup": 1000, "fsGroup": 1000, "allowPrivilegeEscalation": false}' buildah-raw.yaml
yq -i '.spec.steps[0].env += [{"name": "STORAGE_DRIVER", "value": "overlay"}]' buildah-raw.yaml
kubectl apply -f buildah-raw.yaml -n "$NAMESPACE"

# ==============================================================================
# PHASE 3: RBAC, PVC, SIGNING & PRUNING
# ==============================================================================
SA_NAME="build-bot"

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: tekton-pvc
  namespace: $NAMESPACE
spec:
  accessModes: [ReadWriteOnce]
  resources: { requests: { storage: 10Gi } }
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: tekton-manager-role
  namespace: $NAMESPACE
rules:
- apiGroups: ["tekton.dev"]
  resources: ["tasks", "pipelines", "taskruns", "pipelineruns"]
  verbs: ["*"]
- apiGroups: [""]
  resources: ["secrets", "pods", "persistentvolumeclaims"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: build-bot-binding
  namespace: $NAMESPACE
subjects: [{ kind: ServiceAccount, name: $SA_NAME, namespace: $NAMESPACE }]
roleRef: { kind: Role, name: tekton-manager-role, apiGroup: rbac.authorization.k8s.io }
---
apiVersion: tekton.dev/v1alpha1
kind: PruningReplicated
metadata:
  name: keep-last-10-runs
  namespace: $NAMESPACE
spec:
  resources:
    - pipelineRuns
  keep: 10
EOF

# Cosign key generation
if ! kubectl get secret cosign-keys -n "$NAMESPACE" > /dev/null 2>&1; then
    export COSIGN_PASSWORD=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 32)
    cosign generate-key-pair k8s://"$NAMESPACE"/cosign-keys
fi

# Secrets & Registry Mapping
kubectl create secret generic git-creds --from-literal=username="$GIT_USER" --from-literal=password="$GIT_TOKEN" --type=kubernetes.io/basic-auth -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl annotate secret git-creds "tekton.dev/git-0=https://github.com" -n "$NAMESPACE" --overwrite

kubectl create secret docker-registry docker-hub-creds --docker-username="$DOCKER_USER" --docker-password="$DOCKER_PASS" --docker-server="https://index.docker.io/v1/" --dry-run=client -o yaml > d-plain.yaml
kubeseal --format=yaml --namespace "$NAMESPACE" < d-plain.yaml > d-sealed.yaml
kubectl apply -f d-sealed.yaml
kubectl patch serviceaccount "$SA_NAME" -n "$NAMESPACE" -p "{\"secrets\": [{\"name\": \"docker-hub-creds\"}, {\"name\": \"git-creds\"}]}"

# ==============================================================================
# PHASE 4: UNIVERSAL PIPELINE
# ==============================================================================
cat <<EOF | kubectl apply -f -
apiVersion: tekton.dev/v1beta1
kind: Pipeline
metadata:
  name: universal-ci-pipeline
  namespace: $NAMESPACE
spec:
  params:
    - name: repo-url
    - name: repo-revision
      default: "main"
    - name: image-name
    - name: image-tag
  workspaces:
    - name: shared-data
  tasks:
    - name: fetch-repo
      taskRef: { name: git-clone }
      workspaces: [{ name: output, workspace: shared-data }]
      params:
        - name: url
          value: "\$(params.repo-url)"
        - name: revision
          value: "\$(params.repo-revision)"
    - name: app-lint
      runAfter: ["fetch-repo"]
      taskRef: { name: $SPECIFIC_LINTER }
      workspaces: [{ name: source, workspace: shared-data }]
    - name: build-and-push
      runAfter: ["app-lint"]
      taskRef: { name: buildah }
      workspaces: [{ name: source, workspace: shared-data }]
      params:
        - name: IMAGE
          value: "docker.io/$DOCKER_USER/\$(params.image-name):\$(params.image-tag)"
    - name: security-scan
      runAfter: ["build-and-push"]
      taskRef: { name: trivy-scanner }
      params:
        - name: IMAGE_NAME
          value: "docker.io/$DOCKER_USER/\$(params.image-name):\$(params.image-tag)"
        - name: ARGS
          value: ["image", "--severity", "HIGH,CRITICAL", "--exit-code", "1"]
    - name: sign-image
      runAfter: ["security-scan"]
      taskRef: { name: cosign-sign }
      params:
        - name: image
          value: "docker.io/$DOCKER_USER/\$(params.image-name):\$(params.image-tag)"
        - name: secret_name
          value: "cosign-keys"
  finally:
    - name: workspace-cleanup
      taskRef: { name: cleanup }
      workspaces: [{ name: source, workspace: shared-data }]
EOF

# ==============================================================================
# PHASE 5: ADMISSION CONTROL POLICY (KYVERNO)
# ==============================================================================
echo_info "Enforcing Image Integrity Policy..."
PUBLIC_KEY=$(kubectl get secret cosign-keys -n "$NAMESPACE" -o jsonpath='{.data.cosign\.pub}' | base64 -d)

cat <<EOF | kubectl apply -f -
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: enforce-signed-images
spec:
  validationFailureAction: Enforce
  background: false
  rules:
    - name: check-image-signature
      match:
        any:
        - resources:
            kinds: ["Pod"]
            namespaces: ["$NAMESPACE"]
      verifyImages:
        - imageReferences: ["docker.io/$DOCKER_USER/*"]
          attestors:
            - entries:
              - keys:
                  publicKeys: |
$(echo "$PUBLIC_KEY" | sed 's/^/                    /')
EOF

echo_success "V5.0 BOOTSTRAP COMPLETE! Suite: $LANG_CHOICE"
echo_info "Dashboard: kubectl port-forward -n tekton-pipelines service/tekton-dashboard 9097:9097"
