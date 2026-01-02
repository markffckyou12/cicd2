#!/bin/bash
BLUE='\033[0;34m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

echo -e "${BLUE}=======================================${NC}"
echo -e "${BLUE}    TEKTON SMART RUNNER v5.5           ${NC}"
echo -e "${BLUE}=======================================${NC}"

# Context Detection
DEFAULT_REPO=$(git config --get remote.origin.url 2>/dev/null || echo "https://github.com/user/repo")
DEFAULT_IMAGE=$(basename "$PWD" 2>/dev/null || echo "myapp")
GIT_SHA=$(git rev-parse --short HEAD 2>/dev/null || echo "no-git")
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
NAMESPACE="tekton-tasks"

read -p "📂 Repo URL  [$DEFAULT_REPO]: " REPO_URL
REPO_URL=${REPO_URL:-$DEFAULT_REPO}
read -p "📦 Image Name [$DEFAULT_IMAGE]: " IMAGE_NAME
IMAGE_NAME=${IMAGE_NAME:-$DEFAULT_IMAGE}

IMAGE_TAG="${BRANCH}-${GIT_SHA}"
FULL_IMAGE_PATH="docker.io/${DOCKER_USER:-$(kubectl get secret docker-hub-creds -n $NAMESPACE -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d | jq -r '.auths["https://index.docker.io/v1/"].username')}/$IMAGE_NAME:$IMAGE_TAG"

echo -ne "📡 Submitting PipelineRun..."
RUN_NAME=$(cat <<EOF | kubectl create -f - -o name
apiVersion: tekton.dev/v1beta1
kind: PipelineRun
metadata:
  generateName: ci-run-
  namespace: $NAMESPACE
spec:
  pipelineRef:
    name: universal-ci-pipeline
  serviceAccountName: build-bot
  params:
    - name: repo-url
      value: "$REPO_URL"
    - name: repo-revision
      value: "$BRANCH"
    - name: image-name
      value: "$IMAGE_NAME"
    - name: image-tag
      value: "$IMAGE_TAG"
  workspaces:
    - name: shared-data
      persistentVolumeClaim:
        claimName: tekton-pvc
EOF
)

if [ $? -eq 0 ]; then
    echo -e " ✅"
    SHORT_NAME=${RUN_NAME#pipelinerun.tekton.dev/}
    echo -e "${GREEN}✨ Tracking:${NC} $SHORT_NAME"
    
    # Follow the logs
    tkn pipelinerun logs "$SHORT_NAME" -f -n "$NAMESPACE"
    
    # --- NEW: POST-BUILD DEPLOYMENT PHASE ---
    # Check if the pipeline actually succeeded before deploying
    STATUS=$(tkn pipelinerun describe "$SHORT_NAME" -n "$NAMESPACE" -o jsonpath='{.status.conditions[0].reason}')
    
    if [ "$STATUS" == "Succeeded" ]; then
        echo -e "\n${GREEN}🚀 Build Verified & Signed. Deploying to Cluster...${NC}"
        
        # Apply Deployment & Service
        cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $IMAGE_NAME
  namespace: $NAMESPACE
  labels: { app: $IMAGE_NAME }
spec:
  replicas: 1
  selector:
    matchLabels: { app: $IMAGE_NAME }
  template:
    metadata:
      labels: { app: $IMAGE_NAME }
    spec:
      containers:
      - name: app
        image: $FULL_IMAGE_PATH
        ports: [{ containerPort: 8080 }]
---
apiVersion: v1
kind: Service
metadata:
  name: $IMAGE_NAME-service
  namespace: $NAMESPACE
spec:
  type: ClusterIP
  selector: { app: $IMAGE_NAME }
  ports: [{ port: 80, targetPort: 8080 }]
EOF

        echo -e "${GREEN}✅ Deployment successful!${NC}"
        kubectl get pods -n "$NAMESPACE" -l app="$IMAGE_NAME"
    else
        echo -e "\n${RED}❌ Pipeline failed with status: $STATUS. Skipping deployment.${NC}"
        exit 1
    fi
else
    echo -e " ❌\n${RED}Error: Failed to submit.${NC}"
fi
