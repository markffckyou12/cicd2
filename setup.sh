#!/bin/bash
set -euo pipefail 

# --- Helper Functions ---
echo_info() { echo -e "\e[34m[INFO]\e[0m $1"; }
echo_success() { echo -e "\e[32m[SUCCESS]\e[0m $1"; }
echo_error() { echo -e "\e[31m[ERROR]\e[0m $1"; exit 1; }

# ==============================================================================
# PHASE 1: IDENTITY & ENVIRONMENT
# ==============================================================================
echo_info "--- DevSecOps Factory v5.7.0 (Corrected Parameter Wiring) ---"

GIT_USER=${GIT_USER:-"markffckyou12"}
GIT_TOKEN=${GIT_TOKEN:-$(read -s -p "Enter GitHub PAT: " t && echo "$t")}
echo ""
REPO_NAME=${REPO_NAME:-"markffckyou12/cicd2"}
DOCKER_USER=${DOCKER_USER:-"ffckyou123"}
DOCKER_PASS=${DOCKER_PASS:-$(read -s -p "Enter Docker Hub Password: " dp && echo "$dp")}
echo ""
NAMESPACE=${NAMESPACE:-"tekton-tasks"}
IMAGE_NAME="docker.io/$DOCKER_USER/cicd-test:latest"

# The "Bridge" address for Minikube to talk to your Codespace/Local Land
TRIVY_SERVER_DEFAULT="http://host.minikube.internal:8080"

# ==============================================================================
# PHASE 2: INFRASTRUCTURE & STABILITY
# ==============================================================================
echo_info "Creating Namespace: $NAMESPACE"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

echo_info "Deploying Tekton Core..."
kubectl apply -f https://storage.googleapis.com/tekton-releases/pipeline/latest/release.yaml

echo_info "Applying Stability Patch (Disabling Affinity Assistant)..."
kubectl patch cm feature-flags -n tekton-pipelines -p '{"data":{"disable-affinity-assistant":"true"}}'

echo_info "Waiting for Tekton Controllers..."
kubectl wait --for=condition=Available deployment/tekton-pipelines-controller -n tekton-pipelines --timeout=120s

echo_info "Waiting for Tekton Webhook (to prevent Connection Refused)..."
kubectl wait --for=condition=Available deployment/tekton-pipelines-webhook -n tekton-pipelines --timeout=120s

cat <<EOF | kubectl apply -n "$NAMESPACE" -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: shared-ci-pvc
spec:
  accessModes: [ReadWriteOnce]
  resources: { requests: { storage: 2Gi } }
EOF

kubectl create secret docker-registry docker-hub-creds \
  --docker-username="$DOCKER_USER" --docker-password="$DOCKER_PASS" \
  --docker-server="https://index.docker.io/v1/" \
  -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl annotate secret docker-hub-creds "tekton.dev/docker-0=https://index.docker.io/v1/" --overwrite -n "$NAMESPACE"

SA_NAME="build-bot"
kubectl create serviceaccount "$SA_NAME" -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl patch serviceaccount "$SA_NAME" -n "$NAMESPACE" -p "{\"secrets\": [{\"name\": \"docker-hub-creds\"}]}"

# ==============================================================================
# PHASE 3: UPDATED PIPELINE (FIXED PARAMETER PASSING)
# ==============================================================================
echo_info "Defining Pipeline with Corrected Wiring..."

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
    - name: trivy-server-url
      type: string
      default: "$TRIVY_SERVER_DEFAULT"
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
      params:
        - name: trivy-server-url
          value: \$(params.trivy-server-url)
      taskSpec:
        params:
          - name: trivy-server-url
            type: string
        workspaces: [ { name: source } ]
        steps:
          - name: trivy-fs-scan
            image: aquasec/trivy:latest
            workingDir: \$(workspaces.source.path)
            script: |
              echo "Scanning source via \$(params.trivy-server-url)..."
              trivy fs --server \$(params.trivy-server-url) --exit-code 1 --severity HIGH,CRITICAL --ignore-unfixed .

    - name: build-and-push
      runAfter: ["source-scan"]
      workspaces: [ { name: source, workspace: shared-data } ]
      params:
        - name: image-full-name
          value: \$(params.image-full-name)
      taskSpec:
        params:
          - name: image-full-name
            type: string
        workspaces: [ { name: source } ]
        steps:
          - name: buildah-push
            image: quay.io/buildah/stable:v1.30
            workingDir: \$(workspaces.source.path)
            env:
              - name: REGISTRY_AUTH_FILE
                value: /tekton/creds/.docker/config.json
            script: |
              buildah bud --storage-driver=vfs -f ./Dockerfile -t \$(params.image-full-name) .
              buildah push --storage-driver=vfs \$(params.image-full-name)

    - name: image-scan
      runAfter: ["build-and-push"]
      params:
        - name: image-full-name
          value: \$(params.image-full-name)
        - name: trivy-server-url
          value: \$(params.trivy-server-url)
      taskSpec:
        params:
          - name: image-full-name
            type: string
          - name: trivy-server-url
            type: string
        steps:
          - name: trivy-image-scan
            image: aquasec/trivy:latest
            script: |
              echo "Scanning image via \$(params.trivy-server-url)..."
              trivy image --server \$(params.trivy-server-url) --exit-code 1 --severity HIGH,CRITICAL --ignore-unfixed \$(params.image-full-name)
EOF

echo_success "SETUP COMPLETE - PIPELINE IS NOW PARAMETERIZED AND WIRED"

# ==============================================================================
# NEXT STEPS
# ==============================================================================
echo ""
echo "To manually start the build (using the default local bridge):"
echo "--------------------------------------------------------"
echo "tkn pipeline start devsecops-pipeline \\"
echo "  --param repo-url=\"https://github.com/$REPO_NAME.git\" \\"
echo "  --param image-full-name=\"$IMAGE_NAME\" \\"
echo "  --param trivy-server-url=\"$TRIVY_SERVER_DEFAULT\" \\"
echo "  --workspace name=shared-data,claimName=shared-ci-pvc \\"
echo "  --serviceaccount \"$SA_NAME\" \\"
echo "  --namespace \"$NAMESPACE\" \\"
echo "  --showlog"
echo "--------------------------------------------------------"
