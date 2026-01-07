#!/bin/bash
set -euo pipefail 

# --- Helper Functions ---
echo_info() { echo -e "\e[34m[INFO]\e[0m $1"; }
echo_success() { echo -e "\e[32m[SUCCESS]\e[0m $1"; }
echo_warn() { echo -e "\e[33m[WARN]\e[0m $1"; }
echo_error() { echo -e "\e[31m[ERROR]\e[0m $1"; exit 1; }

# ==============================================================================
# PHASE 1: PRE-FLIGHT & TEKTON INSTALL
# ==============================================================================
echo_info "Starting Pre-flight checks..."

# Check for kubectl
command -v kubectl >/dev/null 2>&1 || echo_error "kubectl not found."

# Install Tekton if missing or freshly deleted
if ! kubectl get pods -n tekton-pipelines >/dev/null 2>&1; then
    echo_warn "Tekton not detected. Installing Tekton Pipelines..."
    kubectl apply --filename https://storage.googleapis.com/tekton-releases/pipeline/latest/release.yaml
    echo_info "Waiting for Tekton CRDs to be established..."
    kubectl wait --for condition=established --timeout=60s crd/tasks.tekton.dev
    kubectl wait --for condition=established --timeout=60s crd/pipelines.tekton.dev
    echo_info "Waiting for Tekton Controller to be ready..."
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/component=controller -n tekton-pipelines --timeout=90s
fi

# Check for CLI tools
for tool in tkn cosign; do
    if ! command -v $tool >/dev/null 2>&1; then
        echo_warn "$tool missing. Installing for Linux..."
        if [ "$tool" == "tkn" ]; then
            curl -LO https://github.com/tektoncd/cli/releases/download/v0.32.0/tkn_0.32.0_Linux_x86_64.tar.gz
            tar xvzf tkn_0.32.0_Linux_x86_64.tar.gz tkn && sudo mv tkn /usr/local/bin/
        else
            curl -LO https://github.com/sigstore/cosign/releases/latest/download/cosign-linux-amd64
            sudo mv cosign-linux-amd64 /usr/local/bin/cosign && sudo chmod +x /usr/local/bin/cosign
        fi
    fi
done

# ==============================================================================
# PHASE 2: IDENTITY
# ==============================================================================
GIT_USER=${GIT_USER:-"markffckyou12"}
DOCKER_USER=${DOCKER_USER:-"ffckyou123"}
NAMESPACE=${NAMESPACE:-"tekton-tasks"}
COSIGN_PASSWORD="factory-password-123"
TRIVY_SERVER="http://host.minikube.internal:8080"

[ -z "${GIT_TOKEN:-}" ] && { read -s -p "Enter GitHub PAT: " GIT_TOKEN; echo ""; }
[ -z "${DOCKER_PASS:-}" ] && { read -s -p "Enter Docker Hub Password: " DOCKER_PASS; echo ""; }

# ==============================================================================
# PHASE 3: INFRASTRUCTURE & RBAC FIXES
# ==============================================================================
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

