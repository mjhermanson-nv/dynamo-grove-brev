---
jupyter:
  jupytext:
    cell_metadata_filter: -all
    formats: ipynb,md
    main_language: bash
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
- Set up your personal namespace in the shared Kubernetes cluster
- Deploy Dynamo using namespace-scoped operator on Kubernetes
- Configure a backend engine using aggregated serving
- Test the deployment with OpenAI-compatible API
- Benchmark the deployment using AI-Perf

## Duration: ~90 minutes

---

## Section 1: Environment Setup

### Objectives
- Verify Kubernetes access (shared cluster)
- Create your personal namespace
- Install Dynamo dependencies in your namespace
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
import os

# Set lab configuration
os.environ['RELEASE_VERSION'] = '0.7.1'
os.environ['NAMESPACE'] = 'dynamo-lab1'
os.environ['HF_TOKEN'] = ''  # Will be set securely in a later cell
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

#### Login to NGC Container Registry


```bash
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

HuggingFace token is required to download models. Get yours from https://huggingface.co/settings/tokens

```bash
import os
import getpass

# Get HuggingFace token from user
print("Enter your HuggingFace Token from https://huggingface.co/settings/tokens")
print("(Create a 'Read' token if you don't have one)")
print("")
HF_TOKEN = getpass.getpass("HF Token: ")

# Save to environment
os.environ['HF_TOKEN'] = HF_TOKEN
print("✓ HuggingFace token saved to environment")
```

#### Login to NGC Registry

```bash
import os
import subprocess

# Login to NGC container registry
ngc_key = os.environ.get('NGC_API_KEY')
result = subprocess.run(
    ['helm', 'registry', 'login', 'nvcr.io', '--username', '$oauthtoken', '--password-stdin'],
    input=ngc_key,
    text=True,
    capture_output=True
)
print(result.stdout)
if result.returncode != 0:
    print(result.stderr)

print("")
print("✓ NGC authentication complete")
print("  You can now pull Dynamo container images")
```

### Step 5: Create Your Namespace

```bash
import os
import subprocess

# Create the namespace
namespace = os.environ.get('NAMESPACE', 'dynamo-lab1')
result = subprocess.run(['kubectl', 'create', 'namespace', namespace], 
                       capture_output=True, text=True)
print(result.stdout)
if result.returncode != 0 and "AlreadyExists" not in result.stderr:
    print(result.stderr)

# Verify namespace was created
result = subprocess.run(['kubectl', 'get', 'namespace', namespace], 
                       capture_output=True, text=True)
print(result.stdout)
```

### Step 6: Create NGC Pull Secret

Create a Kubernetes secret so that pods can pull images from NGC.

```bash
import os
import subprocess

# Get variables
namespace = os.environ.get('NAMESPACE', 'dynamo-lab1')
ngc_key = os.environ.get('NGC_API_KEY')

# Create NGC image pull secret
result = subprocess.run([
    'kubectl', 'create', 'secret', 'docker-registry', 'ngc-secret',
    '--docker-server=nvcr.io',
    '--docker-username=$oauthtoken',
    f'--docker-password={ngc_key}',
    '--namespace', namespace
], capture_output=True, text=True)

print(result.stdout)
if result.returncode != 0 and "AlreadyExists" not in result.stderr:
    print(result.stderr)
else:
    # Verify secret was created
    result = subprocess.run(['kubectl', 'get', 'secret', 'ngc-secret', '-n', namespace], 
                           capture_output=True, text=True)
    print(result.stdout)
    print(f"✓ NGC pull secret created in namespace: {namespace}")
```

### Step 7: Create HuggingFace Token Secret

```bash
import os
import subprocess

# Get variables
namespace = os.environ.get('NAMESPACE', 'dynamo-lab1')
hf_token = os.environ.get('HF_TOKEN', '')

