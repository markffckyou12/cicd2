#!/bin/bash

# --- Helper Functions ---
echo_info() { echo -e "\e[34m[INFO]\e[0m $1"; }
echo_success() { echo -e "\e[32m[SUCCESS]\e[0m $1"; }
echo_error() { echo -e "\e[31m[ERROR]\e[0m $1"; exit 1; }

# --- Step 0: Pre-flight Checks & Auto-Install ---

# 1. Check Kubernetes Cluster
echo_info "Checking Kubernetes cluster connection..."
if ! kubectl cluster-info > /dev/null 2>&1; then
    echo_error "No Kubernetes cluster found. Please check your kubeconfig or cloud connection."
fi
echo_success "Cluster is reachable."

# 2. Check Helm
if ! command -v helm &> /dev/null; then
    echo_info "Helm not found. Installing Helm..."
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
else
    echo_success "Helm is already installed."
fi

# 3. Check kubeseal CLI
if ! command -v kubeseal &> /dev/null; then
    echo_info "kubeseal CLI not found. Installing version 0.33.1..."
    KUBESEAL_VERSION="0.33.1"
    curl -L "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz" | tar xz
    sudo install -m 755 kubeseal /usr/local/bin/kubeseal
    rm kubeseal # cleanup extracted file
else
    echo_success "kubeseal CLI is already installed."
fi

# 4. Check Sealed Secrets Controller in Cluster
echo_info "Checking for Sealed Secrets Controller in cluster..."
if ! kubectl get pods -A -l app.kubernetes.io/name=sealed-secrets | grep -q "Running"; then
    echo_info "Controller not found. Installing via Helm..."
    helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
    helm repo update
    helm install sealed-secrets-controller sealed-secrets/sealed-secrets --namespace kube-system
    echo_info "Waiting for controller to start..."
    kubectl rollout status deployment/sealed-secrets-controller -n kube-system --timeout=60s
else
    echo_success "Sealed Secrets Controller is active."
fi

# --- 1. GitHub Credentials ---
read -p "Enter GitHub Username: " GIT_USER
read -s -p "Enter GitHub Personal Access Token (PAT): " GIT_TOKEN
echo ""

echo_info "Testing GitHub credentials..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -u "$GIT_USER:$GIT_TOKEN" https://api.github.com/user)
if [ "$HTTP_CODE" -eq 200 ]; then
    echo_success "GitHub login successful."
else
    echo_error "GitHub login failed (HTTP $HTTP_CODE)."
fi

# --- 2. Docker Credentials ---
read -p "Enter Docker Hub Username: " DOCKER_USER
read -s -p "Enter Docker Hub Password/Token: " DOCKER_PASS
echo ""

echo_info "Testing Docker credentials..."
echo "$DOCKER_PASS" | docker login --username "$DOCKER_USER" --password-stdin > /dev/null 2>&1
if [ $? -eq 0 ]; then
    echo_success "Docker login successful."
else
    echo_error "Docker login failed."
fi

# --- 3. Resource Naming ---
read -p "Enter Service Account name [default: build-bot]: " SA_NAME
SA_NAME=${SA_NAME:-build-bot}

# --- 4. Create SEALED Secrets ---
echo_info "Encrypting secrets into SealedSecret YAML files..."

kubectl create secret docker-registry docker-hub-creds \
  --docker-username="$DOCKER_USER" \
  --docker-password="$DOCKER_PASS" \
  --docker-server="https://index.docker.io/v1/" \
  --dry-run=client -o yaml | kubeseal --format=yaml > docker-hub-sealed.yaml

kubectl create secret generic git-creds \
  --from-literal=username="$GIT_USER" \
  --from-literal=password="$GIT_TOKEN" \
  --type=kubernetes.io/basic-auth \
  --dry-run=client -o yaml | kubeseal --format=yaml > git-creds-sealed.yaml

echo_success "Generated docker-hub-sealed.yaml and git-creds-sealed.yaml"

# --- 5. Apply & Configure ---
echo_info "Applying to cluster and linking to Service Account..."
kubectl apply -f docker-hub-sealed.yaml
kubectl apply -f git-creds-sealed.yaml

# Give the controller time to create the real secrets
echo_info "Waiting for secrets to unseal..."
sleep 5

kubectl annotate secret docker-hub-creds --overwrite tekton.dev/docker-0=https://index.docker.io/v1/
kubectl annotate secret git-creds --overwrite tekton.dev/git-0=https://github.com

kubectl create serviceaccount "$SA_NAME" --dry-run=client -o yaml | kubectl apply -f -
kubectl patch serviceaccount "$SA_NAME" -p "{\"secrets\": [{\"name\": \"docker-hub-creds\"}, {\"name\": \"git-creds\"}]}"

echo_success "All done! You can now commit the .yaml files to your Git repo."
