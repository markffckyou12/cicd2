#!/bin/bash
set -euo pipefail 

# --- A. THE SAFETY TRAP ---
# Ensures temporary RBAC is removed even if the script crashes
cleanup() {
  echo -e "\n\e[33m[CLEANUP]\e[0m Removing temporary security badges..."
  kubectl delete rolebinding cosign-gen-binding -n tekton-tasks --ignore-not-found
}
trap cleanup EXIT

echo -e "\e[34m[INFO]\e[0m --- DevSecOps Factory v6.9.3 (Native Janitor Edition) ---"

# --- 1. IDENTITY & CONFIGURATION ---
GIT_USER="markffckyou12"
REPO_NAME="markffckyou12/cicd2"
DOCKER_USER="ffckyou123"
NAMESPACE="tekton-tasks"
IMAGE_NAME="docker.io/$DOCKER_USER/cicd-test:latest"
TRIVY_SERVER_URL="http://host.minikube.internal:8080"
COSIGN_PASSWORD="factory-password-123"
SA_NAME="build-bot"

# --- 2. CREDENTIAL CHECK ---
if [ -z "${GIT_TOKEN:-}" ]; then read -s -p "Enter GitHub PAT: " GIT_TOKEN; echo ""; fi
if [ -z "${DOCKER_PASS:-}" ]; then read -s -p "Enter Docker Hub Password: " DOCKER_PASS; echo ""; fi

# --- 3. NAMESPACE & KYVERNO INFRA EXCLUSIONS ---
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Patching Kyverno config to ensure it doesn't interfere with internal Tekton/Cosign pods
kubectl patch configmap kyverno -n kyverno --type merge -p "{\"data\":{\"resourceFilters\":\"[Event,*,*][Node,*,*][APIService,*,*][TokenReview,*,*][SubjectAccessReview,*,*][SelfSubjectAccessReview,*,*][*,kyverno,*][Binding,*,*][ReplicaSet,*,*][AdmissionReport,*,*][ClusterAdmissionReport,*,*][BackgroundScanReport,*,*][ClusterBackgroundScanReport,*,*][*,tekton-tasks,cosign-gen*][*,tekton-tasks,affinity-assistant-*]\"}}"

# --- 4. SECURE KEY GENERATION ---
if ! kubectl get secret cosign-keys -n "$NAMESPACE" >/dev/null 2>&1; then
    echo -e "\e[34m[INFO]\e[0m Creating temporary RBAC for key generation..."
    kubectl create rolebinding cosign-gen-binding --clusterrole=edit --serviceaccount="$NAMESPACE:default" --namespace="$NAMESPACE"
    
    kubectl run cosign-gen -n "$NAMESPACE" --rm -i --restart=Never \
      --image=gcr.io/projectsigstore/cosign:v2.2.1 \
      --env="COSIGN_PASSWORD=$COSIGN_PASSWORD" -- generate-key-pair k8s://"$NAMESPACE"/cosign-keys
fi

PUBLIC_KEY=$(kubectl get secret cosign-keys -n "$NAMESPACE" -o jsonpath='{.data.cosign\.pub}' | base64 -d)

# --- 5. PERMANENT RBAC & AUTH ---
kubectl create serviceaccount "$SA_NAME" -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: cosign-secret-reader
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
  name: build-bot-read-cosign
  namespace: $NAMESPACE
subjects:
- kind: ServiceAccount
  name: $SA_NAME
  namespace: $NAMESPACE
roleRef:
  kind: Role
  name: cosign-secret-reader
  apiGroup: rbac.authorization.k8s.io
EOF

# Credentials Setup
kubectl create secret generic github-creds --from-literal=username="$GIT_USER" --from-literal=password="$GIT_TOKEN" --type=kubernetes.io/basic-auth -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl annotate secret github-creds "tekton.dev/git-0=https://github.com" --overwrite -n "$NAMESPACE"
kubectl create secret docker-registry docker-hub-creds --docker-username="$DOCKER_USER" --docker-password="$DOCKER_PASS" --docker-server="https://index.docker.io/v1/" -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl annotate secret docker-hub-creds "tekton.dev/docker-0=https://index.docker.io/v1/" --overwrite -n "$NAMESPACE"
kubectl patch serviceaccount "$SA_NAME" -n "$NAMESPACE" -p "{\"secrets\": [{\"name\": \"docker-hub-creds\"}, {\"name\": \"cosign-keys\"}, {\"name\": \"github-creds\"}]}"

# PVC for Pipeline Workspace
cat <<EOF | kubectl apply -n "$NAMESPACE" -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: shared-ci-pvc
spec:
  accessModes: [ReadWriteOnce]
  resources: { requests: { storage: 2Gi } }
EOF

# --- 6. THE GLOBAL BOUNCER (ClusterPolicy) ---
echo -e "\e[34m[INFO]\e[0m Deploying Global ClusterPolicy..."
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
            namespaces: ["kube-system", "kyverno", "$NAMESPACE", "tekton-pipelines"]
      verifyImages:
        - imageReferences: ["*"]
          attestors:
            - entries:
              - keys:
                  publicKeys: |-
$(echo "$PUBLIC_KEY" | sed 's/^/                    /')
EOF

# --- 7. THE PIPELINE (With Integrated Janitor) ---
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
            args: ["sign", "--key", "k8s://$NAMESPACE/cosign-keys", "--tlog-upload=false", "--yes", "\$(params.image-full-name)"]
            env: 
              - name: COSIGN_PASSWORD
                value: "$COSIGN_PASSWORD"
              - name: REGISTRY_AUTH_FILE
                value: /tekton/creds/.docker/config.json
    - name: security-gate
      runAfter: ["sign-image"]
      params: [{ name: image-full-name, value: "\$(params.image-full-name)" }]
      taskSpec:
        params: [{name: image-full-name, type: string}]
        steps:
          - name: trivy-image-scan
            image: aquasec/trivy:latest
            script: |
              trivy image --server http://host.minikube.internal:8080 --severity CRITICAL --exit-code 1 \$(params.image-full-name)
  
  # --- THE NATIVE JANITOR ---
  # This 'finally' block runs even if tasks above fail. 
  # It wipes the storage volume so your disk usage stays low.
  finally:
    - name: cleanup-workspace
      workspaces:
        - name: source
          workspace: shared-data
      taskSpec:
        workspaces:
          - name: source
        steps:
          - name: wipe-files
            image: alpine
            script: |
              echo "Cleaning up shared storage..."
              rm -rf \$(workspaces.source.path)/*
EOF

echo -e "\e[32m[SUCCESS]\e[0m SETUP COMPLETE - V6.9.3 Ready."