# Create HuggingFace token secret
result = subprocess.run([
    'kubectl', 'create', 'secret', 'generic', 'hf-token-secret',
    f'--from-literal=HF_TOKEN={hf_token}',
    '--namespace', namespace
], capture_output=True, text=True)

print(result.stdout)
if result.returncode != 0 and "AlreadyExists" not in result.stderr:
    print(result.stderr)
else:
    # Verify secret was created
    result = subprocess.run(['kubectl', 'get', 'secret', 'hf-token-secret', '-n', namespace], 
                           capture_output=True, text=True)
    print(result.stdout)
    print("✓ HuggingFace token secret created")
```

## Section 2: Install Dynamo Platform

### Objectives
- Install Dynamo CRDs (Custom Resource Definitions)
- Install Dynamo platform (etcd, NATS, operator) 
- Verify platform components are running

### Architecture
```
Client Request
      ↓
Frontend (OpenAI API + Disaggregated Router)
      ↓
Prefill Worker (GPU 0) → Processes prompt → Generates KV cache
      ↓
Decode Worker (GPU 1) → Uses KV cache → Generates tokens
      ↓
      ↓
   etcd + NATS (Coordination & Messaging)
      ↓
Dynamo Operator (Manages Resources)
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
echo "Installing Dynamo CRDs..."
helm fetch https://helm.ngc.nvidia.com/nvidia/ai-dynamo/charts/dynamo-crds-$RELEASE_VERSION.tgz
helm install dynamo-crds dynamo-crds-$RELEASE_VERSION.tgz --namespace default

echo ""
echo "Verifying CRD installation:"
kubectl get crd | grep nvidia.com
```

### Step 2: Install Dynamo Platform

This installs ETCD, NATS, and the Dynamo Operator Controller (cluster-wide by default).


```bash
import subprocess
import os

release_version = os.environ.get('RELEASE_VERSION', '0.7.1')
namespace = os.environ.get('NAMESPACE', 'dynamo-lab1')

# Download platform chart
chart_url = f"https://helm.ngc.nvidia.com/nvidia/ai-dynamo/charts/dynamo-platform-{release_version}.tgz"
subprocess.run(['helm', 'fetch', chart_url])

# Install Dynamo platform (cluster-wide by default - recommended)
print(f"Installing Dynamo platform in namespace: {namespace}")
subprocess.run([
    'helm', 'install', 'dynamo-platform',
    f'dynamo-platform-{release_version}.tgz',
    '--namespace', namespace
])

print("")
print("Platform installation initiated. Waiting for pods to be ready...")
```

### Step 3: Wait for Platform Pods to Be Ready

Re-run the following cell until all pods report as "Running"


```bash
import subprocess
import os

namespace = os.environ.get('NAMESPACE', 'dynamo-lab1')

# Check pods in namespace
subprocess.run(['kubectl', 'get', 'pods', '-n', namespace])
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

### Step 1: Update the Deployment Configuration

Before deploying, we need to update the YAML configuration with your specific values:


```bash
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
import subprocess
import os

namespace = os.environ.get('NAMESPACE', 'dynamo-lab1')

# Apply the deployment
result = subprocess.run(
    ['kubectl', 'apply', '-f', 'agg_router.yaml', '--namespace', namespace],
    capture_output=True,
    text=True
)

print(result.stdout)
if result.stderr:
    print(result.stderr)

print("")
print("✓ Deployment created. This will take 4-6 minutes for first run.")
print("  - Pulling container images")
print("  - Downloading model from HuggingFace")
print("  - Loading model into GPU memory")
```

### Step 3: Monitor Deployment Progress