echo_info "Configuring RBAC for Secret Management..."
cat <<EOF | kubectl apply -n "$NAMESPACE" -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: secret-manager
rules:
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["get", "list", "create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: pipeline-secret-binder
subjects:
- kind: ServiceAccount
  name: build-bot
- kind: ServiceAccount
  name: default
roleRef:
  kind: Role
  name: secret-manager
  apiGroup: rbac.authorization.k8s.io
EOF

cat <<EOF | kubectl apply -n "$NAMESPACE" -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: shared-ci-pvc
spec:
  accessModes: [ReadWriteOnce]
  resources: { requests: { storage: 1Gi } }
EOF

# Setup ServiceAccount and Credentials
kubectl create serviceaccount build-bot -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret docker-registry docker-hub-creds \
  --docker-username="$DOCKER_USER" --docker-password="$DOCKER_PASS" \
  --docker-server="https://index.docker.io/v1/" -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl annotate secret docker-hub-creds "tekton.dev/docker-0=https://index.docker.io/v1/" --overwrite -n "$NAMESPACE"

kubectl create secret generic github-creds --from-literal=username="$GIT_USER" --from-literal=password="$GIT_TOKEN" --type=kubernetes.io/basic-auth -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl annotate secret github-creds "tekton.dev/git-0=https://github.com" --overwrite -n "$NAMESPACE"

# Cosign Keys (Now works because of secret-manager Role)
if ! kubectl get secret cosign-keys -n "$NAMESPACE" >/dev/null 2>&1; then
    echo_info "Generating Cosign Keys..."
    kubectl run cosign-gen -n "$NAMESPACE" --rm -i --restart=Never \
      --image=gcr.io/projectsigstore/cosign:v2.2.1 \
      --env="COSIGN_PASSWORD=$COSIGN_PASSWORD" -- generate-key-pair k8s://"$NAMESPACE"/cosign-keys
fi

kubectl patch serviceaccount build-bot -n "$NAMESPACE" -p "{\"secrets\": [{\"name\": \"docker-hub-creds\"}, {\"name\": \"cosign-keys\"}, {\"name\": \"github-creds\"}]}"

# ==============================================================================
# PHASE 4: THE SECURE PIPELINE
# ==============================================================================
echo_info "Deploying Pipeline Resources..."



cat <<'EOF' | kubectl apply -n "$NAMESPACE" -f -
apiVersion: tekton.dev/v1
kind: Task
metadata:
  name: cosign-sign-task
spec:
  params:
    - name: image-full-name
  steps:
    - name: sign
      image: gcr.io/projectsigstore/cosign:v2.2.1
      command: ["/ko-app/cosign"]
      args: ["sign", "--key", "k8s://tekton-tasks/cosign-keys", "--tlog-upload=false", "--yes", "$(params.image-full-name)"]
      env:
        - name: COSIGN_PASSWORD
          value: "factory-password-123"
        - name: REGISTRY_AUTH_FILE
          value: /tekton/creds/.docker/config.json
EOF

cat <<EOF | kubectl apply -n "$NAMESPACE" -f -
apiVersion: tekton.dev/v1
kind: Pipeline
metadata:
  name: devsecops-pipeline
spec:
  params:
    - name: repo-url
    - name: image-full-name
  workspaces:
    - name: shared-data
  tasks:
    - name: fetch-repo
      taskRef: { resolver: hub, params: [{ name: kind, value: task }, { name: name, value: git-clone }, { name: version, value: "0.9" }] }
      workspaces: [ { name: output, workspace: shared-data } ]
      params: [ { name: url, value: "\$(params.repo-url)" } ]
    - name: build-and-push
      runAfter: ["fetch-repo"]
      workspaces: [ { name: source, workspace: shared-data } ]
      params: [ { name: image-full-name, value: "\$(params.image-full-name)" } ]
      taskSpec:
        params: [ { name: image-full-name } ]
        workspaces: [ { name: source } ]
        steps:
          - name: buildah
            image: quay.io/buildah/stable:v1.30
            env: [ { name: REGISTRY_AUTH_FILE, value: /tekton/creds/.docker/config.json } ]
            script: |
              set -e
              buildah bud --storage-driver=vfs -f \$(workspaces.source.path)/Dockerfile -t \$(params.image-full-name) \$(workspaces.source.path)
              buildah push --storage-driver=vfs \$(params.image-full-name)
    - name: sign-image
      runAfter: ["build-and-push"]
      taskRef: { name: cosign-sign-task }
      params: [ { name: image-full-name, value: "\$(params.image-full-name)" } ]
    - name: image-scan
      runAfter: ["sign-image"]
      params: [ { name: image-full-name, value: "\$(params.image-full-name)" } ]
      taskSpec:
        params: [ { name: image-full-name } ]
        steps:
          - name: trivy-scan
            image: aquasec/trivy:latest
            script: |
              trivy image --server $TRIVY_SERVER --severity HIGH,CRITICAL \$(params.image-full-name)
EOF

echo_success "ALL SYSTEMS READY."
echo "------------------------------------------------------------------------"
echo "RUN THIS COMMAND TO TEST THE SECURE BUILD:"
echo "------------------------------------------------------------------------"
echo "tkn pipeline start devsecops-pipeline \\
  --param repo-url=\"https://github.com/$GIT_USER/cicd2.git\" \\
  --param image-full-name=\"docker.io/$DOCKER_USER/cicd-test:latest\" \\
  --workspace name=shared-data,claimName=shared-ci-pvc \\
  --serviceaccount build-bot \\
  --namespace $NAMESPACE \\
  --showlog"
echo "------------------------------------------------------------------------"
