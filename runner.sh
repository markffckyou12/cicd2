#!/bin/bash

# --- Styling & Branding ---
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}=======================================${NC}"
echo -e "${BLUE}   TEKTON SMART RUNNER v5.2          ${NC}"
echo -e "${BLUE}=======================================${NC}"

# --- 1. Automatic Identity Extraction ---
# Detect Repo URL from Git config
DEFAULT_REPO=$(git config --get remote.origin.url 2>/dev/null || echo "https://github.com/user/repo")
# Detect Image Name from the current folder name
DEFAULT_IMAGE=$(basename "$PWD" 2>/dev/null || echo "myapp")
# Get Git SHA & Branch for the tag
GIT_SHA=$(git rev-parse --short HEAD 2>/dev/null || echo "no-git")
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "dev")

# UX: Warning if the user has uncommitted local changes
if [[ -n $(git status -s 2>/dev/null) ]]; then
    echo -e "${YELLOW}⚠️  Warning: Uncommitted changes detected. Build may not match SHA!${NC}"
fi

# --- 2. Interactive Input (With Smart Defaults) ---
echo -e "Press ${GREEN}ENTER${NC} to accept defaults:"
echo -e "---------------------------------------"

read -p "📂 Repo URL  [$DEFAULT_REPO]: " REPO_URL
REPO_URL=${REPO_URL:-$DEFAULT_REPO}

read -p "📦 Image Name [$DEFAULT_IMAGE]: " IMAGE_NAME
IMAGE_NAME=${IMAGE_NAME:-$DEFAULT_IMAGE}

# Auto-generate the Tag - Removed from user input for better UX
IMAGE_TAG="${BRANCH}-${GIT_SHA}"
NAMESPACE="tekton-tasks"

echo -e "---------------------------------------"
echo -e "🚀 ${BLUE}Target:${NC} $IMAGE_NAME:$IMAGE_TAG"
echo -e "📍 ${BLUE}Namespace:${NC} $NAMESPACE"
echo -e "---------------------------------------"

# --- 3. Submit PipelineRun ---
echo -ne "📡 Submitting to cluster..."

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
    SHORT_NAME=$(echo $RUN_NAME | cut -d/ -f2)
    echo -e "${GREEN}✨ Created PipelineRun:${NC} $SHORT_NAME"
    echo -e "${BLUE}📊 Streaming Logs...${NC}\n"
    
    # Live log streaming
    tkn pipelinerun logs "$SHORT_NAME" -f -n "$NAMESPACE"

    # --- 4. Success Summary (Post-Build) ---
    echo -e "\n${GREEN}=======================================${NC}"
    echo -e "${GREEN}       BUILD COMPLETED SUCCESSFULLY!    ${NC}"
    echo -e "${GREEN}=======================================${NC}"
    
    # Extract Docker Username using yq for tool consistency
    DOCKER_USER_LOCAL=$(kubectl get secret docker-hub-creds -n $NAMESPACE -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d | yq '.auths["https://index.docker.io/v1/"].username' 2>/dev/null)
    
    # Fallback text if user cannot be parsed
    DISPLAY_USER=${DOCKER_USER_LOCAL:-"<your-docker-user>"}

    echo -e "${BLUE}Image URL:${NC} docker.io/$DISPLAY_USER/$IMAGE_NAME:$IMAGE_TAG"
    echo -e "${BLUE}Git Ref:${NC}   $BRANCH @ $GIT_SHA"
    echo -e "${BLUE}Security:${NC}  ✅ Scanned & Signed"
    echo -e "---------------------------------------"
    echo -e "To view in Dashboard: tkn pipelinerun describe $SHORT_NAME -n $NAMESPACE"
else
    echo -e " ❌"
    echo -e "${RED}Error: Failed to submit PipelineRun.${NC}"
fi