```bash
import subprocess
import os

namespace = os.environ.get('NAMESPACE', 'dynamo-lab1')

# Check deployment status
print("Checking DynamoGraphDeployment status:")
subprocess.run(['kubectl', 'get', 'dynamographdeployment', '-n', namespace])

print("\nPod status (wait for all pods to be 1/1 Ready):")
result = subprocess.run(
    ['kubectl', 'get', 'pods', '-n', namespace],
    capture_output=True,
    text=True
)
# Filter for vllm pods - we should see both prefill and decode workers
for line in result.stdout.split('\n'):
    if 'vllm' in line.lower() or 'NAME' in line:
        print(line)

print("\n# Expected pods:")
print("#   - vllm-disagg-router-frontend-xxxxx     (Frontend)")
print("#   - vllm-disagg-router-vllmprefillworker-xxxxx (Prefill Worker on GPU 0)")
print("#   - vllm-disagg-router-vllmdecodeworker-xxxxx  (Decode Worker on GPU 1)")
print("\n# To watch in real-time, run: kubectl get pods -n", namespace, "-w")
```

### Step 4: View Worker Logs (Optional)

While waiting for the deployment, you can watch the model loading progress in both workers.

**Note**: In disaggregated serving, both the prefill and decode workers load the model separately.


```bash
import subprocess
import os

namespace = os.environ.get('NAMESPACE', 'dynamo-lab1')

# Get logs from worker pods
result = subprocess.run(
    ['kubectl', 'get', 'pods', '-n', namespace],
    capture_output=True,
    text=True
)

prefill_pod = None
decode_pod = None
for line in result.stdout.split('\n'):
    if 'vllmprefillworker' in line.lower():
        prefill_pod = line.split()[0]
    elif 'vllmdecodeworker' in line.lower():
        decode_pod = line.split()[0]

if prefill_pod:
    print(f"=== Prefill Worker Logs (GPU 0): {prefill_pod} ===")
    print("Look for:")
    print("  - 'Loading model weights...' (downloading)")
    print("  - 'Model loading took X.XX GiB' (loaded)")
    print("")
    subprocess.run(['kubectl', 'logs', prefill_pod, '-n', namespace, '--tail=30'])
    print("\n")

if decode_pod:
    print(f"=== Decode Worker Logs (GPU 1): {decode_pod} ===")
    print("Look for:")
    print("  - 'Loading model weights...' (downloading)")
    print("  - 'Model loading took X.XX GiB' (loaded)")
    print("")
    subprocess.run(['kubectl', 'logs', decode_pod, '-n', namespace, '--tail=30'])
    
if not prefill_pod and not decode_pod:
    print("Worker pods not found yet, please wait and try again")
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
import subprocess

# Get the node IP
result = subprocess.run(
    ['kubectl', 'get', 'nodes', '-o', 'jsonpath={.items[0].status.addresses[?(@.type=="InternalIP")].address}'],
    capture_output=True,
    text=True
)

node_ip = result.stdout.strip()
print(f"Node IP: {node_ip}")
print("")
print(f"Frontend URL: http://{node_ip}:30100")
print("")
print(f"✓ Access the frontend at: http://{node_ip}:30100")
```

### Step 2: Test the `/v1/models` Endpoint


```bash
import subprocess

# Get node IP
result = subprocess.run(
    ['kubectl', 'get', 'nodes', '-o', 'jsonpath={.items[0].status.addresses[?(@.type=="InternalIP")].address}'],
    capture_output=True,
    text=True
)
node_ip = result.stdout.strip()

# Test the /v1/models endpoint
subprocess.run(['curl', f'http://{node_ip}:30100/v1/models'])
```

### Step 3: Simple Non-Streaming Chat Completion


```bash
import subprocess

# Get node IP
result = subprocess.run(
    ['kubectl', 'get', 'nodes', '-o', 'jsonpath={.items[0].status.addresses[?(@.type=="InternalIP")].address}'],
    capture_output=True,
    text=True
)
node_ip = result.stdout.strip()

# Test non-streaming chat completion
subprocess.run([
    'curl', f'http://{node_ip}:30100/v1/chat/completions',
    '-H', 'Content-Type: application/json',
    '-d', '''{
    "model": "Qwen/Qwen2.5-1.5B-Instruct",
    "messages": [{"role": "user", "content": "Hello! How are you?"}],
    "stream": false,
    "max_tokens": 50
  }'''
])
```

