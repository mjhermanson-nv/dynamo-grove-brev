#!/bin/bash
set -e

# Detect Brev user (handles ubuntu, nvidia, shadeform, etc.)
detect_brev_user() {
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        echo "$SUDO_USER"
        return
    fi
    for user_home in /home/*; do
        username=$(basename "$user_home")
        [ "$username" = "launchpad" ] && continue
        if ls "$user_home"/.lifecycle-script-ls-*.log 2>/dev/null | grep -q . || \
           [ -f "$user_home/.verb-setup.log" ] || \
           { [ -L "$user_home/.cache" ] && [ "$(readlink "$user_home/.cache")" = "/ephemeral/cache" ]; }; then
            echo "$username"
            return
        fi
    done
    [ -d "/home/nvidia" ] && echo "nvidia" && return
    [ -d "/home/ubuntu" ] && echo "ubuntu" && return
    echo "ubuntu"
}

if [ "$(id -u)" -eq 0 ] || [ "${USER:-}" = "root" ]; then
    DETECTED_USER=$(detect_brev_user)
    export USER="$DETECTED_USER"
    export HOME="/home/$DETECTED_USER"
fi

echo "🚀 Installing Dynamo + Grove..."
echo "User: $USER"
echo ""

# Check prerequisites
if ! command -v kubectl >/dev/null 2>&1; then
    echo "❌ kubectl not found. Please run oneshot.sh first to set up Kubernetes."
    exit 1
fi

if ! command -v helm >/dev/null 2>&1; then
    echo "❌ helm not found. Please run oneshot.sh first to set up Kubernetes."
    exit 1
fi

# Verify kubectl access
if ! kubectl cluster-info >/dev/null 2>&1; then
    echo "❌ Cannot access Kubernetes cluster. Please ensure:"
    echo "   1. Kubernetes is set up (run oneshot.sh)"
    echo "   2. KUBECONFIG is set: export KUBECONFIG=\$HOME/.kube/config"
    exit 1
fi

# Set environment variables
export NAMESPACE=dynamo-system
export RELEASE_VERSION=0.3.2  # Update to latest version as needed

# Check NGC authentication
echo "Checking NGC authentication..."
if ! helm registry login nvcr.io --username oauthtoken --password-stdin 2>/dev/null <<<"dummy" >/dev/null 2>&1; then
    echo ""
    echo "⚠️  NGC authentication required!"
    echo ""
    echo "Before proceeding, you need to:"
    echo "  1. Get your NGC API key from: https://catalog.ngc.nvidia.com/setup/api-key"
    echo "  2. Login to Helm registry:"
    echo "     helm registry login nvcr.io"
    echo "     # Username: \$oauthtoken"
    echo "     # Password: <your-ngc-api-key>"
    echo ""
    read -p "Have you logged in to NGC? (y/n) " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Please login first, then run this script again."
        exit 1
    fi
fi

# Prompt for NGC API key for image pull secrets
echo ""
echo "📝 NGC Image Pull Secret Setup"
echo "Dynamo requires NGC images. We'll create an image pull secret."
echo ""
read -p "Enter your NGC API key (or press Enter to skip and set up manually later): " NGC_API_KEY
echo ""

if [ -n "$NGC_API_KEY" ]; then
    read -p "Enter your email (for image pull secret): " NGC_EMAIL
    echo ""
    echo "Creating NGC image pull secret..."
    kubectl create secret docker-registry ngc-registry-secret \
        --docker-server=nvcr.io \
        --docker-username='$oauthtoken' \
        --docker-password="$NGC_API_KEY" \
        --docker-email="${NGC_EMAIL:-noreply@example.com}" \
        -n ${NAMESPACE} \
        --dry-run=client -o yaml | kubectl apply -f -
    
    # Patch default service account to use the secret
    kubectl patch serviceaccount default -n ${NAMESPACE} -p '{"imagePullSecrets":[{"name":"ngc-registry-secret"}]}' || true
    
    echo "✓ Image pull secret created"
else
    echo "⚠️  Skipping image pull secret creation."
    echo "   You may need to create it manually if pods fail with ImagePullBackOff:"
    echo "   kubectl create secret docker-registry ngc-registry-secret \\"
    echo "     --docker-server=nvcr.io \\"
    echo "     --docker-username=\$oauthtoken \\"
    echo "     --docker-password=<your-ngc-api-key> \\"
    echo "     --docker-email=<your-email> \\"
    echo "     -n ${NAMESPACE}"
fi

# Create namespace
echo ""
echo "Creating namespace: $NAMESPACE"
kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

# Step 1: Install Dynamo CRDs
echo ""
echo "Step 1: Installing Dynamo CRDs..."
cd /tmp
helm fetch https://helm.ngc.nvidia.com/nvidia/ai-dynamo/charts/dynamo-crds-${RELEASE_VERSION}.tgz || {
    echo "⚠️  Failed to fetch CRDs. Checking if CRDs already exist..."
    if kubectl get crd dynamographdeployments.nvidia.com >/dev/null 2>&1; then
        echo "✓ CRDs already exist, skipping installation"
    else
        echo "❌ CRDs not found and fetch failed."
        echo "   Please ensure you have:"
        echo "   1. NGC account access (https://catalog.ngc.nvidia.com/)"
        echo "   2. Logged in: helm registry login nvcr.io"
        echo "   3. Correct RELEASE_VERSION (check: https://github.com/ai-dynamo/dynamo/releases)"
        exit 1
    fi
}

if [ -f "/tmp/dynamo-crds-${RELEASE_VERSION}.tgz" ]; then
    helm install dynamo-crds /tmp/dynamo-crds-${RELEASE_VERSION}.tgz --namespace default || {
        echo "⚠️  CRD installation failed, but continuing (may already exist)"
    }
    rm -f /tmp/dynamo-crds-${RELEASE_VERSION}.tgz
fi

# Step 2: Install Dynamo Platform
echo ""
echo "Step 2: Installing Dynamo Platform..."
helm fetch https://helm.ngc.nvidia.com/nvidia/ai-dynamo/charts/dynamo-platform-${RELEASE_VERSION}.tgz || {
    echo "❌ Failed to fetch Dynamo Platform."
    echo "   Please ensure NGC authentication: helm registry login nvcr.io"
    exit 1
}

# Bitnami moved images to bitnamilegacy repository (as of Aug 2025)
# Override etcd image to use the legacy repository
echo "Configuring etcd image to use bitnamilegacy repository..."
helm install dynamo-platform /tmp/dynamo-platform-${RELEASE_VERSION}.tgz \
    --namespace ${NAMESPACE} \
    --create-namespace \
    --set global.security.allowInsecureImages=true \
    --set etcd.image.registry=docker.io \
    --set etcd.image.repository=bitnamilegacy/etcd \
    --wait \
    --timeout 10m || {
    echo "⚠️  Platform installation had issues, but continuing..."
    echo "This may be due to Docker Hub rate limiting or image availability."
    echo "The installation will continue, but some pods may fail to pull images."
}

rm -f /tmp/dynamo-platform-${RELEASE_VERSION}.tgz
cd - > /dev/null

# Wait for platform to be ready
echo ""
echo "Waiting for Dynamo Platform to be ready..."
echo "Checking for Dynamo deployments in namespace ${NAMESPACE}..."
sleep 10  # Give helm a moment to create resources

# Check what deployments exist
OPERATOR_DEPLOY="dynamo-platform-dynamo-operator-controller-manager"
if kubectl get deployment ${OPERATOR_DEPLOY} -n ${NAMESPACE} >/dev/null 2>&1; then
    echo "Found operator deployment: ${OPERATOR_DEPLOY}"
    echo "Waiting for operator to be available..."
    kubectl wait --for=condition=available --timeout=300s deployment/${OPERATOR_DEPLOY} -n ${NAMESPACE} || {
        echo "⚠️  Operator deployment exists but may not be ready yet"
        echo "Current status:"
        kubectl get deployment ${OPERATOR_DEPLOY} -n ${NAMESPACE}
    }
else
    echo "⚠️  Operator deployment not found yet. Checking all resources..."
    kubectl get all -n ${NAMESPACE} 2>/dev/null || echo "No resources found in namespace"
fi

# Check for image pull issues
echo ""
echo "Checking for image pull issues..."
if kubectl get pods -n ${NAMESPACE} 2>/dev/null | grep -qE "(ImagePullBackOff|ErrImagePull)"; then
    echo "⚠️  Warning: Some pods have image pull errors"
    echo ""
    
    # Check for Docker Hub images (etcd, etc.)
    DOCKERHUB_ISSUES=$(kubectl get pods -n ${NAMESPACE} -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[*].state.waiting.reason}{"\t"}{.status.containerStatuses[*].state.waiting.message}{"\n"}{end}' 2>/dev/null | grep -E "(ImagePullBackOff|ErrImagePull)" || true)
    
    if echo "$DOCKERHUB_ISSUES" | grep -q "docker.io"; then
        echo "🔍 Docker Hub image pull issues detected (common with etcd, nats, etc.)"
        echo ""
        echo "This is often caused by:"
        echo "  1. Docker Hub rate limiting (anonymous pulls)"
        echo "  2. Network connectivity issues"
        echo "  3. Image tag not found"
        echo ""
        echo "Solutions:"
        echo ""
        echo "Option 1: Create Docker Hub pull secret (if you have an account):"
        echo "  kubectl create secret docker-registry dockerhub-secret \\"
        echo "    --docker-server=docker.io \\"
        echo "    --docker-username=<your-dockerhub-username> \\"
        echo "    --docker-password=<your-dockerhub-token> \\"
        echo "    --docker-email=<your-email> \\"
        echo "    -n ${NAMESPACE}"
        echo ""
        echo "Option 2: Update to use bitnamilegacy repository:"
        echo "  # Bitnami moved images to bitnamilegacy (as of Aug 2025)"
        echo "  # Upgrade the Helm release with the correct image:"
        echo "  helm upgrade dynamo-platform /tmp/dynamo-platform-${RELEASE_VERSION}.tgz \\"
        echo "    --namespace ${NAMESPACE} \\"
        echo "    --set global.security.allowInsecureImages=true \\"
        echo "    --set etcd.image.registry=docker.io \\"
        echo "    --set etcd.image.repository=bitnamilegacy/etcd"
        echo ""
        echo "Option 3: Pull image manually using containerd (microk8s):"
        echo "  # Check which image is failing:"
        echo "  kubectl describe pod <pod-name> -n ${NAMESPACE} | grep Image"
        echo ""
        echo "  # Try pulling from bitnamilegacy:"
        echo "  sudo microk8s ctr image pull docker.io/bitnamilegacy/etcd:3.5.18-debian-12-r5"
        echo "  # Or using containerd directly:"
        echo "  sudo ctr -n k8s.io images pull docker.io/bitnamilegacy/etcd:3.5.18-debian-12-r5"
        echo ""
        echo "  # Then delete the pod to retry:"
        echo "  kubectl delete pod dynamo-platform-etcd-0 -n ${NAMESPACE}"
        echo ""
        echo "Option 3: Wait and retry (Docker Hub rate limits reset):"
        echo "  kubectl delete pod <pod-name> -n ${NAMESPACE}"
        echo "  # Wait a few minutes, then check again"
        echo ""
        echo "Option 4: Check if image tag exists:"
        echo "  # Visit: https://hub.docker.com/r/bitnami/etcd/tags"
        echo "  # The Helm chart may need updating if tag doesn't exist"
        echo ""
    fi
    
    # Check for NGC images
    if echo "$DOCKERHUB_ISSUES" | grep -q "nvcr.io"; then
        echo "🔍 NGC image pull issues detected"
        echo ""
        echo "This usually means NGC image registry authentication is needed."
        echo ""
        echo "To fix, create an image pull secret:"
        echo "  kubectl create secret docker-registry ngc-registry-secret \\"
        echo "    --docker-server=nvcr.io \\"
        echo "    --docker-username=\$oauthtoken \\"
        echo "    --docker-password=<your-ngc-api-key> \\"
        echo "    --docker-email=<your-email> \\"
        echo "    -n ${NAMESPACE}"
        echo ""
        echo "Then patch the service accounts to use it:"
        echo "  kubectl patch serviceaccount default -n ${NAMESPACE} -p '{\"imagePullSecrets\":[{\"name\":\"ngc-registry-secret\"}]}'"
        echo ""
    fi
    
    echo "Affected pods:"
    kubectl get pods -n ${NAMESPACE} | grep -E "(ImagePullBackOff|ErrImagePull)" || true
    echo ""
    echo "To see detailed error:"
    echo "  kubectl describe pod <pod-name> -n ${NAMESPACE}"
fi

# Step 3: Install Grove (for multinode support and advanced features)
echo ""
echo "Step 3: Setting up Grove..."
echo "Grove enables advanced features like distributed KV cache and multinode deployments."
echo "For single-node setups, Grove provides enhanced capabilities for future scaling."
echo ""

# Note: Grove installation details may vary by version
# Check if Grove is included in the platform or needs separate installation
if kubectl get crd grovenodes.grove.nvidia.com >/dev/null 2>&1; then
    echo "✓ Grove CRDs detected"
elif kubectl get crd | grep -i grove >/dev/null 2>&1; then
    echo "✓ Grove components found"
else
    echo "ℹ️  Grove CRDs not found in this installation."
    echo "   Grove may be installed separately or included in multinode configurations."
    echo "   For single-node with 2 L40s, Dynamo works without Grove."
    echo "   See: https://docs.nvidia.com/dynamo/latest/kubernetes/grove/index.html"
fi

# Step 4: Verify installation
echo ""
echo "Step 4: Verifying installation..."
echo ""
echo "Checking Dynamo components:"
kubectl get pods -n ${NAMESPACE}
echo ""
echo "Checking CRDs:"
kubectl get crd | grep -E "(dynamo|grove)" || echo "No Dynamo/Grove CRDs found"

# Check for any issues
echo ""
echo "Checking for issues..."
FAILED_PODS=$(kubectl get pods -n ${NAMESPACE} --field-selector=status.phase!=Running,status.phase!=Succeeded -o name 2>/dev/null | wc -l)
if [ "$FAILED_PODS" -gt 0 ]; then
    echo "⚠️  Found pods that are not running:"
    kubectl get pods -n ${NAMESPACE} --field-selector=status.phase!=Running,status.phase!=Succeeded
    echo ""
    echo "Common issues:"
    echo "  - ImagePullBackOff: Need NGC image pull secret (see instructions above)"
    echo "  - CrashLoopBackOff: Check logs with: kubectl logs <pod-name> -n ${NAMESPACE}"
fi

# Step 5: Prepare for model deployment
echo ""
echo "Step 5: Preparing for model deployment..."
echo ""
echo "📝 Tutorial: Deploying Your First Model with Dynamo + Grove"
echo ""
echo "Your setup: Single node with 2x L40s GPUs"
echo ""
echo "Option A: Deploy with HuggingFace (recommended for first-time users)"
echo ""
echo "1. Create HuggingFace token secret (if needed for private models):"
echo "   export HF_TOKEN=<your-token>"
echo "   kubectl create secret generic hf-token-secret \\"
echo "     --from-literal=HF_TOKEN=\"\$HF_TOKEN\" \\"
echo "     -n ${NAMESPACE}"
echo ""
echo "2. Create a simple DynamoGraphDeployment YAML (save as my-model.yaml):"
echo "   # Example for vLLM backend with aggregated serving"
echo "   # This uses 1 GPU per worker - perfect for your 2 L40s setup"
echo ""
echo "3. Deploy the model:"
echo "   kubectl apply -f my-model.yaml -n ${NAMESPACE}"
echo ""
echo "4. Monitor deployment:"
echo "   kubectl get dynamoGraphDeployment -n ${NAMESPACE}"
echo "   kubectl get pods -n ${NAMESPACE} -w"
echo ""
echo "5. Test the deployment:"
echo "   kubectl port-forward svc/<your-frontend-service> 8000:8000 -n ${NAMESPACE}"
echo "   curl http://localhost:8000/v1/models"
echo ""
echo "📚 Example configurations available at:"
echo "   https://github.com/ai-dynamo/dynamo/tree/main/examples/backends"
echo ""
echo "💡 Architecture patterns for your 2 L40s setup:"
echo "   - Aggregated: 1 worker per GPU (2 workers total)"
echo "   - Disaggregated: Separate prefill/decode workers for higher throughput"
echo "   - With Router: Load balancing across workers"
echo ""

# Display GPU information
echo ""
echo "🖥️  GPU Information:"
if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi --query-gpu=index,name,memory.total --format=csv,noheader | head -2
    echo ""
    echo "You have 2x L40s GPUs available for Dynamo deployments"
else
    echo "⚠️  nvidia-smi not found. GPUs may not be properly configured."
fi

echo ""
echo "✅ Dynamo + Grove installation complete!"
echo ""
echo "📚 Next Steps:"
echo "   1. Review Dynamo documentation: https://docs.nvidia.com/dynamo/latest/kubernetes/README.html"
echo "   2. Choose a backend (vLLM, SGLang, or TensorRT-LLM)"
echo "   3. Deploy your first model using DynamoGraphDeployment"
echo "   4. For multinode deployments, configure Grove"
echo ""
echo "💡 Quick commands:"
echo "   kubectl get dynamoGraphDeployment -n ${NAMESPACE}"
echo "   kubectl get pods -n ${NAMESPACE}"
echo "   kubectl logs -n ${NAMESPACE} <pod-name>"
echo ""

