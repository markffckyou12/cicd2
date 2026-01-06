#!/bin/bash
set -euo pipefail 

# --- Helper Functions ---
echo_info() { echo -e "\e[34m[INFO]\e[0m $1"; }
echo_success() { echo -e "\e[32m[SUCCESS]\e[0m $1"; }
echo_error() { echo -e "\e[31m[ERROR]\e[0m $1"; exit 1; }

# ==============================================================================
# PHASE 1: IDENTITY
# ==============================================================================
echo_info "--- DevSecOps Factory v6.3.1 (Preparation Mode) ---"

GIT_USER="markffckyou12"
REPO_NAME="markffckyou12/cicd2"
DOCKER_USER="ffckyou123"
GIT_TOKEN=${GIT_TOKEN:-$(read -s -p "Enter GitHub PAT: " t && echo "$t")}
echo ""
DOCKER_PASS=${DOCKER_PASS:-$(read -s -p "Enter Docker Hub Password: " dp && echo "$dp")}
echo ""

NAMESPACE="tekton-tasks"
IMAGE_NAME="docker.io/$DOCKER_USER/cicd-test:latest"
TRIVY_SERVER_DEFAULT="http://host.minikube.internal:8080"
COSIGN_PASSWORD="factory-password-123"

# ==============================================================================
# PHASE 2: INFRASTRUCTURE
# ==============================================================================
echo_info "Creating Namespace & Deploying Tools..."
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f https://github.com/kyverno/kyverno/releases/download/v1.10.0/install.yaml --server-side
kubectl apply -f https://storage.googleapis.com/tekton-releases/pipeline/latest/release.yaml

echo_info "Waiting for Controllers..."
kubectl wait --for=condition=Available deployment/tekton-pipelines-controller -n tekton-pipelines --timeout=120s
kubectl wait --for=condition=Available deployment/kyverno-admission-controller -n kyverno --timeout=120s

# ==============================================================================
# PHASE 3: SECURITY & AUTH
# ==============================================================================
echo_info "Handling Cosign Keys and RBAC..."

# 1. Create the secret if it doesn't exist
if ! kubectl get secret cosign-keys -n "$NAMESPACE" >/dev/null 2>&1; then
    kubectl create rolebinding cosign-gen-binding --clusterrole=edit --serviceaccount="$NAMESPACE:default" --namespace="$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
    kubectl run cosign-gen -n "$NAMESPACE" --rm -i --restart=Never --image=gcr.io/projectsigstore/cosign:v2.2.1 --env="COSIGN_PASSWORD=$COSIGN_PASSWORD" -- generate-key-pair k8s://"$NAMESPACE"/cosign-keys
    kubectl delete rolebinding cosign-gen-binding -n "$NAMESPACE"
fi

PUBLIC_KEY=$(kubectl get secret cosign-keys -n "$NAMESPACE" -o jsonpath='{.data.cosign\.pub}' | base64 -d)

# 2. Setup ServiceAccount and RBAC
SA_NAME="build-bot"
kubectl create serviceaccount "$SA_NAME" -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# RBAC FIX: Explicitly allow build-bot to READ the secret for signing
kubectl create role secret-reader --verb=get,list --resource=secrets -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl create rolebinding build-bot-secret-read --role=secret-reader --serviceaccount="$NAMESPACE:$SA_NAME" -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# 3. Credentials
kubectl create secret generic github-creds --from-literal=username="$GIT_USER" --from-literal=password="$GIT_TOKEN" --type=kubernetes.io/basic-auth -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl annotate secret github-creds "tekton.dev/git-0=https://github.com" --overwrite -n "$NAMESPACE"

kubectl create secret docker-registry docker-hub-creds --docker-username="$DOCKER_USER" --docker-password="$DOCKER_PASS" --docker-server="https://index.docker.io/v1/" -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl annotate secret docker-hub-creds "tekton.dev/docker-0=https://index.docker.io/v1/" --overwrite -n "$NAMESPACE"

# Link secrets to SA
kubectl patch serviceaccount "$SA_NAME" -n "$NAMESPACE" -p "{\"secrets\": [{\"name\": \"docker-hub-creds\"}, {\"name\": \"cosign-keys\"}, {\"name\": \"github-creds\"}]}"

# 4. PVC
cat <<EOF | kubectl apply -n "$NAMESPACE" -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: shared-ci-pvc
spec:
  accessModes: [ReadWriteOnce]
  resources: { requests: { storage: 2Gi } }
EOF