### Step 4: Test Streaming Response


```bash
import subprocess

# Get node IP
result = subprocess.run(
    ['kubectl', 'get', 'nodes', '-o', 'jsonpath={.items[0].status.addresses[?(@.type=="InternalIP")].address}'],
    capture_output=True,
    text=True
)
node_ip = result.stdout.strip()

# Test streaming chat completion
subprocess.run([
    'curl', f'http://{node_ip}:30100/v1/chat/completions',
    '-H', 'Content-Type: application/json',
    '-d', '''{
    "model": "Qwen/Qwen2.5-1.5B-Instruct",
    "messages": [{"role": "user", "content": "Write a short poem about AI"}],
    "stream": true,
    "max_tokens": 100
  }'''
])
```

### Step 5: Test with Different Parameters


```bash
import subprocess

# Get node IP
result = subprocess.run(
    ['kubectl', 'get', 'nodes', '-o', 'jsonpath={.items[0].status.addresses[?(@.type=="InternalIP")].address}'],
    capture_output=True,
    text=True
)
node_ip = result.stdout.strip()

# Test with different parameters
subprocess.run([
    'curl', f'http://{node_ip}:30100/v1/chat/completions',
    '-H', 'Content-Type: application/json',
    '-d', '''{
    "model": "Qwen/Qwen2.5-1.5B-Instruct",
    "messages": [{"role": "user", "content": "Explain quantum computing in one sentence"}],
    "stream": false,
    "temperature": 0.7,
    "max_tokens": 100,
    "top_p": 0.9
  }'''
])
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


```bash
# Install AI-Perf benchmarking tool
!uv pip install aiperf -q
print("✓ AI-Perf installed")
```

### Step 2: Run Baseline Benchmark (Low Concurrency)


```bash
import subprocess

# Get node IP
result = subprocess.run(
    ['kubectl', 'get', 'nodes', '-o', 'jsonpath={.items[0].status.addresses[?(@.type=="InternalIP")].address}'],
    capture_output=True,
    text=True
)
node_ip = result.stdout.strip()

print("Running low concurrency benchmark...")

# Run a simple benchmark with low concurrency
subprocess.run([
    'aiperf', 'profile',
    '--log-level', 'warning',
    '--model', 'Qwen/Qwen2.5-1.5B-Instruct',
    '--url', f'http://{node_ip}:30100',
    '--endpoint-type', 'chat',
    '--streaming',
    '--concurrency', '1',
    '--request-count', '100'
])

print("\n✓ Baseline benchmark complete")
```

### Step 3: Run Benchmark with Higher Concurrency


```bash
import subprocess

# Get node IP
result = subprocess.run(
    ['kubectl', 'get', 'nodes', '-o', 'jsonpath={.items[0].status.addresses[?(@.type=="InternalIP")].address}'],
    capture_output=True,
    text=True
)
node_ip = result.stdout.strip()

print("Running high concurrency benchmark...")

# Test with higher concurrency to stress test
subprocess.run([
    'aiperf', 'profile',
    '--log-level', 'warning',
    '--model', 'Qwen/Qwen2.5-1.5B-Instruct',
    '--url', f'http://{node_ip}:30100',
    '--endpoint-type', 'chat',
    '--streaming',
    '--concurrency', '4',
    '--request-count', '200'
])

print("\n✓ High concurrency benchmark complete")
```

### Step 4: Run Benchmark with Request Rate


```bash
import subprocess

# Get node IP
result = subprocess.run(
    ['kubectl', 'get', 'nodes', '-o', 'jsonpath={.items[0].status.addresses[?(@.type=="InternalIP")].address}'],
    capture_output=True,
    text=True
)
node_ip = result.stdout.strip()

print("Running request rate benchmark...")

