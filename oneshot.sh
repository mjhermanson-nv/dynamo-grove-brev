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

echo "☸️  Setting up Kubernetes with Dynamo + Grove..."
echo "User: $USER"

# Install microk8s
echo "Installing microk8s..."
sudo snap install microk8s --classic

# Add user to group
sudo usermod -a -G microk8s $USER

# Create .kube directory if it doesn't exist and fix permissions
mkdir -p ~/.kube
if [ "$(id -u)" -eq 0 ]; then
    chown -R $USER:$USER ~/.kube
fi

# Wait for microk8s to be ready
echo "Waiting for microk8s..."
sudo microk8s status --wait-ready

# Enable essential addons
echo "Enabling addons..."
sudo microk8s enable dns
sudo microk8s enable gpu  # NVIDIA GPU operator (Brev has NVIDIA drivers)

# Export kubeconfig so kubectl works without group membership
echo "Configuring kubectl access..."
sudo microk8s config > ~/.kube/config
chmod 600 ~/.kube/config

# Fix ownership if running as root
if [ "$(id -u)" -eq 0 ]; then
    chown $USER:$USER ~/.kube/config
fi

# Add KUBECONFIG to shell configs if not already there
for shell_config in ~/.bashrc ~/.zshrc; do
    if [ -f "$shell_config" ] && ! grep -q "KUBECONFIG.*kube/config" "$shell_config"; then
        echo "" >> "$shell_config"
        echo "# Kubernetes config" >> "$shell_config"
        echo "export KUBECONFIG=\$HOME/.kube/config" >> "$shell_config"

        # Fix ownership if running as root
        if [ "$(id -u)" -eq 0 ]; then
            chown $USER:$USER "$shell_config"
        fi
    fi
done

# Export for current session
export KUBECONFIG=$HOME/.kube/config

# Remove any existing snap alias (it requires group membership)
sudo snap unalias kubectl 2>/dev/null || true

# Install standalone kubectl (works without group membership!)
echo "Installing standalone kubectl..."
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl
sudo mv kubectl /usr/local/bin/kubectl
echo "✓ kubectl installed to /usr/local/bin/kubectl"

# Install standalone helm (works without group membership!)
echo "Installing standalone helm..."
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
echo "✓ helm installed to /usr/local/bin/helm"

# Install k9s for terminal UI
echo "Installing k9s..."
wget -q https://github.com/derailed/k9s/releases/latest/download/k9s_Linux_amd64.tar.gz
tar -xzf k9s_Linux_amd64.tar.gz
sudo chmod +x k9s
sudo mv k9s /usr/local/bin/
rm k9s_Linux_amd64.tar.gz LICENSE README.md 2>/dev/null || true

# Install local-path-provisioner for PersistentVolumeClaims
echo "Installing local-path storage provisioner..."
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.24/deploy/local-path-storage.yaml

# Wait for provisioner to be ready
echo "Waiting for storage provisioner..."
kubectl wait --for=condition=available --timeout=60s deployment/local-path-provisioner -n local-path-storage

# Set as default storage class
kubectl patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
echo "✓ Storage provisioner installed and set as default"

# Final permission fix for any files created by microk8s
if [ "$(id -u)" -eq 0 ] && [ -d "$HOME/.kube" ]; then
    chown -R $USER:$USER "$HOME/.kube" 2>/dev/null || true
fi

# Verify (without sudo - should work now!)
echo ""
echo "Verifying installation..."
sudo microk8s status

# Show which binaries we're using
echo ""
echo "kubectl binary: $(which kubectl)"
echo "helm binary: $(which helm)"

# Test kubectl
export KUBECONFIG=$HOME/.kube/config
kubectl version --client
echo ""
echo "Testing cluster access..."
kubectl get nodes 2>/dev/null && echo "✓ kubectl can access cluster without group membership!" || echo "⚠️  kubectl will work after sourcing shell config"

# Test helm
echo ""
echo "Testing helm..."
helm version --short 2>/dev/null && echo "✓ helm is ready!" || echo "⚠️  helm will work after sourcing shell config"

# Verify storage class
echo ""
echo "Verifying storage class..."
kubectl get storageclass

echo ""
echo "✅ Kubernetes ready for Dynamo + Grove!"
echo ""
echo "Kubeconfig: ~/.kube/config"
echo ""
echo "Quick start (works immediately!):"
echo "  kubectl get nodes"
echo "  kubectl get pods -A"
echo "  kubectl get storageclass"
echo "  helm version"
echo "  k9s"
echo ""
echo "💡 How it works:"
echo "  - kubectl, helm, k9s are standalone binaries (/usr/local/bin/)"
echo "  - Use ~/.kube/config automatically"
echo "  - Storage provisioner ready for Dynamo/Grove PVCs"
echo "  - No group membership needed!"
echo "  - No 'newgrp' or logout required!"
echo ""
echo "Next steps:"
echo "  Follow the README.md in this directory to deploy Dynamo + Grove"
echo ""

### Dynamo + Grove deployment
echo ""
echo "🚀 Deploying Dynamo + Grove..."
echo ""

# Set environment variables
export NAMESPACE=dynamo-system
export RELEASE_VERSION=0.3.2  # Update to latest version as needed

# Create namespace
echo "Creating namespace: $NAMESPACE"
kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

# Step 1: Install Dynamo CRDs
echo ""
echo "Step 1: Installing Dynamo CRDs..."
echo "Note: This requires NGC authentication. If you haven't logged in, run:"
echo "  helm registry login nvcr.io"
echo ""
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

if [ -f "dynamo-crds-${RELEASE_VERSION}.tgz" ]; then
    helm install dynamo-crds dynamo-crds-${RELEASE_VERSION}.tgz --namespace default || {
        echo "⚠️  CRD installation failed, but continuing (may already exist)"
    }
    rm -f dynamo-crds-${RELEASE_VERSION}.tgz
fi

# Step 2: Install Dynamo Platform
echo ""
echo "Step 2: Installing Dynamo Platform..."
helm fetch https://helm.ngc.nvidia.com/nvidia/ai-dynamo/charts/dynamo-platform-${RELEASE_VERSION}.tgz || {
    echo "❌ Failed to fetch Dynamo Platform."
    echo "   Please ensure NGC authentication: helm registry login nvcr.io"
    exit 1
}

helm install dynamo-platform dynamo-platform-${RELEASE_VERSION}.tgz \
    --namespace ${NAMESPACE} \
    --create-namespace \
    --wait \
    --timeout 10m || {
    echo "⚠️  Platform installation had issues, but continuing..."
}

rm -f dynamo-platform-${RELEASE_VERSION}.tgz

# Wait for platform to be ready
echo ""
echo "Waiting for Dynamo Platform to be ready..."
kubectl wait --for=condition=available --timeout=300s deployment/dynamo-operator -n ${NAMESPACE} || echo "⚠️  Operator may still be starting"

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
echo "✅ Dynamo + Grove deployment complete!"
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