# 5. Kyverno Policy
cat <<EOF | kubectl apply -f -
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: enforce-signed-images
spec:
  validationFailureAction: Enforce
  background: false
  rules:
    - name: verify-signature
      match:
        any:
        - resources:
            kinds: ["Pod"]
            namespaces: ["$NAMESPACE", "default"]
      verifyImages:
        - imageReferences: ["docker.io/$DOCKER_USER/*"]
          attestors:
            - entries:
              - keys:
                  publicKeys: |-
$(echo "$PUBLIC_KEY" | sed 's/^/                    /')
EOF

# ==============================================================================
# PHASE 4: THE PIPELINE
# ==============================================================================
echo_info "Defining Pipeline..."

cat <<EOF | kubectl apply -n "$NAMESPACE" -f -
apiVersion: tekton.dev/v1
kind: Pipeline
metadata:
  name: devsecops-pipeline
spec:
  params:
    - name: repo-url
      default: "https://github.com/$REPO_NAME.git"
    - name: image-full-name
      default: "$IMAGE_NAME"
    - name: trivy-server-url
      default: "$TRIVY_SERVER_DEFAULT"
  workspaces:
    - name: shared-data
  tasks:
    - name: fetch-repo
      taskRef: { resolver: hub, params: [{name: kind, value: task}, {name: name, value: git-clone}, {name: version, value: "0.9"}] }
      workspaces: [{ name: output, workspace: shared-data }]
      params: [{ name: url, value: "\$(params.repo-url)" }]

    - name: source-scan
      runAfter: ["fetch-repo"]
      workspaces: [{ name: source, workspace: shared-data }]
      params: [{ name: trivy-server-url, value: "\$(params.trivy-server-url)" }]
      taskSpec:
        params: [{ name: trivy-server-url, type: string }]
        workspaces: [{ name: source }]
        steps:
          - name: trivy-fs-scan
            image: aquasec/trivy:latest
            workingDir: \$(workspaces.source.path)
            script: |
              trivy fs --server \$(params.trivy-server-url) --severity HIGH,CRITICAL .

    - name: build-and-push
      runAfter: ["source-scan"]
      workspaces: [{ name: source, workspace: shared-data }]
      params: [{ name: image-full-name, value: "\$(params.image-full-name)" }]
      taskSpec:
        params: [{ name: image-full-name, type: string }]
        workspaces: [{ name: source }]
        steps:
          - name: buildah
            image: quay.io/buildah/stable:v1.30
            workingDir: \$(workspaces.source.path)
            env: [{ name: REGISTRY_AUTH_FILE, value: /tekton/creds/.docker/config.json }]
            script: |
              buildah bud --storage-driver=vfs -f ./Dockerfile -t \$(params.image-full-name) .
              buildah push --storage-driver=vfs \$(params.image-full-name)

    - name: sign-image
      runAfter: ["build-and-push"]
      params: [{ name: image-full-name, value: "\$(params.image-full-name)" }]
      taskSpec:
        params: [{ name: image-full-name, type: string }]
        steps:
          - name: cosign-sign
            image: gcr.io/projectsigstore/cosign:v2.2.1
            command: ["cosign"]
            args:
              - "sign"
              - "--key"
              - "k8s://$NAMESPACE/cosign-keys"
              - "--yes"
              - "\$(params.image-full-name)"
            env: 
              - name: COSIGN_PASSWORD
                value: "$COSIGN_PASSWORD"
              - name: REGISTRY_AUTH_FILE
                value: /tekton/creds/.docker/config.json

    - name: image-scan
      runAfter: ["sign-image"]
      params: [{ name: image-full-name, value: "\$(params.image-full-name)" }, { name: trivy-server-url, value: "\$(params.trivy-server-url)" }]
      taskSpec:
        params: [{name: image-full-name, type: string}, {name: trivy-server-url, type: string}]
        steps:
          - name: trivy-image-scan
            image: aquasec/trivy:latest
            script: |
              trivy image --server \$(params.trivy-server-url) --severity HIGH,CRITICAL \$(params.image-full-name)
EOF

echo_success "SETUP COMPLETE - V6.3.1 Ready."

# ==============================================================================
# PHASE 5: TEST COMMAND ECHO
# ==============================================================================
echo "-----------------------------------------------------------------------"
echo_info "To test your pipeline, run the following command:"
echo ""
echo "tkn pipeline start devsecops-pipeline \\"
echo "  --workspace name=shared-data,claimName=shared-ci-pvc \\"
echo "  --serviceaccount $SA_NAME \\"
echo "  --param repo-url=\"https://github.com/$REPO_NAME.git\" \\"
echo "  --param image-full-name=\"$IMAGE_NAME\" \\"
echo "  --param trivy-server-url=\"$TRIVY_SERVER_DEFAULT\" \\"
echo "  -n $NAMESPACE \\"
echo "  --showlog"
echo "-----------------------------------------------------------------------"c