# Test with request rate instead of concurrency
subprocess.run([
    'aiperf', 'profile',
    '--log-level', 'warning',
    '--model', 'Qwen/Qwen2.5-1.5B-Instruct',
    '--url', f'http://{node_ip}:30100',
    '--endpoint-type', 'chat',
    '--streaming',
    '--request-rate', '10',
    '--request-count', '200'
])

print("\n✓ Request rate benchmark complete")
```

### Step 5: Analyze Results

Review the benchmark outputs above. Key metrics to look for:
- **Throughput**: requests/second and tokens/second
- **TTFT (Time To First Token)**: How quickly does the first token appear?
- **TPOT (Time Per Output Token)**: Generation speed
- **End-to-end latency**: Total request time



### Cleanup

When you're done with Lab 1, clean up your deployment:


```bash
import subprocess
import os

namespace = os.environ.get('NAMESPACE', 'dynamo-lab1')

# Delete the deployment
subprocess.run(['kubectl', 'delete', 'dynamographdeployment', 'vllm-agg-router', '-n', namespace])

print("")
print("✓ Deployment deleted")
print("Verifying pods are terminating:")
subprocess.run(['kubectl', 'get', 'pods', '-n', namespace])
```

**Note:** Keep your namespace and platform for Lab 2! Only delete the deployment, not the namespace.

## Troubleshooting

### Check Pod Status


```bash
import subprocess
import os

namespace = os.environ.get('NAMESPACE', 'dynamo-lab1')

# Check all pods in your namespace
subprocess.run(['kubectl', 'get', 'pods', '-n', namespace])

print("\n# To describe a specific pod to see errors:")
print(f"# kubectl describe pod <pod-name> -n {namespace}")
```

### View Pod Logs


```bash
import subprocess
import os

namespace = os.environ.get('NAMESPACE', 'dynamo-lab1')

# View logs from a specific component
print("Frontend logs:")
subprocess.run(['kubectl', 'logs', '-l', 'component=Frontend', '-n', namespace, '--tail=50'])

print("\nWorker logs:")
subprocess.run(['kubectl', 'logs', '-l', 'component=VllmDecodeWorker', '-n', namespace, '--tail=50'])
```

### Check Deployment Status


```bash
import subprocess
import os

namespace = os.environ.get('NAMESPACE', 'dynamo-lab1')

# Check DynamoGraphDeployment status
print("DynamoGraphDeployment status:")
subprocess.run(['kubectl', 'describe', 'dynamographdeployment', 'vllm-agg-router', '-n', namespace])

print("\nOperator logs:")
subprocess.run(['kubectl', 'logs', '-l', 'app.kubernetes.io/name=dynamo-operator', '-n', namespace, '--tail=50'])
```

### Check Recent Events


```bash
import subprocess
import os

namespace = os.environ.get('NAMESPACE', 'dynamo-lab1')

# View recent events in your namespace
result = subprocess.run(
    ['kubectl', 'get', 'events', '-n', namespace, '--sort-by=.lastTimestamp'],
    capture_output=True,
    text=True
)

# Show last 20 lines
lines = result.stdout.split('\n')
for line in lines[-20:]:
    if line:
        print(line)
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
- ✅ Kubernetes-based aggregated deployment architecture
- ✅ Creating and managing DynamoGraphDeployment resources
- ✅ Backend engine deployment (vLLM)
- ✅ Testing with OpenAI-compatible API
- ✅ Performance benchmarking with AI-Perf

### Key Takeaways
- Namespace-scoped operators enable safe multi-tenant deployments
- Aggregated serving is simpler to deploy and suitable for single-node models
- KV-cache routing provides intelligent load balancing across replicas
- DynamoGraphDeployment CRD simplifies complex inference deployments
- AI-Perf provides comprehensive performance insights

### Next Steps
- **(Optional)** Complete the **Monitoring Extension** (`lab1-monitoring.md`) to set up Prometheus and Grafana for observability
- In **Lab 2**, you'll explore disaggregated serving with separate prefill and decode workers, and use AIConfigurator to optimize configurations for larger models

---

## Appendix: Step-by-Step Commands

