#!/bin/bash
BLUE='\033[0;34m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'

echo -e "${BLUE}=======================================${NC}"
echo -e "${BLUE}    TEKTON SMART RUNNER v5.3           ${NC}"
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
    sleep 2
    tkn pipelinerun logs "$SHORT_NAME" -f -n "$NAMESPACE"
else
    echo -e " ❌\n${RED}Error: Failed to submit.${NC}"
fi
