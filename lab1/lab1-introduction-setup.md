# Lab 1: Introduction and Kubernetes-Based Deployment

## Overview

In this lab, you will:
- Set up your namespace in the Kubernetes cluster
- Deploy Dynamo platform on Kubernetes
- Configure a backend engine using aggregated serving
- Test the deployment with OpenAI-compatible API
- Benchmark the deployment using AI-Perf

## Duration: ~90 minutes

---

## Section 1: Environment Setup

### Objectives
- Verify Kubernetes access
- Create your namespace
- Install Dynamo dependencies
- Set up prerequisites (kubectl, helm)

### Prerequisites
Before starting, ensure you have:
- ✅ Single-node Kubernetes cluster (MicroK8s recommended)
- ✅ `kubectl` installed (version 1.24+)
- ✅ `helm` 3.x installed
- ✅ NGC API key from [ngc.nvidia.com](https://ngc.nvidia.com/) (for container image access)
- ✅ HuggingFace token from [huggingface.co/settings/tokens](https://huggingface.co/settings/tokens)

### Step 2: Set Configuration Variables

Set your configuration variables. **Replace the values below with your own:**



```python
import os

# Set lab configuration
os.environ['RELEASE_VERSION'] = '0.7.1'
os.environ['NAMESPACE'] = 'dynamo-lab1'
os.environ['HF_TOKEN'] = ''  # Replace with your HuggingFace token
os.environ['CACHE_PATH'] = '/data/huggingface-cache'  # Local cache path

NAMESPACE = os.environ['NAMESPACE']
FRONTEND_PORT = '10000'
GRAFANA_PORT = '30080'  # NodePort from monitoring stack

print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
print("🎓 Lab 1: Environment Configuration")
print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
print(f"  Release Version:  {os.environ['RELEASE_VERSION']}")
print(f"  Namespace:        {NAMESPACE}")
print(f"  Cache Path:       {os.environ['CACHE_PATH']}")
print("")
print("📌 Access Ports:")
print(f"  Frontend API:     localhost:{FRONTEND_PORT} (via port-forward)")
print(f"  Grafana:          http://<node-ip>:{GRAFANA_PORT}")
print("")
print("💡 Use port-forward to access the frontend:")
print(f"   kubectl port-forward -n {NAMESPACE} deployment/vllm-agg-router-frontend {FRONTEND_PORT}:8000")
print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
```

### Step 3: Verify Kubernetes Access



```bash
%%bash
# Verify kubectl is installed and configured
kubectl version --client

# Check cluster connection
kubectl cluster-info

# Check GPU nodes are available (optional)
kubectl get nodes -o custom-columns=NAME:.metadata.name,GPUs:.status.capacity.nvidia\\.com/gpu
```

### Step 4: Set Up NGC Authentication

To access NVIDIA's Dynamo container images, you need to authenticate with NGC (NVIDIA GPU Cloud).

#### Get Your NGC API Key

1. Go to [NGC](https://ngc.nvidia.com/)
2. Sign in or create an account
3. Click on your profile in the top right corner
4. Select **"Setup"** → **"Generate API Key"**
5. Copy your API key (it will only be shown once!)

#### Get and Save Your NGC API Key



```python
import os
import getpass

# Get NGC API key from user
print("Enter your NGC API Key from https://ngc.nvidia.com/")
print("(Go to Profile > Setup > Generate API Key)")
print("")
NGC_API_KEY = getpass.getpass("NGC API Key: ")

# Save it for later use (creating pull secrets)
os.environ['NGC_API_KEY'] = NGC_API_KEY

print("")
print("✓ NGC API key saved")
print("  You can now use it to login and create pull secrets")
```

#### Login to NGC Container Registry



```bash
%%bash
# Login to NGC container registry
echo $NGC_API_KEY | helm registry login nvcr.io --username '$oauthtoken' --password-stdin

echo ""
echo "✓ NGC authentication complete"
echo "  You can now pull Dynamo container images"
```

### Step 5: Create Your Namespace



```bash
%%bash
# Create your namespace
kubectl create namespace $NAMESPACE

# Verify namespace was created
kubectl get namespace $NAMESPACE
```

### Step 6: Create NGC Pull Secret

Create a Kubernetes secret so that pods can pull images from NGC.



```bash
%%bash
# Create NGC image pull secret
kubectl create secret docker-registry ngc-secret \
  --docker-server=nvcr.io \
  --docker-username='$oauthtoken' \
  --docker-password=$NGC_API_KEY \
  --namespace $NAMESPACE

# Verify secret was created
kubectl get secret ngc-secret -n $NAMESPACE
echo "✓ NGC pull secret created in namespace: $NAMESPACE"
```

### Step 7: Create HuggingFace Token Secret



```bash
%%bash
# Create HuggingFace token secret
kubectl create secret generic hf-token-secret \
  --from-literal=HF_TOKEN="$HF_TOKEN" \
  --namespace $NAMESPACE

# Verify secret was created
kubectl get secret hf-token-secret -n $NAMESPACE
echo "✓ HuggingFace token secret created"
```

## Section 2: Install Dynamo Platform

### Objectives
- Install Dynamo CRDs (Custom Resource Definitions)
- Install Dynamo platform (etcd, NATS, operator) in your namespace
- Verify platform components are running

### Architecture
```
Client → Frontend → Router → Worker(s) with Backend Engine
                        ↓
                 etcd + NATS
                        ↓
                Dynamo Operator
```

### Step 1: Install Dynamo CRDs

CRDs are cluster-wide resources that define the custom resources used by Dynamo.



```bash
%%bash
# Check if CRDs already exist
if kubectl get crd dynamographdeployments.nvidia.com &>/dev/null && \
   kubectl get crd dynamocomponentdeployments.nvidia.com &>/dev/null; then
    echo "✓ CRDs already installed"
    kubectl get crd | grep nvidia.com
else
    echo "Installing Dynamo CRDs..."
    helm fetch https://helm.ngc.nvidia.com/nvidia/ai-dynamo/charts/dynamo-crds-$RELEASE_VERSION.tgz
    helm install dynamo-crds dynamo-crds-$RELEASE_VERSION.tgz --namespace default
    
    echo ""
    echo "Verifying CRD installation:"
    kubectl get crd | grep nvidia.com
fi
```

### Step 2: Install Dynamo Platform

This installs ETCD, NATS, and the Dynamo Operator Controller in your namespace.



```bash
%%bash
# Download platform chart
helm fetch https://helm.ngc.nvidia.com/nvidia/ai-dynamo/charts/dynamo-platform-$RELEASE_VERSION.tgz

# Install Dynamo platform
echo "Installing Dynamo platform in namespace: $NAMESPACE"
helm install dynamo-platform dynamo-platform-$RELEASE_VERSION.tgz \
  --namespace $NAMESPACE

echo ""
echo "Platform installation initiated. Waiting for pods to be ready..."
```

### Step 3: Wait for Platform Pods to Be Ready

Re-run the following cell until all pods report as "Running"



```bash
%%bash
kubectl get pods -n $NAMESPACE
```

## Section 3: Deploy Your First Model with Aggregated Serving

### Objectives
- Understand aggregated serving architecture
- Configure and deploy a model using vLLM backend
- Use Kubernetes manifests to deploy Dynamo resources

### Available Backends
In this lab, we'll use **vLLM** with aggregated serving for simplicity:
- **vLLM**: High-throughput serving with PagedAttention
- Model: `Qwen/Qwen2.5-1.5B-Instruct` (small, fast to download)
- Architecture: Aggregated serving with KV-cache routing

**Other backends** (for exploration):
- **SGLang**: Optimized for complex prompting and structured generation
- **TensorRT-LLM**: Maximum performance on NVIDIA GPUs

### Deployment Configuration

We'll use a `DynamoGraphDeployment` resource that defines:
- **Frontend**: OpenAI-compatible API endpoint with KV-cache routing
- **Worker**: vLLM worker with 1 GPU running the model

### Step 1: Update the Deployment Configuration

Before deploying, we need to update the YAML configuration with your specific values:



```bash
%%bash
# Update agg_router.yaml with your configuration

# Replace my-tag with actual version
sed -i "s/my-tag/$RELEASE_VERSION/g" agg_router.yaml

# Replace cache path
sed -i "s|/YOUR/LOCAL/CACHE/FOLDER|$CACHE_PATH|g" agg_router.yaml

echo "✓ Configuration updated in agg_router.yaml"
echo ""
echo "Verify image tags (should show version, not my-tag):"
grep "image:" agg_router.yaml
```

### Step 2: Deploy the Model



```bash
%%bash
# Apply the deployment
kubectl apply -f agg_router.yaml --namespace $NAMESPACE

echo ""
echo "✓ Deployment created. This will take 4-6 minutes for first run."
echo "  - Pulling container images"
echo "  - Downloading model from HuggingFace"
echo "  - Loading model into GPU memory"
```

### Step 3: Monitor Deployment Progress



```bash
%%bash
# Check deployment status
kubectl get dynamographdeployment -n $NAMESPACE

echo ""
echo "Pod status (wait for all pods to be 1/1 Ready):"
kubectl get pods -n $NAMESPACE | grep vllm

# To watch in real-time, uncomment the line below:
# kubectl get pods -n $NAMESPACE -w
```

### Step 4: View Worker Logs (Optional)

While waiting for the deployment, you can watch the model loading progress:



```bash
%%bash
# Get logs from the worker pod
WORKER_POD=$(kubectl get pods -n $NAMESPACE | grep vllmdecodeworker | head -1 | awk '{print $1}')

if [ -n "$WORKER_POD" ]; then
    echo "Viewing logs from: $WORKER_POD"
    echo "Look for:"
    echo "  - 'Loading model weights...' (downloading)"
    echo "  - 'Model loading took X.XX GiB' (loaded)"
    echo ""
    kubectl logs $WORKER_POD -n $NAMESPACE --tail=30
else
    echo "Worker pod not found yet, please wait and try again"
fi
```

## Section 4: Testing and Validation

### Objectives
- Access the service via NodePort
- Send test requests to the deployment
- Verify OpenAI API compatibility
- Test streaming and non-streaming responses

### Testing Strategy
Once your deployment is running (`1/1 Ready`), you'll:
1. Get the node IP address
2. Access the service on NodePort 30100
3. Test with curl commands
4. Verify response format and functionality

### Step 1: Get Node IP and Service URL

The frontend is exposed as a NodePort service on port 30100:



```bash
%%bash
# Get the node IP
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
echo "Node IP: $NODE_IP"
echo ""
echo "Frontend URL: http://$NODE_IP:30100"
echo ""
echo "✓ Access the frontend at: http://$NODE_IP:30100"
```

### Step 2: Test the `/v1/models` Endpoint



```bash
%%bash
# Get node IP for testing
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

curl http://$NODE_IP:30100/v1/models
```

### Step 3: Simple Non-Streaming Chat Completion



```bash
%%bash
# Get node IP for testing
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

curl http://$NODE_IP:30100/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{ 
    "model": "Qwen/Qwen2.5-1.5B-Instruct",
    "messages": [{"role": "user", "content": "Hello! How are you?"}], 
    "stream": false,
    "max_tokens": 50 
  }'
```

### Step 4: Test Streaming Response



```bash
%%bash
# Get node IP for testing
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

curl http://$NODE_IP:30100/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{ 
    "model": "Qwen/Qwen2.5-1.5B-Instruct", 
    "messages": [{"role": "user", "content": "Write a short poem about AI"}], 
    "stream": true, 
    "max_tokens": 100 
  }'
```

### Step 5: Test with Different Parameters



```bash
%%bash
# Get node IP for testing
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

curl http://$NODE_IP:30100/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{ 
    "model": "Qwen/Qwen2.5-1.5B-Instruct", 
    "messages": [{"role": "user", "content": "Explain quantum computing in one sentence"}], 
    "stream": false, 
    "temperature": 0.7, 
    "max_tokens": 100, 
    "top_p": 0.9 
  }'
```

## Section 5: Benchmarking with AI-Perf

### Objectives
- Install and configure AI-Perf benchmarking tool
- Run performance benchmarks against your Kubernetes deployment
- Analyze throughput, latency, and token metrics
- Compare performance across different configurations

### Metrics to Measure
- Throughput (requests/second, tokens/second)
- Latency (TTFT - Time To First Token, TPOT - Time Per Output Token, end-to-end)
- GPU utilization
- KV cache efficiency

### Benchmarking Setup
You'll run AI-Perf from your local machine against the port-forwarded service, simulating:
- Different concurrency levels (fixed concurrent requests)
- Request rate patterns (requests per second)
- Various workload characteristics

### Step 1: Install AI-Perf (if not already installed)



```python
%%python
# Install AI-Perf benchmarking tool
!pip install aiperf -q
print("✓ AI-Perf installed")
```

### Step 2: Run Baseline Benchmark (Low Concurrency)



```bash
%%bash
# Get node IP for benchmarking
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

# Run a simple benchmark with low concurrency
aiperf profile \
  --model Qwen/Qwen2.5-1.5B-Instruct \
  --url http://$NODE_IP:30100 \
  --endpoint-type chat \
  --streaming \
  --concurrency 1 \
  --request-count 100

echo ""
echo "✓ Baseline benchmark complete"
```

### Step 3: Run Benchmark with Higher Concurrency



```bash
%%bash
# Get node IP for benchmarking
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

# Test with higher concurrency to stress test
aiperf profile \
  --model Qwen/Qwen2.5-1.5B-Instruct \
  --url http://$NODE_IP:30100 \
  --endpoint-type chat \
  --streaming \
  --concurrency 4 \
  --request-count 200

echo ""
echo "✓ High concurrency benchmark complete"
```

### Step 4: Run Benchmark with Request Rate



```bash
%%bash
# Get node IP for benchmarking
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

# Test with request rate instead of concurrency
aiperf profile \
  --model Qwen/Qwen2.5-1.5B-Instruct \
  --url http://$NODE_IP:30100 \
  --endpoint-type chat \
  --streaming \
  --request-rate 10 \
  --request-count 200

echo ""
echo "✓ Request rate benchmark complete"
```

### Step 5: Analyze Results

Review the benchmark outputs above. Key metrics to look for:
- **Throughput**: requests/second and tokens/second
- **TTFT (Time To First Token)**: How quickly does the first token appear?
- **TPOT (Time Per Output Token)**: Generation speed
- **End-to-end latency**: Total request time

## Section 6: Exercises and Exploration

### Exercise 1: Scale Your Deployment

Try scaling to multiple worker replicas and observe KV-cache routing in action:



```bash
%%bash
# Scale the deployment to 2 replicas
# First, update the agg_router.yaml file (change replicas: 1 to replicas: 2)
# Then reapply:

# Quick way: use kubectl patch
kubectl patch dynamographdeployment vllm-agg-router -n $NAMESPACE --type='json' \
  -p='[{"op": "replace", "path": "/spec/services/VllmDecodeWorker/replicas", "value":2}]'

echo ""
echo "✓ Scaling to 2 workers"
echo "Watch the new worker come online:"
kubectl get pods -n $NAMESPACE -w
```

Check load distribution across workers:



```bash
%%bash
# View logs from all workers to see load distribution
kubectl logs -l component=VllmDecodeWorker -n $NAMESPACE --tail=20
```

### Exercise 2: Parameter Tuning

Experiment with vLLM parameters by modifying the worker args. Common parameters to try:
- `--max-num-seqs`: Maximum number of sequences per iteration
- `--gpu-memory-utilization`: GPU memory fraction to use (default 0.9)
- `--max-model-len`: Maximum sequence length

To update, you'll need to edit `agg_router.yaml` and reapply the deployment.

### Exercise 3: Load Testing

Test with your scaled deployment:



```bash
%%bash
# Get node IP for benchmarking
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

# Run benchmark against scaled deployment
aiperf profile \
  --model Qwen/Qwen2.5-1.5B-Instruct \
  --url http://$NODE_IP:30100 \
  --endpoint-type chat \
  --streaming \
  --concurrency 8 \
  --request-count 300

echo ""
echo "Compare this with your single-worker baseline!"
```

### Exercise 4: Cleanup

When you're done with Lab 1, clean up your deployment:



```bash
%%bash
# Delete the deployment
kubectl delete dynamographdeployment vllm-agg-router -n $NAMESPACE

echo ""
echo "✓ Deployment deleted"
echo "Verifying pods are terminating:"
kubectl get pods -n $NAMESPACE
```

**Note:** Keep your namespace and platform for Lab 2! Only delete the deployment, not the namespace.

## Troubleshooting

### Check Pod Status



```bash
%%bash
# Check all pods in your namespace
kubectl get pods -n $NAMESPACE

# Describe a specific pod to see errors
# Replace <pod-name> with actual pod name from above output
# kubectl describe pod <pod-name> -n $NAMESPACE
```

### View Pod Logs



```bash
%%bash
# View logs from a specific component
# For frontend:
kubectl logs -l component=Frontend -n $NAMESPACE --tail=50

# For worker:
kubectl logs -l component=VllmDecodeWorker -n $NAMESPACE --tail=50
```

### Check Deployment Status



```bash
%%bash
# Check DynamoGraphDeployment status
kubectl describe dynamographdeployment vllm-agg-router -n $NAMESPACE

# Check operator logs
kubectl logs -l app.kubernetes.io/name=dynamo-operator -n $NAMESPACE --tail=50
```

### Check Recent Events



```bash
%%bash
# View recent events in your namespace
kubectl get events -n $NAMESPACE --sort-by='.lastTimestamp' | tail -20
```

### Common Issues

1. **ImagePullBackOff**: Check if you have access to NGC containers. Verify image version is correct.
2. **Pods stuck in Pending**: Check if GPU resources are available: `kubectl describe pod <pod-name> -n $NAMESPACE`
3. **Model download slow**: First run takes longer due to model download. Check worker logs for progress.
4. **Port forward not working**: Make sure pods are `1/1 Ready` before forwarding. Kill existing port-forward processes: `pkill -f port-forward`

---

## Summary

### What You Learned
- ✅ How to set up a Dynamo deployment on Kubernetes
- ✅ Kubernetes-based aggregated deployment architecture
- ✅ Creating and managing DynamoGraphDeployment resources
- ✅ Backend engine deployment (vLLM)
- ✅ Testing with OpenAI-compatible API
- ✅ Performance benchmarking with AI-Perf

### Key Takeaways
- Aggregated serving is simpler to deploy and suitable for single-node models
- KV-cache routing provides intelligent load balancing across replicas
- DynamoGraphDeployment CRD simplifies complex inference deployments
- AI-Perf provides comprehensive performance insights
- Single-node Kubernetes clusters are ideal for development and learning

### Next Steps
- **(Optional)** Complete the **Monitoring Extension** (`lab1-monitoring.md`) to set up Prometheus and Grafana for observability
- In **Lab 2**, you'll explore disaggregated serving with separate prefill and decode workers, and use AIConfigurator to optimize configurations for larger models

---

## Appendix: Step-by-Step Commands

This appendix provides complete commands for each section. Use these as a reference during the lab.

**Note for MicroK8s users:** Replace `kubectl` with `kubectl` in all commands below, or set up an alias:



```python
%%python
alias kubectl='kubectl'
```

### A1. Environment Setup



```python
%%python
# Verify kubectl is installed and configured
kubectl version --client
kubectl cluster-info

# Set your configuration
export NAMESPACE="dynamo-lab1"
export RELEASE_VERSION="0.7.1"     # Dynamo version
export CACHE_PATH="/data/huggingface-cache"  # Local cache path

# HuggingFace Token - Required for model downloads
# Get your token from https://huggingface.co/settings/tokens
export HF_TOKEN="your_hf_token"    # Replace with your HuggingFace token

# NGC Authentication - Get and save NGC API key
export NGC_API_KEY="your_ngc_api_key"  # Replace with your actual NGC API key from https://ngc.nvidia.com/

# Login to NVIDIA Container Registry
# Username: $oauthtoken (literal string)
# Password: your NGC API key
echo $NGC_API_KEY | helm registry login nvcr.io --username '$oauthtoken' --password-stdin

# Create your namespace
kubectl create namespace ${NAMESPACE}

# Verify namespace was created
kubectl get namespace ${NAMESPACE}

# Create NGC pull secret in the namespace
kubectl create secret docker-registry ngc-secret \
  --docker-server=nvcr.io \
  --docker-username='$oauthtoken' \
  --docker-password=$NGC_API_KEY \
  --namespace ${NAMESPACE}

# Verify NGC secret was created
kubectl get secret ngc-secret -n ${NAMESPACE}

# Create HuggingFace token secret
kubectl create secret generic hf-token-secret \
  --from-literal=HF_TOKEN="${HF_TOKEN}" \
  --namespace ${NAMESPACE}

# Check GPU nodes are available (optional)
kubectl get nodes -o custom-columns=NAME:.metadata.name,GPUs:.status.capacity.nvidia\\.com/gpu
```

### A2. Install Dynamo Platform (Namespace-Scoped)



```python
%%python
# Step 1: Check if CRDs are already installed (cluster-wide)
if kubectl get crd dynamographdeployments.nvidia.com &>/dev/null && \
   kubectl get crd dynamocomponentdeployments.nvidia.com &>/dev/null; then
    echo "✓ CRDs already installed"
else
    echo "⚠️  CRDs not found. Ask instructor to install them, or run:"
    echo "helm fetch https://helm.ngc.nvidia.com/nvidia/ai-dynamo/charts/dynamo-crds-${RELEASE_VERSION}.tgz"
    echo "helm install dynamo-crds dynamo-crds-${RELEASE_VERSION}.tgz --namespace default"
fi

# Step 2: Download Dynamo platform helm chart
helm fetch https://helm.ngc.nvidia.com/nvidia/ai-dynamo/charts/dynamo-platform-${RELEASE_VERSION}.tgz

# Step 3: Install Dynamo platform (cluster-wide by default - recommended)
helm install dynamo-platform dynamo-platform-${RELEASE_VERSION}.tgz \
  --namespace ${NAMESPACE}

# Step 4: Wait for platform pods to be ready (~2-3 minutes)
echo "Waiting for platform pods to be ready..."
kubectl wait --for=condition=ready pod \
  --all \
  --namespace ${NAMESPACE} \
  --timeout=300s

# Step 5: Verify platform is running
kubectl get pods -n ${NAMESPACE}
# You should see: dynamo-operator, etcd, and nats pods in Running state
```

### A3. Deploy Your First Model

Create a deployment YAML file `agg_router.yaml`:

```yaml
# agg_router.yaml
apiVersion: nvidia.com/v1alpha1
kind: DynamoGraphDeployment
metadata:
  name: vllm-agg-router
spec:
  services:
    Frontend:
      dynamoNamespace: vllm-agg-router
      componentType: frontend
      replicas: 1
      extraPodSpec:
        mainContainer:
          image: nvcr.io/nvidia/ai-dynamo/vllm-runtime:0.5.0
      envs:
        - name: DYN_ROUTER_MODE
          value: kv
    VllmDecodeWorker:
      envFromSecret: hf-token-secret
      dynamoNamespace: vllm-agg-router
      componentType: worker
      replicas: 1
      resources:
        limits:
          gpu: "1"
      envs:
        - name: DYN_LOG
          value: "info"
      extraPodSpec:
        volumes:
        - name: local-model-cache
          hostPath:
            path: /data/huggingface-cache  # Update if instructor provides different path
            type: DirectoryOrCreate
        mainContainer:
          image: nvcr.io/nvidia/ai-dynamo/vllm-runtime:0.5.0
          volumeMounts:
          - name: local-model-cache
            mountPath: /root/.cache
          workingDir: /workspace/components/backends/vllm
          command:
            - /bin/sh
            - -c
          args:
            - python3 -m dynamo.vllm --model Qwen/Qwen2.5-1.5B-Instruct
```

Deploy the model:



```python
%%python
# Apply the deployment
kubectl apply -f agg_router.yaml --namespace ${NAMESPACE}

# Monitor deployment progress
kubectl get dynamographdeployment -n ${NAMESPACE}

# Watch pods starting up (this takes 4-6 minutes for first run)
kubectl get pods -n ${NAMESPACE} -w
# Press Ctrl+C to stop watching

# Check specific pod status
kubectl get pods -n ${NAMESPACE} | grep vllm

# View worker logs to see model loading progress
WORKER_POD=$(kubectl get pods -n ${NAMESPACE} | grep vllmdecodeworker | head -1 | awk '{print $1}')
kubectl logs ${WORKER_POD} -n ${NAMESPACE} --tail=50 --follow
```

### A4. Test the Deployment



```python
%%python
# Forward the frontend service port (run in a separate terminal, or add & to background)
kubectl port-forward deployment/vllm-agg-router-frontend 10000:8000 -n ${NAMESPACE}

# In another terminal, test the deployment:

# Test 1: Check available models
curl http://localhost:10000/v1/models

# Test 2: Simple non-streaming chat completion
curl http://localhost:10000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen2.5-1.5B-Instruct",
    "messages": [{"role": "user", "content": "Hello! How are you?"}],
    "stream": false,
    "max_tokens": 50
  }'

# Test 3: Streaming chat completion
curl http://localhost:10000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen2.5-1.5B-Instruct",
    "messages": [{"role": "user", "content": "Write a short poem about AI"}],
    "stream": true,
    "max_tokens": 100
  }'

# Test 4: With different parameters
curl http://localhost:10000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen2.5-1.5B-Instruct",
    "messages": [{"role": "user", "content": "Explain quantum computing in one sentence"}],
    "stream": false,
    "temperature": 0.7,
    "max_tokens": 100,
    "top_p": 0.9
  }'
```

### A5. Benchmark with AI-Perf



```python
# Install AI-Perf (if not already installed)
pip install aiperf

# Run a simple benchmark (adjust parameters as needed)
aiperf profile \
  --model Qwen/Qwen2.5-1.5B-Instruct \
  --url http://localhost:10000 \
  --endpoint-type chat \
  --streaming \
  --concurrency 1 \
  --request-count 100

# Run with higher concurrency
aiperf profile \
  --model Qwen/Qwen2.5-1.5B-Instruct \
  --url http://localhost:10000 \
  --endpoint-type chat \
  --streaming \
  --concurrency 4 \
  --request-count 200

# Run with request rate
aiperf profile \
  --model Qwen/Qwen2.5-1.5B-Instruct \
  --url http://localhost:10000 \
  --endpoint-type chat \
  --streaming \
  --request-rate 10 \
  --request-count 200
```

### A6. Scale Your Deployment



```python
%%python
# Edit your agg_router.yaml and change replicas from 1 to 2
# Then reapply:
kubectl apply -f agg_router.yaml --namespace ${NAMESPACE}

# Watch the new worker come online
kubectl get pods -n ${NAMESPACE} -w

# Test that load is distributed (KV-cache routing should work)
# Run multiple requests and check logs from both workers
kubectl logs -l component=VllmDecodeWorker -n ${NAMESPACE} --tail=20
```

### A7. Cleanup



```python
%%python
# Delete the deployment
kubectl delete dynamographdeployment vllm-agg-router -n ${NAMESPACE}

# Verify pods are terminating
kubectl get pods -n ${NAMESPACE}

# (Optional) Keep your namespace for Lab 2
# To completely clean up (only if you're done with all labs):
# kubectl delete namespace ${NAMESPACE}
```

### A8. Troubleshooting



```python
%%python
# Check pod status
kubectl get pods -n ${NAMESPACE}

# Describe a pod to see errors
kubectl describe pod <pod-name> -n ${NAMESPACE}

# View logs from a specific pod
kubectl logs <pod-name> -n ${NAMESPACE}

# Check DynamoGraphDeployment status
kubectl describe dynamographdeployment vllm-agg-router -n ${NAMESPACE}

# Check operator logs
kubectl logs -l app.kubernetes.io/name=dynamo-operator -n ${NAMESPACE}

# Check if image pull is working
kubectl get events -n ${NAMESPACE} --sort-by='.lastTimestamp'
```