This appendix provides complete commands for each section. Use these as a reference during the lab.

**Note for MicroK8s users:** Replace `kubectl` with `microk8s kubectl` in all commands below, or set up an alias:


```python
alias kubectl='microk8s kubectl'
```

### A1. Environment Setup


```python
# Verify kubectl is installed and configured
kubectl version --client
kubectl cluster-info

# Set your configuration (customize with your name!)
export NAMESPACE="dynamo-yourname"  # Replace 'yourname' with your actual name
export RELEASE_VERSION="0.5.0"     # Dynamo version
export HF_TOKEN="your_hf_token"    # Your HuggingFace token
export CACHE_PATH="/data/huggingface-cache"  # Shared cache path (ask instructor)

# Create your personal namespace
kubectl create namespace ${NAMESPACE}

# Verify namespace was created
kubectl get namespace ${NAMESPACE}

# Check GPU nodes are available (optional)
kubectl get nodes -o custom-columns=NAME:.metadata.name,GPUs:.status.capacity.nvidia\\.com/gpu
```

### A2. Install Dynamo Platform (Namespace-Scoped)


```python
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


```bash
import subprocess

# The frontend is exposed via NodePort on port 30100
# Get the node IP
result = subprocess.run(
    ['kubectl', 'get', 'nodes', '-o', 'jsonpath={.items[0].status.addresses[?(@.type=="InternalIP")].address}'],
    capture_output=True,
    text=True
)
node_ip = result.stdout.strip()
print(f"Frontend URL: http://{node_ip}:30100")
print("\nQuick test commands (run in terminal):\n")
print(f"# Test 1: Check available models")
print(f"curl http://{node_ip}:30100/v1/models\n")
print(f"# Test 2: Simple chat completion")
print(f"curl http://{node_ip}:30100/v1/chat/completions -H 'Content-Type: application/json' -d '{{\"model\": \"Qwen/Qwen2.5-1.5B-Instruct\", \"messages\": [{{\"role\": \"user\", \"content\": \"Hello!\"}}], \"stream\": false, \"max_tokens\": 50}}'")
```

### A5. Benchmark with AI-Perf


```bash
import subprocess

# Get node IP
result = subprocess.run(
    ['kubectl', 'get', 'nodes', '-o', 'jsonpath={.items[0].status.addresses[?(@.type=="InternalIP")].address}'],
    capture_output=True,
    text=True
)
node_ip = result.stdout.strip()
frontend_url = f"http://{node_ip}:30100"

print(f"Benchmarking frontend at: {frontend_url}\n")

# Install AI-Perf (if not already installed)
subprocess.run(['pip', 'install', 'aiperf'], capture_output=True)

print("=== Running benchmarks ===\n")

# Run a simple benchmark (adjust parameters as needed)
print("1. Low concurrency benchmark...")
subprocess.run([
    'aiperf', 'profile',
    '--log-level', 'warning',
    '--model', 'Qwen/Qwen2.5-1.5B-Instruct',
    '--url', frontend_url,
    '--endpoint-type', 'chat',
    '--streaming',
    '--concurrency', '1',
    '--request-count', '100'
])

# Run with higher concurrency
print("\n2. High concurrency benchmark...")
subprocess.run([
    'aiperf', 'profile',
    '--log-level', 'warning',
    '--model', 'Qwen/Qwen2.5-1.5B-Instruct',
    '--url', frontend_url,
    '--endpoint-type', 'chat',
    '--streaming',
    '--concurrency', '4',
    '--request-count', '200'
])

# Run with request rate
print("\n3. Request rate benchmark...")
subprocess.run([
    'aiperf', 'profile',
    '--log-level', 'warning',
    '--model', 'Qwen/Qwen2.5-1.5B-Instruct',
    '--url', frontend_url,
    '--endpoint-type', 'chat',
    '--streaming',
    '--request-rate', '10',
    '--request-count', '200'
])
```

### A6. Scale Your Deployment


```python
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


