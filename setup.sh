#!/bin/bash
set -euo pipefail 

# --- A. SAFETY TRAP ---
cleanup() {
  echo -e "\n\e[33m[CLEANUP]\e[0m Cleaning up temporary build artifacts..."
  kubectl delete rolebinding cosign-gen-binding -n tekton-tasks --ignore-not-found || true
}
trap cleanup EXIT

echo -e "\e[34m[INFO]\e[0m --- DevSecOps Factory v8.8 (Darwin/macOS Ready) ---"

# --- 1. CONFIGURATION ---
GIT_USER="markffckyou12"
REPO_NAME="markffckyou12/cicd2"
DOCKER_USER="ffckyou123"
NAMESPACE="tekton-tasks"
IMAGE_NAME="docker.io/$DOCKER_USER/cicd-test:latest"
TRIVY_SERVER_URL="http://trivy-server.trivy-system.svc.cluster.local:8080"
LOKI_URL="http://loki-server.trivy-system.svc.cluster.local:3100/loki/api/v1/push"
COSIGN_PASSWORD="factory-password-123"
SA_NAME="build-bot"

# --- 2. PREREQUISITE INSTALLATION (YOUR STEPS) ---

# 2.1 Install Tekton CLI (tkn)
if ! command -v tkn &> /dev/null; then
  echo -e "\e[33m[INSTALL]\e[0m Installing Tekton CLI (v0.43.0)..."
  curl -LO https://github.com/tektoncd/cli/releases/download/v0.43.0/tkn_0.43.0_Darwin_all.tar.gz
  sudo tar xvzf tkn_0.43.0_Darwin_all.tar.gz -C /usr/local/bin tkn
  rm tkn_0.43.0_Darwin_all.tar.gz
fi

# 2.2 Install Tekton Pipelines
echo -e "\e[33m[INSTALL]\e[0m Applying Tekton Pipelines..."
kubectl apply --filename https://storage.googleapis.com/tekton-releases/pipeline/latest/release.yaml

# 2.3 Install Kyverno via Helm
if ! command -v helm &> /dev/null; then
    echo -e "\e[31m[ERROR]\e[0m Helm is not installed. Please install it first:"
    echo "brew install helm"
    exit 1
fi

echo -e "\e[33m[INSTALL]\e[0m Installing Kyverno via Helm..."
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update
helm upgrade --install kyverno kyverno/kyverno -n kyverno --create-namespace

# Wait for infrastructure to be ready
echo -e "\e[34m[WAIT]\e[0m Waiting for controllers to start..."
kubectl wait --for=condition=Ready pods --all -n tekton-pipelines --timeout=60s || true
kubectl wait --for=condition=Ready pods --all -n kyverno --timeout=60s || true

# --- 3. CREDENTIALS ---
if [ -z "${GIT_TOKEN:-}" ]; then read -s -p "Enter GitHub PAT: " GIT_TOKEN; echo ""; fi
if [ -z "${DOCKER_PASS:-}" ]; then read -s -p "Enter Docker Hub Password: " DOCKER_PASS; echo ""; fi

