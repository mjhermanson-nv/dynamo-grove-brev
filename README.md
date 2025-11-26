# Dynamo + Grove Bootstrap Script for Brev

A one-shot bootstrap script to set up Kubernetes (microk8s) and deploy NVIDIA Dynamo with Grove on a Brev launchable instance. Perfect for single-node setups with GPU support (tested with 2x L40s GPUs).

## 🎯 What This Does

This script automates the complete setup of:

1. **Kubernetes Cluster** - Installs and configures microk8s
2. **Essential Tools** - kubectl, helm, k9s
3. **Storage Provisioning** - Local-path storage for PersistentVolumeClaims
4. **NVIDIA GPU Support** - GPU operator for Kubernetes
5. **Dynamo Platform** - Installs Dynamo CRDs and platform operator
6. **Grove Setup** - Prepares Grove components for advanced features

## 📋 Prerequisites

- A Brev launchable instance (Ubuntu-based)
- NVIDIA GPUs (tested with 2x L40s)
- sudo/root access
- Internet connectivity
- NGC account access (for Dynamo Helm charts)

### NGC Authentication

Before running the script, ensure you have NGC access:

```bash
# Login to NGC Helm registry
helm registry login nvcr.io
```

You'll need:
- An NVIDIA NGC account: https://catalog.ngc.nvidia.com/
- Access to the Dynamo Helm charts

## 🚀 Quick Start

### Option 1: Run the Script Directly

```bash
# Clone or download the repository
git clone https://github.com/mjhermanson-nv/dynamo-grove-brev.git
cd dynamo-grove-brev

# Make it executable
chmod +x oneshot.sh

# Run it (may require sudo)
sudo ./oneshot.sh
```

### Option 2: Run as Root

```bash
sudo bash oneshot.sh
```

The script will:
- Detect your Brev user automatically
- Install and configure all components
- Set up proper permissions
- Verify the installation

## 📖 What Gets Installed

### Kubernetes Components
- **microk8s** - Lightweight Kubernetes distribution
- **DNS addon** - CoreDNS for service discovery
- **GPU addon** - NVIDIA GPU operator

### CLI Tools
- **kubectl** - Standalone binary in `/usr/local/bin/`
- **helm** - Helm 3 for package management
- **k9s** - Terminal UI for Kubernetes

### Storage
- **local-path-provisioner** - Dynamic storage provisioning
- Set as default StorageClass for PVCs

### Dynamo Components
- **Dynamo CRDs** - Custom Resource Definitions
- **Dynamo Platform** - Operator and core components
- **Grove** - Advanced features (multinode, distributed KV cache)

## 🎓 Tutorial: Deploying Your First Model

After the script completes, you're ready to deploy models with Dynamo. Here's a quick tutorial:

### 1. Set Up HuggingFace Token (if needed)

```bash
export NAMESPACE=dynamo-system
export HF_TOKEN=<your-huggingface-token>

kubectl create secret generic hf-token-secret \
  --from-literal=HF_TOKEN="$HF_TOKEN" \
  -n ${NAMESPACE}
```

### 2. Choose Your Backend

Dynamo supports three backends:

| Backend | Best For | Example Use Case |
|---------|----------|------------------|
| **vLLM** | General purpose, easy setup | Most models, quick deployments |
| **SGLang** | High throughput, structured outputs | Tool calling, function calling |
| **TensorRT-LLM** | Maximum performance | Production workloads, optimized inference |

### 3. Deploy a Model

For a 2x L40s setup, you can run:

- **Aggregated**: 1 worker per GPU (2 workers total)
- **Disaggregated**: Separate prefill/decode workers for higher throughput
- **With Router**: Load balancing across workers

Example deployment YAML (`my-model.yaml`):

```yaml
apiVersion: nvidia.com/v1alpha1
kind: DynamoGraphDeployment
metadata:
  name: my-llm
spec:
  services:
    Frontend:
      dynamoNamespace: my-llm
      componentType: frontend
      replicas: 1
    VllmDecodeWorker:
      dynamoNamespace: my-llm
      componentType: worker
      replicas: 2  # One per GPU
      envFromSecret: hf-token-secret
      resources:
        limits:
          gpu: "1"
      extraPodSpec:
        mainContainer:
          image: nvcr.io/nvidia/dynamo/dynamo-runtime:latest
          args:
            - python3 -m dynamo.vllm --model Qwen/Qwen2.5-0.5B
```

