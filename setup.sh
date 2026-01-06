#!/bin/bash
set -euo pipefail 

# --- Helper Functions ---
echo_info() { echo -e "\e[34m[INFO]\e[0m $1"; }
echo_success() { echo -e "\e[32m[SUCCESS]\e[0m $1"; }
echo_error() { echo -e "\e[31m[ERROR]\e[0m $1"; exit 1; }

# ==============================================================================
# PHASE 1: IDENTITY & ENVIRONMENT
# ==============================================================================
echo_info "--- Operational DevSecOps Factory v5.2.0 ---"

GIT_USER=${GIT_USER:-"markffckyou12"}
GIT_TOKEN=${GIT_TOKEN:-$(read -s -p "Enter GitHub PAT: " t && echo "$t")}
echo ""
REPO_NAME=${REPO_NAME:-"markffckyou12/cicd2"}
DOCKER_USER=${DOCKER_USER:-"ffckyou123"}
DOCKER_PASS=${DOCKER_PASS:-$(read -s -p "Enter Docker Hub Password: " dp && echo "$dp")}
echo ""
NAMESPACE=${NAMESPACE:-"tekton-tasks"}

# ==============================================================================
# PHASE 2: NAMESPACE & INFRASTRUCTURE
# ==============================================================================
echo_info "Creating Namespace: $NAMESPACE"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl label --overwrite ns "$NAMESPACE" pod-security.kubernetes.io/enforce=baseline

echo_info "Deploying Tekton Core..."
kubectl apply -f https://storage.googleapis.com/tekton-releases/pipeline/latest/release.yaml

echo_info "Waiting for Tekton stability..."
kubectl wait --for=condition=Available deployment/tekton-pipelines-controller -n tekton-pipelines --timeout=120s
kubectl wait --for=condition=Available deployment/tekton-pipelines-webhook -n tekton-pipelines --timeout=120s
# Stability sleep to prevent Webhook "connection refused" errors
sleep 10

# Create Pod Template File for PipelinRun execution
echo_info "Creating pod-template.yaml..."
cat <<EOF > pod-template.yaml
securityContext:
  fsGroup: 1000
  runAsUser: 1000
  runAsGroup: 1000
EOF

cat <<EOF | kubectl apply -n "$NAMESPACE" -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: shared-ci-pvc
spec:
  accessModes: [ReadWriteOnce]
  resources: { requests: { storage: 2Gi } }
EOF

# Docker Secret & RBAC
kubectl create secret docker-registry docker-hub-creds \
  --docker-username="$DOCKER_USER" --docker-password="$DOCKER_PASS" \
  --docker-server="https://index.docker.io/v1/" \
  -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl annotate secret docker-hub-creds "tekton.dev/docker-0=https://index.docker.io/v1/" --overwrite -n "$NAMESPACE"

SA_NAME="build-bot"
kubectl create serviceaccount "$SA_NAME" -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl patch serviceaccount "$SA_NAME" -n "$NAMESPACE" -p "{\"secrets\": [{\"name\": \"docker-hub-creds\"}]}"

# ==============================================================================
# PHASE 3: THE OPERATIONAL PIPELINE
# ==============================================================================
echo_info "Defining Operational Security Pipeline..."

cat <<EOF | kubectl apply -n "$NAMESPACE" -f -
apiVersion: tekton.dev/v1
kind: Pipeline
metadata:
  name: devsecops-pipeline
spec:
  params:
    - name: repo-url
      type: string
    - name: image-full-name
      type: string
  workspaces:
    - name: shared-data
  tasks:
    - name: fetch-repo
      taskRef:
        resolver: hub
        params:
          - name: kind
            value: task
          - name: name
            value: git-clone
          - name: version
            value: "0.9"
      workspaces: [ { name: output, workspace: shared-data } ]
      params:
        - name: url
          value: \$(params.repo-url)

    - name: source-scan
      runAfter: ["fetch-repo"]
      workspaces: [ { name: source, workspace: shared-data } ]
      taskSpec:
        workspaces: [ { name: source } ]
        steps:
          - name: trivy-fs-scan
            image: aquasec/trivy:latest
            workingDir: \$(workspaces.source.path)
            env:
              - name: TRIVY_CACHE_DIR
                value: \$(workspaces.source.path)/.trivycache
            script: |
              mkdir -p \$TRIVY_CACHE_DIR
              echo "GATE 1: Scanning Filesystem (Shift Left)..."
              trivy fs --exit-code 1 --severity HIGH,CRITICAL --ignore-unfixed --no-progress .

    - name: build-and-push
      runAfter: ["source-scan"]
      workspaces: [ { name: source, workspace: shared-data } ]
      taskSpec:
        workspaces: [ { name: source } ]
        steps:
          - name: buildah-push
            image: quay.io/buildah/stable:v1.30
            workingDir: \$(workspaces.source.path)
            env:
              - name: REGISTRY_AUTH_FILE
                value: /tekton/creds/.docker/config.json
            script: |
              echo "Building \$(params.image-full-name)..."
              buildah bud --storage-driver=vfs -f ./Dockerfile -t \$(params.image-full-name) .
              echo "Pushing..."
              buildah push --storage-driver=vfs \$(params.image-full-name)

    - name: image-scan
      runAfter: ["build-and-push"]
      workspaces: [ { name: source, workspace: shared-data } ]
      taskSpec:
        workspaces: [ { name: source } ]
        steps:
          - name: trivy-image-scan
            image: aquasec/trivy:latest
            env:
              - name: TRIVY_CACHE_DIR
                value: \$(workspaces.source.path)/.trivycache
            script: |
              echo "GATE 2: Scanning Final Image (Operational Gate)..."
              trivy image --exit-code 1 --severity HIGH,CRITICAL --ignore-unfixed \$(params.image-full-name)
EOF

# ==============================================================================
# FINISH
# ==============================================================================
echo "------------------------------------------------------------"
echo_success "OPERATIONAL DEVSECOPS BOOTSTRAP COMPLETE!"
echo_info "To start your SECURE build, run:"
echo "tkn pipeline start devsecops-pipeline \\
  --param repo-url=https://github.com/$REPO_NAME.git \\
  --param image-full-name=docker.io/$DOCKER_USER/cicd-test:latest \\
  --workspace name=shared-data,claimName=shared-ci-pvc \\
  --pod-template pod-template.yaml \\
  --serviceaccount $SA_NAME \\
  --namespace $NAMESPACE \\
  --showlog"