# --- 4. KYVERNO PERMISSIONS ---
echo -e "\e[34m[INFO]\e[0m Granting Cleanup Controller permissions for Tekton..."
cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kyverno:cleanup-tekton
rules:
- apiGroups: ["tekton.dev"]
  resources: ["pipelineruns", "taskruns"]
  verbs: ["get", "list", "watch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kyverno:cleanup-tekton
subjects:
- kind: ServiceAccount
  name: kyverno-cleanup-controller
  namespace: kyverno
roleRef:
  kind: ClusterRole
  name: kyverno:cleanup-tekton
  apiGroup: rbac.authorization.k8s.io
EOF

# --- 5. INFRASTRUCTURE & RBAC ---
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

if ! kubectl get secret cosign-keys -n "$NAMESPACE" >/dev/null 2>&1; then
    kubectl create rolebinding cosign-gen-binding --clusterrole=edit --serviceaccount="$NAMESPACE:default" --namespace="$NAMESPACE"
    kubectl run cosign-gen -n "$NAMESPACE" --rm -i --restart=Never \
      --image=gcr.io/projectsigstore/cosign:v2.2.1 \
      --env="COSIGN_PASSWORD=$COSIGN_PASSWORD" -- generate-key-pair k8s://"$NAMESPACE"/cosign-keys
fi
PUBLIC_KEY=$(kubectl get secret cosign-keys -n "$NAMESPACE" -o jsonpath='{.data.cosign\.pub}' | base64 -d)

# Pipeline Secrets & SA
kubectl create serviceaccount "$SA_NAME" -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic github-creds --from-literal=username="$GIT_USER" --from-literal=password="$GIT_TOKEN" --type=kubernetes.io/basic-auth -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl annotate secret github-creds "tekton.dev/git-0=https://github.com" --overwrite -n "$NAMESPACE"
kubectl create secret docker-registry docker-hub-creds --docker-username="$DOCKER_USER" --docker-password="$DOCKER_PASS" --docker-server="https://index.docker.io/v1/" -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl annotate secret docker-hub-creds "tekton.dev/docker-0=https://index.docker.io/v1/" --overwrite -n "$NAMESPACE"
kubectl patch serviceaccount "$SA_NAME" -n "$NAMESPACE" -p "{\"secrets\": [{\"name\": \"docker-hub-creds\"}, {\"name\": \"cosign-keys\"}, {\"name\": \"github-creds\"}]}"

# --- 6. THE POLICIES ---
echo -e "\e[34m[INFO]\e[0m Deploying Enforcement and Janitor Policies..."
cat <<EOF | kubectl apply -f -
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: enforce-signed-images
spec:
  validationFailureAction: Enforce
  background: false
  rules:
    - name: verify-all-images
      match:
        any:
        - resources:
            kinds: ["Pod"]
      exclude:
        any:
        - resources:
            namespaces: ["kube-system", "kyverno", "$NAMESPACE", "tekton-pipelines", "trivy-system"]
      verifyImages:
        - imageReferences: ["*"]
          attestors:
            - entries:
              - keys:
                  publicKeys: |-
$(echo "$PUBLIC_KEY" | sed 's/^/                    /')
                  rekor:
                    ignoreTlog: true
---
apiVersion: kyverno.io/v2
kind: CleanupPolicy
metadata:
  name: cleanup-success-only
  namespace: $NAMESPACE
spec:
  match:
    any:
    - resources:
        kinds: ["tekton.dev/v1/PipelineRun"]
  schedule: "*/10 * * * *"
  conditions:
    all:
    - key: "{{ target.status.conditions[0].status }}"
      operator: Equals
      value: "True"
EOF

# --- 7. THE TEKTON PIPELINE ---
echo -e "\e[34m[INFO]\e[0m Deploying DevSecOps Pipeline..."
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
      default: "$TRIVY_SERVER_URL"
    - name: loki-url
      default: "$LOKI_URL"
  workspaces: [{ name: shared-data }]
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
            script: |
              trivy fs --server \$(params.trivy-server-url) --severity HIGH,CRITICAL \$(workspaces.source.path)
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
            args: ["sign", "--key", "k8s://$NAMESPACE/cosign-keys", "--tlog-upload=false", "--yes", "\$(params.image-full-name)"]
            env: 
              - name: COSIGN_PASSWORD
                value: "$COSIGN_PASSWORD"
              - name: REGISTRY_AUTH_FILE
                value: /tekton/creds/.docker/config.json
    - name: security-gate
      runAfter: ["sign-image"]
      params:
        - name: image-full-name
          value: "\$(params.image-full-name)"
        - name: trivy-server-url
          value: "\$(params.trivy-server-url)"
        - name: loki-url
          value: "\$(params.loki-url)"
      taskSpec:
        params:
          - name: image-full-name
            type: string
          - name: trivy-server-url
            type: string
          - name: loki-url
            type: string
        steps:
          - name: trivy-image-scan-and-audit
            image: aquasec/trivy:latest
            script: |
              trivy image --server \$(params.trivy-server-url) --severity CRITICAL --exit-code 0 --format json --output report.json \$(params.image-full-name)
              CRIT_COUNT=\$(grep -c "VulnerabilityID" report.json || echo "0")
              
              cat <<EOF_JSON > payload.json
              {
                "streams": [
                  {
                    "stream": { "job": "security-gate", "image": "\$(params.image-full-name)" },
                    "values": [ [ "\$(date +%s)000000000", "Audit: Found \$CRIT_COUNT critical vulnerabilities." ] ]
                  }
                ]
              }
              EOF_JSON

              echo "Pushing Audit Log to Loki..."
              wget --header="Content-Type: application/json" --post-file=payload.json -O- \$(params.loki-url) || echo "Loki push failed"
              trivy image --server \$(params.trivy-server-url) --severity CRITICAL --exit-code 1 \$(params.image-full-name)
EOF

echo -e "\e[32m[SUCCESS]\e[0m Infrastructure and Pipeline deployed successfully."
