---
jupyter:
  jupytext:
    cell_metadata_filter: -all
    formats: ipynb,md
    main_language: python
    notebook_metadata_filter: jupytext,-kernelspec,-widgets,-language_info
    text_representation:
      extension: .md
      format_name: markdown
      format_version: '1.3'
      jupytext_version: 1.18.1
---

# Lab 1: Introduction and Kubernetes-Based Deployment

## Overview

In this lab, you will:
- Set up Kubernetes cluster with Dynamo platform
- Deploy Dynamo v0.8.0 using K8s-native discovery (simplified architecture)
- Configure a backend engine using disaggregated serving
- Test the deployment with OpenAI-compatible API
- Benchmark the deployment using AI-Perf

**What's New in v0.8.0:**
- ✅ Kubernetes-native service discovery (no etcd required)
- ✅ TCP transport by default (no NATS required)
- ✅ Validation webhooks for early error detection
- ✅ Enhanced observability with unified tracing
- ✅ Improved disaggregated serving performance

**Duration**: ~90 minutes

---

## Section 1: Environment Setup

### Objectives
- Verify Kubernetes access 
- Install Dynamo dependencies
- Set up prerequisites (kubectl, helm)

### Prerequisites
Before starting, ensure you have:
- ✅ Kubernetes cluster access (kubeconfig provided by instructor)
- ✅ `kubectl` installed (version 1.24+) or `microk8s kubectl`
- ✅ `helm` 3.x installed
- ✅ HuggingFace token from [huggingface.co/settings/tokens](https://huggingface.co/settings/tokens)

### Step 2: Set Configuration Variables

Set your configuration variables. **Replace the values below with your own:**


```bash
# Set environment variables (use defaults if not already set)
export RELEASE_VERSION=${RELEASE_VERSION:-0.8.0}
export NAMESPACE=${NAMESPACE:-dynamo}
export CACHE_PATH=${CACHE_PATH:-/data/huggingface-cache}

# Get node IP
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🎓 Lab 1: Environment Configuration"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Release Version:  $RELEASE_VERSION"
echo "  Namespace:        $NAMESPACE"
echo "  Cache Path:       $CACHE_PATH"
echo "  Node IP:          $NODE_IP"
echo ""
echo "📌 Service Ports (after deployment):"
echo "  Frontend API:     http://$NODE_IP:30100"
echo "  Grafana:          http://$NODE_IP:30080"
echo ""
echo "💡 Note: Frontend will be accessible after deploying in Section 3"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
```

### Step 3: Verify Kubernetes Access


```bash
# Verify kubectl is installed and configured
echo "=== kubectl version ==="
kubectl version --client

echo ""
echo "=== Cluster info ==="
kubectl cluster-info

echo ""
echo "=== GPU nodes ==="
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

#### Set NGC API Key

**Get your NGC API Key from [ngc.nvidia.com](https://ngc.nvidia.com/)** (Go to Profile > Setup > Generate API Key)

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

#### Set HuggingFace Token

**HuggingFace token is required to download models.** Get yours from [huggingface.co/settings/tokens](https://huggingface.co/settings/tokens) (Create a 'Read' token if you don't have one)

```python
import os
import getpass

# Get HuggingFace token from user
print("Enter your HuggingFace Token from https://huggingface.co/settings/tokens")
print("(Create a 'Read' token if you don't have one)")
print("")
HF_TOKEN = getpass.getpass("HF Token: ")

# Save it for later use
os.environ['HF_TOKEN'] = HF_TOKEN

print("")
print("✓ HuggingFace token saved to environment")
print("  Available as $HF_TOKEN in bash cells")
```

#### Login to NGC Registry

```bash
# Login to NGC container registry
echo "$NGC_API_KEY" | helm registry login nvcr.io --username '$oauthtoken' --password-stdin

echo ""
echo "✓ NGC authentication complete"
echo "  You can now pull Dynamo container images"
```

### Step 5: Create Your Namespace

```bash
# Create the namespace
NAMESPACE=${NAMESPACE:-dynamo}

kubectl create namespace $NAMESPACE 2>&1 | grep -v "AlreadyExists" || true

# Verify namespace was created
echo ""
echo "Verifying namespace:"
kubectl get namespace $NAMESPACE
```

### Step 6: Create NGC Pull Secret

Create a Kubernetes secret so that pods can pull images from NGC.

```bash
# Get variables
NAMESPACE=${NAMESPACE:-dynamo}

# Create NGC image pull secret
kubectl create secret docker-registry ngc-secret \
    --docker-server=nvcr.io \
    --docker-username='$oauthtoken' \
    --docker-password="$NGC_API_KEY" \
    --namespace $NAMESPACE \
    2>&1 | grep -v "AlreadyExists" || true

# Verify secret was created
echo ""
echo "Verifying NGC secret:"
kubectl get secret ngc-secret -n $NAMESPACE
echo "✓ NGC pull secret created in namespace: $NAMESPACE"
```

### Step 7: Create HuggingFace Token Secret

```bash
# Get variables
NAMESPACE=${NAMESPACE:-dynamo}

# Create HuggingFace token secret
kubectl create secret generic hf-token-secret \
    --from-literal=HF_TOKEN="$HF_TOKEN" \
    --namespace $NAMESPACE \
    2>&1 | grep -v "AlreadyExists" || true

# Verify secret was created
echo ""
echo "Verifying HuggingFace secret:"
kubectl get secret hf-token-secret -n $NAMESPACE
echo "✓ HuggingFace token secret created"
```

## Section 2: Install Dynamo Platform

### Objectives
- Install Dynamo CRDs (Custom Resource Definitions) with validation webhooks
- Install Dynamo platform (operator with K8s-native discovery)
- Verify platform components are running

### Architecture (v0.8.0 Simplified)

```
Client Request
      ↓
Frontend (OpenAI API + Disaggregated Router)
      ↓
Prefill Worker (GPU 0) → Processes prompt → Generates KV cache
      ↓
Decode Worker (GPU 1) → Uses KV cache → Generates tokens
      ↓
Response to Client

Infrastructure:
- Kubernetes EndpointSlices (service discovery)
- TCP Transport (default, no NATS needed)
- Dynamo Operator (manages deployments)
- Validation Webhooks (catch errors early)

Note: NATS/etcd are optional for extreme scale (Lab 3)
```

### Deployment Mode

We're using the **recommended cluster-wide deployment** (default). According to the [official Dynamo documentation](https://github.com/ai-dynamo/dynamo/blob/main/deploy/helm/charts/platform/README.md):

- ✅ **Recommended**: One cluster-wide operator per cluster (default)
- This is the standard deployment for single-node and production clusters
- Install a **namespace-scoped Dynamo operator** that only manages resources in your namespace
- The CRDs are cluster-wide and should already be installed (check first)

### Step 1: Check if Dynamo CRDs Are Installed

**Note:** CRDs are cluster-wide resources and only need to be installed **once per cluster**. If already installed, skip to Step 2.


```bash
# Check if CRDs already exist
if kubectl get crd dynamographdeployments.nvidia.com &>/dev/null && \
   kubectl get crd dynamocomponentdeployments.nvidia.com &>/dev/null; then
    echo "✓ CRDs already installed"
    kubectl get crd | grep nvidia.com
else
    echo "⚠️  CRDs not found. Ask instructor to install them, or proceed with Step 1b"
fi
```

### Step 1b: Install CRDs (Optional - Instructor May Do This)

**Skip this step if CRDs are already installed.** If needed, run:


```bash
# Install Dynamo CRDs (only if not already installed)
RELEASE_VERSION=${RELEASE_VERSION:-0.8.0}

echo "Installing Dynamo CRDs v$RELEASE_VERSION..."
helm fetch https://helm.ngc.nvidia.com/nvidia/ai-dynamo/charts/dynamo-crds-$RELEASE_VERSION.tgz
helm install dynamo-crds dynamo-crds-$RELEASE_VERSION.tgz --namespace default

echo ""
echo "Verifying CRD installation:"
kubectl get crd | grep nvidia.com
echo ""
echo "✓ v0.8.0 CRDs include validation webhooks for early error detection"
```

### Step 2: Install Dynamo Platform

**Simplified in v0.8.0:** NATS and etcd are now **optional**. Dynamo uses Kubernetes-native service discovery (EndpointSlices) and TCP transport by default, making deployment simpler and reducing infrastructure dependencies.


```bash
RELEASE_VERSION=${RELEASE_VERSION:-0.8.0}
NAMESPACE=${NAMESPACE:-dynamo}

# Download platform chart
echo "Downloading Dynamo platform chart v$RELEASE_VERSION..."
helm fetch https://helm.ngc.nvidia.com/nvidia/ai-dynamo/charts/dynamo-platform-$RELEASE_VERSION.tgz

# Install Dynamo platform (namespace-scoped, K8s-native discovery)
echo "Installing Dynamo platform in namespace: $NAMESPACE"
echo "Using K8s-native discovery (no NATS/etcd required)"
helm install dynamo-platform \
    dynamo-platform-$RELEASE_VERSION.tgz \
    --namespace $NAMESPACE \
    --set dynamo-operator.namespaceRestriction.enabled=true

echo ""
echo "✓ Platform installation initiated"
echo "  Discovery: Kubernetes EndpointSlices (native)"
echo "  Transport: TCP (default in v0.8.0)"
echo ""
echo "Waiting for pods to be ready..."
```

### Step 3: Wait for Platform Pods to Be Ready

Re-run the following cell until all pods report as "Running"


```bash
NAMESPACE=${NAMESPACE:-dynamo}

echo "Waiting for platform pods to be ready..."
echo ""

# Wait for pods to be ready (timeout after 5 minutes)
TIMEOUT=300
ELAPSED=0
INTERVAL=5

while [ $ELAPSED -lt $TIMEOUT ]; do
    # Get pod status
    NOT_READY=$(kubectl get pods -n $NAMESPACE --no-headers 2>/dev/null | grep -v "Running\|Completed" | wc -l)
    TOTAL=$(kubectl get pods -n $NAMESPACE --no-headers 2>/dev/null | wc -l)
    READY=$((TOTAL - NOT_READY))
    
    echo "[$ELAPSED s] Pods ready: $READY/$TOTAL"
    kubectl get pods -n $NAMESPACE
    
    # Check if all pods are ready
    if [ $NOT_READY -eq 0 ] && [ $TOTAL -gt 0 ]; then
        echo ""
        echo "✓ All platform pods are ready!"
        break
    fi
    
    echo ""
    echo "Waiting for pods to be ready... (checking again in ${INTERVAL}s)"
    echo ""
    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
done

if [ $ELAPSED -ge $TIMEOUT ]; then
    echo "⚠️  Timeout waiting for pods to be ready"
    echo "Please check pod status manually: kubectl get pods -n $NAMESPACE"
fi
```





## Section 3: Deploy Your First Model with Disaggregated Serving

### Objectives
- Understand disaggregated serving architecture
- Configure and deploy a model using vLLM backend with separate prefill and decode workers
- Use Kubernetes manifests to deploy Dynamo resources

### Available Backends
In this lab, we'll use **vLLM** with disaggregated serving:
- **vLLM**: High-throughput serving with PagedAttention
- Model: `Qwen/Qwen2.5-1.5B-Instruct` (small, fast to download)
- Architecture: Disaggregated serving with separate prefill and decode workers

**Other backends** (for exploration):
- **SGLang**: Optimized for complex prompting and structured generation
- **TensorRT-LLM**: Maximum performance on NVIDIA GPUs

### What is Disaggregated Serving?

Disaggregated serving separates the inference pipeline into specialized workers:

**Prefill Worker** (GPU 0):
- Processes input prompts (compute-intensive)
- Converts tokens into KV cache
- Passes KV cache to decode workers

**Decode Worker** (GPU 1):
- Generates output tokens (memory-intensive)
- Uses KV cache from prefill worker
- Produces the final response

**Benefits:**
- ✅ **Independent scaling**: Scale prefill and decode separately based on workload
- ✅ **Resource optimization**: Each worker optimized for its specific task
- ✅ **Better throughput**: Specialized workers can handle more requests

**Architecture:**
```
Client Request
    ↓
Frontend (Router)
    ↓
Prefill Worker (GPU 0) → processes prompt → generates KV cache
    ↓
Decode Worker (GPU 1) → receives KV cache → generates tokens
    ↓
Response to Client
```

### Deployment Configuration

We'll use a `DynamoGraphDeployment` resource that defines:
- **Frontend**: OpenAI-compatible API endpoint with disaggregated routing
- **VllmPrefillWorker**: 1 replica on GPU 0 for prompt processing
- **VllmDecodeWorker**: 1 replica on GPU 1 for token generation

### Step 1: Create Deployment Manifest

We will create the `disagg_router.yaml` file dynamically with your specific configuration variables:

```bash
# Create the deployment YAML with environment variables
cat <<EOF > disagg_router.yaml
apiVersion: nvidia.com/v1alpha1
kind: DynamoGraphDeployment
metadata:
  name: vllm-disagg-router
spec:
  services:
    Frontend:
      dynamoNamespace: vllm-disagg-router
      componentType: frontend
      replicas: 1
      extraPodSpec:
        mainContainer:
          image: nvcr.io/nvidia/ai-dynamo/vllm-runtime:$RELEASE_VERSION
      envs:
        - name: DYN_ROUTER_MODE
          value: disaggregated
    VllmPrefillWorker:
      envFromSecret: hf-token-secret
      dynamoNamespace: vllm-disagg-router
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
            path: $CACHE_PATH
            type: DirectoryOrCreate
        mainContainer:
          image: nvcr.io/nvidia/ai-dynamo/vllm-runtime:$RELEASE_VERSION
          securityContext:
            capabilities:
              add:
                - IPC_LOCK
          volumeMounts:
          - name: local-model-cache
            mountPath: /root/.cache
          workingDir: /workspace/components/backends/vllm
          command:
            - /bin/sh
            - -c
          args:
            - python3 -m dynamo.vllm --model Qwen/Qwen2.5-1.5B-Instruct --worker-type prefill
    VllmDecodeWorker:
      envFromSecret: hf-token-secret
      dynamoNamespace: vllm-disagg-router
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
            path: $CACHE_PATH
            type: DirectoryOrCreate
        mainContainer:
          image: nvcr.io/nvidia/ai-dynamo/vllm-runtime:$RELEASE_VERSION
          securityContext:
            capabilities:
              add:
                - IPC_LOCK
          volumeMounts:
          - name: local-model-cache
            mountPath: /root/.cache
          workingDir: /workspace/components/backends/vllm
          command:
            - /bin/sh
            - -c
          args:
            - python3 -m dynamo.vllm --model Qwen/Qwen2.5-1.5B-Instruct --worker-type decode
EOF

echo "✓ Deployment manifest created: disagg_router.yaml"
echo "  Using Image Version: $RELEASE_VERSION"
echo "  Using Cache Path:    $CACHE_PATH"
echo ""
echo "Verify the configuration:"
grep "image:" disagg_router.yaml
```

### Step 2: Deploy the Model


```bash
NAMESPACE=${NAMESPACE:-dynamo}

# Apply the deployment
kubectl apply -f disagg_router.yaml --namespace $NAMESPACE

echo ""
echo "✓ Deployment created. This will take 4-6 minutes for first run."
echo "  - Pulling container images"
echo "  - Downloading model from HuggingFace"
echo "  - Loading model into GPU memory"
```

### Step 2b: Expose Frontend Service via NodePort

**CRITICAL**: By default, the deployment is internal-only. We must expose it via a NodePort Service to access it on port `30100`.

```bash
NAMESPACE=${NAMESPACE:-dynamo}

# Create NodePort service to expose the frontend
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: vllm-frontend-nodeport
  namespace: $NAMESPACE
spec:
  type: NodePort
  selector:
    nvidia.com/dynamo-component: Frontend
    nvidia.com/dynamo-graph-deployment-name: vllm-disagg-router
  ports:
  - port: 8000
    targetPort: 8000
    nodePort: 30100
    protocol: TCP
    name: http
EOF

echo ""
echo "✓ Service exposed on NodePort 30100"
echo "  Access URL: http://$NODE_IP:30100"
echo ""
echo "Note: The service will be accessible once the frontend pod is running."
```

### Step 3: Monitor Deployment Progress


```bash
NAMESPACE=${NAMESPACE:-dynamo}

echo "Expected pods:"
echo "  - vllm-disagg-router-frontend-xxxxx     (Frontend)"
echo "  - vllm-disagg-router-vllmprefillworker-xxxxx (Prefill Worker on GPU 0)"
echo "  - vllm-disagg-router-vllmdecodeworker-xxxxx  (Decode Worker on GPU 1)"
echo ""
echo "Waiting for deployment pods to be ready (this may take 4-6 minutes for first run)..."
echo ""

# Wait for pods to be ready (timeout after 10 minutes for model download)
TIMEOUT=600
ELAPSED=0
INTERVAL=10

while [ $ELAPSED -lt $TIMEOUT ]; do
    # Get vllm pod status
    VLLM_PODS=$(kubectl get pods -n $NAMESPACE 2>/dev/null | grep vllm || true)
    NOT_READY=$(echo "$VLLM_PODS" | grep -v "1/1.*Running" | grep -v "^$" | wc -l)
    TOTAL=$(echo "$VLLM_PODS" | grep -v "^$" | wc -l)
    READY=$((TOTAL - NOT_READY))
    
    echo "[$ELAPSED s] VLLM Pods ready: $READY/$TOTAL"
    kubectl get pods -n $NAMESPACE | grep -E '(NAME|vllm)'
    
    # Check if all vllm pods are ready
    if [ $NOT_READY -eq 0 ] && [ $TOTAL -ge 3 ]; then
        echo ""
        echo "✓ All deployment pods are ready!"
        echo ""
        echo "DynamoGraphDeployment status:"
        kubectl get dynamographdeployment -n $NAMESPACE
        break
    fi
    
    echo ""
    echo "Waiting for pods to be ready... (checking again in ${INTERVAL}s)"
    echo "💡 Tip: Model download happens on first run and may take 3-5 minutes"
    echo ""
    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
done

if [ $ELAPSED -ge $TIMEOUT ]; then
    echo "⚠️  Timeout waiting for pods to be ready"
    echo "Check logs: kubectl logs -l component=VllmPrefillWorker -n $NAMESPACE --tail=50"
fi
```

### Step 3b: Troubleshoot Pod Issues (If Pods Are Crashing)

If your pods are in `Error` or `CrashLoopBackOff` state, run this cell to diagnose:

```bash
NAMESPACE=${NAMESPACE:-dynamo}

echo "=== Pod Status ==="
kubectl get pods -n $NAMESPACE | grep vllm
echo ""

echo "=== GPU Availability ==="
kubectl get nodes -o custom-columns=NAME:.metadata.name,GPUs:.status.capacity.nvidia\\.com/gpu,GPU-Allocatable:.status.allocatable.nvidia\\.com/gpu
echo ""

echo "=== Checking Secrets ==="
kubectl get secret hf-token-secret -n $NAMESPACE &>/dev/null && echo "✓ HF token secret exists" || echo "✗ HF token secret missing!"
kubectl get secret ngc-secret -n $NAMESPACE &>/dev/null && echo "✓ NGC secret exists" || echo "✗ NGC secret missing!"
echo ""

echo "=== Prefill Worker Logs (last 30 lines) ==="
PREFILL_POD=$(kubectl get pods -n $NAMESPACE | grep vllmprefillworker | awk '{print $1}' | head -1)
if [ -n "$PREFILL_POD" ]; then
    kubectl logs $PREFILL_POD -n $NAMESPACE --tail=30
else
    echo "No prefill pod found"
fi
echo ""

echo "=== Decode Worker Logs (last 30 lines) ==="
DECODE_POD=$(kubectl get pods -n $NAMESPACE | grep vllmdecodeworker | awk '{print $1}' | head -1)
if [ -n "$DECODE_POD" ]; then
    kubectl logs $DECODE_POD -n $NAMESPACE --tail=30
else
    echo "No decode pod found"
fi
echo ""

echo "=== Common Issues ==="
echo "1. If 'insufficient gpu' error: You need 2 GPUs for disaggregated serving"
echo "2. If 'HF_TOKEN' error: Make sure you created the hf-token-secret"
echo "3. If 'ImagePullBackOff': Check NGC secret and credentials"
echo "4. If model download errors: Check network connectivity to huggingface.co"
```

### Step 4: View Worker Logs (Optional)

While waiting for the deployment, you can watch the model loading progress in both workers.

**Note**: In disaggregated serving, both the prefill and decode workers load the model separately.


```bash
NAMESPACE=${NAMESPACE:-dynamo}

# Get logs from worker pods
PREFILL_POD=$(kubectl get pods -n $NAMESPACE | grep vllmprefillworker | awk '{print $1}' | head -1)
DECODE_POD=$(kubectl get pods -n $NAMESPACE | grep vllmdecodeworker | awk '{print $1}' | head -1)

if [ -n "$PREFILL_POD" ]; then
    echo "=== Prefill Worker Logs (GPU 0): $PREFILL_POD ==="
    echo "Look for:"
    echo "  - 'Loading model weights...' (downloading)"
    echo "  - 'Model loading took X.XX GiB' (loaded)"
    echo ""
    kubectl logs $PREFILL_POD -n $NAMESPACE --tail=30
    echo ""
fi

if [ -n "$DECODE_POD" ]; then
    echo "=== Decode Worker Logs (GPU 1): $DECODE_POD ==="
    echo "Look for:"
    echo "  - 'Loading model weights...' (downloading)"
    echo "  - 'Model loading took X.XX GiB' (loaded)"
    echo ""
    kubectl logs $DECODE_POD -n $NAMESPACE --tail=30
fi

if [ -z "$PREFILL_POD" ] && [ -z "$DECODE_POD" ]; then
    echo "Worker pods not found yet, please wait and try again"
fi
```

## Section 4: Testing and Validation

### Objectives
- Expose the service locally using port forwarding
- Send test requests to the deployment
- Verify OpenAI API compatibility
- Test streaming and non-streaming responses

### Testing Strategy
Once your deployment is running (`1/1 Ready`), you'll:
1. Forward the frontend service port to localhost
2. Test with curl commands
3. Verify response format and functionality

### Step 1: Set Up Port Forwarding

Forward the service port to localhost (run in background):



### Understanding Disaggregated Serving Trade-offs

Now that your deployment is running, let's understand when and why disaggregated serving is beneficial:

**When to Use Disaggregated:**
- ✅ **Large models** (70B+ parameters) where compute and memory demands differ
- ✅ **High throughput scenarios** where prefill and decode have different scaling needs
- ✅ **Long input prompts** where prefill becomes a bottleneck
- ✅ **Production deployments** with predictable traffic patterns

**When Aggregated is Better:**
- ✅ **Small to medium models** (< 13B parameters) like we're using here
- ✅ **Development and testing** where simplicity matters
- ✅ **Unpredictable workloads** where flexibility is key
- ✅ **Resource-constrained environments** with limited GPUs

**Key Differences:**

| Aspect | Aggregated | Disaggregated |
|--------|-----------|---------------|
| Architecture | Single worker type | Separate prefill & decode |
| GPU Utilization | Both phases on same GPU | Specialized per GPU |
| Scaling | Scale all workers together | Scale prefill/decode independently |
| Complexity | Simpler | More complex coordination |
| Latency | Lower for small batches | Better for large throughput |
| Resource Usage | More flexible | More optimized |

**In this lab:**
We're using disaggregated serving with a small model (1.5B) primarily for **educational purposes** to demonstrate the architecture pattern. In production, you would typically use aggregated serving for models this size.

```bash
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
# Get node IP
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

# Test the /v1/models endpoint
curl http://$NODE_IP:30100/v1/models
```

### Step 3: Simple Non-Streaming Chat Completion


```bash
# Get node IP
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

# Test non-streaming chat completion
curl http://$NODE_IP:30100/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "Qwen/Qwen2.5-1.5B-Instruct",
    "messages": [{"role": "user", "content": "Hello! How are you?"}],
    "stream": false,
    "max_tokens": 50
  }'