Deploy it:

```bash
kubectl apply -f my-model.yaml -n dynamo-system
```

### 4. Monitor Your Deployment

```bash
# Check deployment status
kubectl get dynamoGraphDeployment -n dynamo-system

# Watch pods
kubectl get pods -n dynamo-system -w

# View logs
kubectl logs -n dynamo-system <pod-name>
```

### 5. Test Your Model

```bash
# Port forward to the frontend service
kubectl port-forward svc/<your-frontend-service> 8000:8000 -n dynamo-system

# In another terminal, test the API
curl http://localhost:8000/v1/models
```

## 🏗️ Architecture Patterns

### Aggregated Serving
- Single worker handles both prefill and decode
- Simple setup, good for development
- Use: `examples/backends/vllm/deploy/agg.yaml`

### Aggregated + Router
- Multiple workers with load balancing
- Better throughput, fault tolerance
- Use: `examples/backends/vllm/deploy/agg_router.yaml`

### Disaggregated + Router
- Separate prefill and decode workers
- Maximum throughput, optimal resource usage
- Use: `examples/backends/vllm/deploy/disagg_router.yaml`

## 📚 Resources

- **Dynamo Documentation**: https://docs.nvidia.com/dynamo/latest/kubernetes/README.html
- **Dynamo Examples**: https://github.com/ai-dynamo/dynamo/tree/main/examples/backends
- **Grove Documentation**: https://docs.nvidia.com/dynamo/latest/kubernetes/grove/index.html
- **API Reference**: https://docs.nvidia.com/dynamo/latest/kubernetes/api-reference/index.html

## 🔧 Troubleshooting

### kubectl not working

The script installs standalone binaries that work immediately. If you have issues:

```bash
export KUBECONFIG=$HOME/.kube/config
kubectl get nodes
```

### NGC Authentication Issues

```bash
# Verify NGC login
helm registry login nvcr.io

# Check available versions
# Visit: https://github.com/ai-dynamo/dynamo/releases
```

### GPU Not Detected

```bash
# Check GPU availability
nvidia-smi

# Verify GPU operator
kubectl get pods -n gpu-operator-resources
```

### Storage Issues

```bash
# Check storage class
kubectl get storageclass

# Verify local-path-provisioner
kubectl get pods -n local-path-storage
```

### Dynamo Platform Not Ready

```bash
# Check operator status
kubectl get pods -n dynamo-system

# View operator logs
kubectl logs -n dynamo-system deployment/dynamo-operator
```

## 💡 Tips

- **No group membership needed**: The script installs standalone binaries, so you don't need to logout/login or use `newgrp`
- **Works immediately**: kubectl, helm, and k9s are available right after the script completes
- **Single-node optimized**: Perfect for development and testing on Brev instances
- **Grove ready**: While Grove is primarily for multinode, the setup prepares you for scaling

## 🎯 Quick Commands Reference

```bash
# Cluster info
kubectl get nodes
kubectl get pods -A
kubectl get storageclass

# Dynamo deployments
kubectl get dynamoGraphDeployment -n dynamo-system
kubectl describe dynamoGraphDeployment <name> -n dynamo-system

# Monitoring
k9s  # Terminal UI
kubectl logs -n dynamo-system <pod-name> -f

# Port forwarding
kubectl port-forward svc/<service-name> 8000:8000 -n dynamo-system
```

## 📝 Notes

- The script is idempotent - safe to run multiple times
- All tools are installed to `/usr/local/bin/` for system-wide access
- Kubeconfig is stored at `~/.kube/config`
- Default namespace is `dynamo-system`

## 🤝 Contributing

Feel free to open issues or submit pull requests for improvements!

## 📄 License

This script is provided as-is for setting up Dynamo on Brev instances.

---

**Happy deploying! 🚀**