```

### Step 4: Test Streaming Response


```bash
# Get node IP
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

# Test streaming chat completion
curl http://$NODE_IP:30100/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "Qwen/Qwen2.5-1.5B-Instruct",
    "messages": [{"role": "user", "content": "Write a short poem about AI"}],
    "stream": true,
    "max_tokens": 100
  }'
```

### Step 5: Test with Different Parameters


```bash
# Get node IP
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

# Test with different parameters
curl http://$NODE_IP:30100/v1/chat/completions \
  -H 'Content-Type: application/json' \
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
import subprocess
import sys

# Ensure pip is available in the venv
print("Setting up pip in venv...")
subprocess.run([sys.executable, "-m", "ensurepip", "--default-pip"], 
               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

# Install AI-Perf in the venv
print("Installing AI-Perf...")
result = subprocess.run([sys.executable, "-m", "pip", "install", "aiperf", "-q"])

if result.returncode == 0:
    print("✓ AI-Perf installed successfully")
    # Verify aiperf can be imported
    verify = subprocess.run([sys.executable, "-c", "import aiperf"], capture_output=True)
    if verify.returncode == 0:
        print("  aiperf is ready to use")
else:
    print("⚠️  Installation had issues, but may still work")
```

### Step 2: Run Baseline Benchmark (Low Concurrency)

**⚠️ IMPORTANT: Run benchmarks in a TERMINAL, not in notebook cells (aiperf can crash the kernel).**

**To run this benchmark:**

1. Open a new terminal (File → New → Terminal in JupyterLab)
2. Copy and paste this command:

```
cd ~/dynamo-grove-brev/resources && ./run-benchmark.sh baseline
```

This will run a low concurrency benchmark (1 concurrent request, 100 total requests) and display metrics including:
- Time to First Token (TTFT)
- Token throughput
- Request latency
- Percentile distributions (p50, p90, p99)

### Step 3: Run Benchmark with Higher Concurrency

**⚠️ IMPORTANT: Run benchmarks in a TERMINAL, not in notebook cells.**

**To run this benchmark:**

1. Open a new terminal (File → New → Terminal in JupyterLab)
2. Copy and paste this command:

```
cd ~/dynamo-grove-brev/resources && ./run-benchmark.sh high
```

This will run a high concurrency benchmark (4 concurrent requests, 200 total requests) to stress test the system and see how it handles multiple simultaneous users.

### Step 4: Run Benchmark with Request Rate

**⚠️ IMPORTANT: Run benchmarks in a TERMINAL, not in notebook cells.**

**To run this benchmark:**

1. Open a new terminal (File → New → Terminal in JupyterLab)
2. Copy and paste this command:

```
cd ~/dynamo-grove-brev/resources && ./run-benchmark.sh rate
```

This will run a request rate benchmark (10 requests per second, 200 total requests) to simulate a steady stream of users hitting the API at a controlled rate.

### Step 5: Analyze Results

Review the benchmark outputs above. Key metrics to look for:
- **Throughput**: requests/second and tokens/second
- **TTFT (Time To First Token)**: How quickly does the first token appear?
- **TPOT (Time Per Output Token)**: Generation speed
- **End-to-end latency**: Total request time



### Cleanup

When you're done with Lab 1, clean up your deployment:


```bash
NAMESPACE=${NAMESPACE:-dynamo}

# Delete the deployment
kubectl delete dynamographdeployment vllm-disagg-router -n $NAMESPACE

# Delete the NodePort service
kubectl delete svc vllm-frontend-nodeport -n $NAMESPACE

echo ""
echo "✓ Deployment and service deleted"
echo "Verifying pods are terminating:"
kubectl get pods -n $NAMESPACE
```

**Note:** Keep your namespace and platform for Lab 2! Only delete the deployment and service, not the namespace.

## Troubleshooting

### Check Pod Status


```bash
NAMESPACE=${NAMESPACE:-dynamo}

# Check all pods in your namespace
kubectl get pods -n $NAMESPACE

echo ""
echo "# To describe a specific pod to see errors:"
echo "# kubectl describe pod <pod-name> -n $NAMESPACE"
```

### View Pod Logs


```bash
NAMESPACE=${NAMESPACE:-dynamo}

# View logs from a specific component
echo "Frontend logs:"
kubectl logs -l component=Frontend -n $NAMESPACE --tail=50

echo ""
echo "Worker logs:"
kubectl logs -l component=VllmDecodeWorker -n $NAMESPACE --tail=50
```

### Check Deployment Status


```bash
NAMESPACE=${NAMESPACE:-dynamo}

# Check DynamoGraphDeployment status
echo "DynamoGraphDeployment status:"
kubectl describe dynamographdeployment vllm-disagg-router -n $NAMESPACE

echo ""
echo "Operator logs:"
kubectl logs -l app.kubernetes.io/name=dynamo-operator -n $NAMESPACE --tail=50
```

### Check Recent Events


```bash
NAMESPACE=${NAMESPACE:-dynamo}

# View recent events in your namespace
kubectl get events -n $NAMESPACE --sort-by=.lastTimestamp | tail -20
```

### Common Issues

1. **ImagePullBackOff**: Check if you have access to NGC containers. Verify image version is correct.
2. **Pods stuck in Pending**: Check if GPU resources are available: `kubectl describe pod <pod-name> -n $NAMESPACE`
3. **Model download slow**: First run takes longer due to model download. Check worker logs for progress.
4. **Port forward not working**: Make sure pods are `1/1 Ready` before forwarding. Kill existing port-forward processes: `pkill -f port-forward`

---

## Summary

### What You Learned
- ✅ How to set up a namespace-scoped Dynamo deployment on Kubernetes
- ✅ Kubernetes-based disaggregated deployment architecture
- ✅ Creating and managing DynamoGraphDeployment resources
- ✅ Backend engine deployment (vLLM)
- ✅ Testing with OpenAI-compatible API
- ✅ Performance benchmarking with AI-Perf

### Key Takeaways
- Namespace-scoped operators enable safe multi-tenant deployments
- Disaggregated serving separates prefill and decode for optimized resource utilization
- KV-cache routing provides intelligent load balancing across replicas
- DynamoGraphDeployment CRD simplifies complex inference deployments
- AI-Perf provides comprehensive performance insights

### Next Steps
- **(Optional)** Complete the **Monitoring Extension** (`lab1-monitoring.md`) to set up Prometheus and Grafana for observability
- In **Lab 2**, you'll explore advanced optimizations and use AIConfigurator to optimize configurations for larger models

---

## Appendix: Step-by-Step Commands

This appendix provides complete commands for each section. Use these as a reference during the lab.

**Note for MicroK8s users:** Replace `kubectl` with `microk8s kubectl` in all commands below, or set up an alias:


```bash
alias kubectl='microk8s kubectl'
```

### A1. Environment Setup


```bash
# Verify kubectl is installed and configured
kubectl version --client
kubectl cluster-info

# Set your configuration
export NAMESPACE="dynamo"
export RELEASE_VERSION="0.7.1"     # Dynamo version
export HF_TOKEN="your_hf_token"    # Your HuggingFace token
export CACHE_PATH="/data/huggingface-cache"  # Shared cache path

# Create your personal namespace
kubectl create namespace ${NAMESPACE}

# Verify namespace was created
kubectl get namespace ${NAMESPACE}

# Check GPU nodes are available (optional)
kubectl get nodes -o custom-columns=NAME:.metadata.name,GPUs:.status.capacity.nvidia\\.com/gpu
```

### A2. Install Dynamo Platform (Namespace-Scoped)


```bash
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

# Step 3: Install namespace-scoped Dynamo platform
# IMPORTANT: --set dynamo-operator.namespaceRestriction.enabled=true restricts operator to this namespace
helm install dynamo-platform dynamo-platform-${RELEASE_VERSION}.tgz \
  --namespace ${NAMESPACE} \
  --set dynamo-operator.namespaceRestriction.enabled=true

# Step 4: Wait for platform pods to be ready (~2-3 minutes)
echo "Waiting for platform pods to be ready..."
kubectl wait --for=condition=ready pod \
  --all \
  --namespace ${NAMESPACE} \
  --timeout=300s

# Step 5: Verify platform is running
kubectl get pods -n ${NAMESPACE}
# You should see: dynamo-operator, etcd, and nats pods in Running state

# Step 6: Create HuggingFace token secret
kubectl create secret generic hf-token-secret \
  --from-literal=HF_TOKEN="${HF_TOKEN}" \
  --namespace ${NAMESPACE}

# Verify secret was created
kubectl get secret hf-token-secret -n ${NAMESPACE}
```

### A3. Deploy Your First Model

Create a deployment YAML file `disagg_router.yaml`:

```yaml
# disagg_router.yaml
apiVersion: nvidia.com/v1alpha1
kind: DynamoGraphDeployment
metadata:
  name: vllm-disagg-router
spec:
  services:
    Frontend:
      dynamoNamespace: vllm-disagg-router
      componentType: frontend
      replicas: 1
      extraPodSpec:
        mainContainer:
          image: nvcr.io/nvidia/ai-dynamo/vllm-runtime:${RELEASE_VERSION}
      envs:
        - name: DYN_ROUTER_MODE
          value: disaggregated
    VllmPrefillWorker:
      envFromSecret: hf-token-secret
      dynamoNamespace: vllm-disagg-router
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
            path: ${CACHE_PATH}  # Defaults to /data/huggingface-cache
            type: DirectoryOrCreate
        mainContainer:
          image: nvcr.io/nvidia/ai-dynamo/vllm-runtime:${RELEASE_VERSION}
          securityContext:
            capabilities:
              add:
                - IPC_LOCK
          volumeMounts:
          - name: local-model-cache
            mountPath: /root/.cache
          workingDir: /workspace/components/backends/vllm
          command:
            - /bin/sh
            - -c
          args:
            - python3 -m dynamo.vllm --model Qwen/Qwen2.5-1.5B-Instruct --worker-type prefill
    VllmDecodeWorker:
      envFromSecret: hf-token-secret
      dynamoNamespace: vllm-disagg-router
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
            path: ${CACHE_PATH}  # Defaults to /data/huggingface-cache
            type: DirectoryOrCreate
        mainContainer:
          image: nvcr.io/nvidia/ai-dynamo/vllm-runtime:${RELEASE_VERSION}
          securityContext:
            capabilities:
              add:
                - IPC_LOCK
          volumeMounts:
          - name: local-model-cache
            mountPath: /root/.cache
          workingDir: /workspace/components/backends/vllm
          command:
            - /bin/sh
            - -c
          args:
            - python3 -m dynamo.vllm --model Qwen/Qwen2.5-1.5B-Instruct --worker-type decode
```

Deploy the model:


```bash
# Apply the deployment
kubectl apply -f disagg_router.yaml --namespace ${NAMESPACE}

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


```bash
# The frontend is exposed via NodePort on port 30100
# Get the node IP
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

echo "Frontend URL: http://$NODE_IP:30100"
echo ""
echo "Quick test commands (run in terminal):"
echo ""
echo "# Test 1: Check available models"
echo "curl http://$NODE_IP:30100/v1/models"
echo ""
echo "# Test 2: Simple chat completion"
echo "curl http://$NODE_IP:30100/v1/chat/completions -H 'Content-Type: application/json' -d '{\"model\": \"Qwen/Qwen2.5-1.5B-Instruct\", \"messages\": [{\"role\": \"user\", \"content\": \"Hello!\"}], \"stream\": false, \"max_tokens\": 50}'"
```

### A5. Benchmark with AI-Perf


```bash
# Get node IP
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
FRONTEND_URL="http://$NODE_IP:30100"

echo "Benchmarking frontend at: $FRONTEND_URL"
echo ""

# Install AI-Perf (if not already installed)
pip install aiperf -q

echo "=== Running benchmarks ==="
echo ""

# Run a simple benchmark (adjust parameters as needed)
echo "1. Low concurrency benchmark..."
aiperf profile     --log-level warning     --model Qwen/Qwen2.5-1.5B-Instruct     --url $FRONTEND_URL     --endpoint-type chat     --streaming     --concurrency 1     --request-count 100

# Run with higher concurrency
echo ""
echo "2. High concurrency benchmark..."
aiperf profile     --log-level warning     --model Qwen/Qwen2.5-1.5B-Instruct     --url $FRONTEND_URL     --endpoint-type chat     --streaming     --concurrency 4     --request-count 200

# Run with request rate
echo ""
echo "3. Request rate benchmark..."
aiperf profile     --log-level warning     --model Qwen/Qwen2.5-1.5B-Instruct     --url $FRONTEND_URL     --endpoint-type chat     --streaming     --request-rate 10     --request-count 200
```

### A6. Scale Your Deployment


```bash
# Edit your disagg_router.yaml and change replicas from 1 to 2
# Then reapply:
kubectl apply -f disagg_router.yaml --namespace ${NAMESPACE}

# Watch the new worker come online
kubectl get pods -n ${NAMESPACE} -w

# Test that load is distributed (KV-cache routing should work)
# Run multiple requests and check logs from both workers
kubectl logs -l component=VllmDecodeWorker -n ${NAMESPACE} --tail=20
```

### A7. Cleanup


```bash
# Delete the deployment
kubectl delete dynamographdeployment vllm-disagg-router -n ${NAMESPACE}

# Delete the NodePort service
kubectl delete svc vllm-frontend-nodeport -n ${NAMESPACE}

# Verify pods are terminating
kubectl get pods -n ${NAMESPACE}

# (Optional) Keep your namespace for Lab 2
# To completely clean up (only if you're done with all labs):
# kubectl delete namespace ${NAMESPACE}
```

### A8. Troubleshooting


```bash
# Check pod status
kubectl get pods -n ${NAMESPACE}

# Describe a pod to see errors
kubectl describe pod <pod-name> -n ${NAMESPACE}

# View logs from a specific pod
kubectl logs <pod-name> -n ${NAMESPACE}

# Check DynamoGraphDeployment status
kubectl describe dynamographdeployment vllm-disagg-router -n ${NAMESPACE}

# Check operator logs
kubectl logs -l app.kubernetes.io/name=dynamo-operator -n ${NAMESPACE}

# Check if image pull is working
kubectl get events -n ${NAMESPACE} --sort-by='.lastTimestamp'
```


