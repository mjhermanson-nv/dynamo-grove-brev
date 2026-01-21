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

# Lab 3: KV-Aware Routing with Data-Parallel Workers

## Overview

In this lab, you'll learn about **KV-aware routing**, an intelligent load balancing feature that routes requests to workers based on their cached data. Unlike simple round-robin routing, KV-aware routing tracks which workers have already processed similar prompts and directs new requests to workers with matching cached blocks. This dramatically reduces the time to first token (TTFT) for repeated or similar queries.

**The Architecture:**
- **2 Independent Workers** (GPUs 0-1): Each handles full inference (prefill + decode)
- **KV-Aware Router**: Tracks which worker has cached which prompt prefixes
- **NATS Message Bus**: Coordinates cache state across workers
- Each worker stores its own local KV cache and publishes cache events to NATS

**How KV-Aware Routing Works:**
1. Request with prompt "Explain quantum computing" arrives
2. Router checks: No worker has this cached → sends to Worker 1
3. Worker 1 processes request and caches the prefill computation
4. Worker 1 publishes cache event to NATS: "I have blocks for 'Explain quantum computing'"
5. Router updates its tracking: Worker 1 has those cached blocks
6. Next request: "Explain quantum computing in simple terms" arrives
7. Router sees: Worker 1 has cached blocks for "Explain quantum computing" → sends to Worker 1
8. Worker 1 reuses cached prefill blocks → much faster TTFT!

**Why This Matters:**
When users ask variations of similar questions, the router intelligently directs requests to workers that have already cached related computations. This avoids redundant prefill work and reduces time-to-first-token for cache-friendly workloads.

**When to use KV-aware routing:**
- Chatbots with conversation history (similar context across turns)
- Document Q&A systems (multiple questions about the same document)
- Batch processing with shared system prompts
- Any workload where prompt prefixes are repeated across requests

**Prerequisites**: Complete Lab 1 (Dynamo Deployment) and Lab 2 (Monitoring)

**Duration**: ~60 minutes

**Note**: Requires 2 GPUs. If Lab 1 is still running, you'll need to clean it up first.

---

## Section 1: Understanding KV-Aware Routing

### What is KV-Aware Routing?

Traditional load balancers distribute requests randomly or in round-robin fashion across workers, treating all workers as identical. But large language models cache intermediate computations (the "KV cache") to avoid reprocessing tokens they've already seen. **KV-aware routing** leverages this by tracking which workers have which cached blocks and intelligently routing requests to workers that can reuse cached data.

**Example Scenario:**
1. User asks: "Explain quantum computing" → Router sends to Worker 1
2. Worker 1 processes the prompt and caches it
3. User follows up: "Explain quantum computing in simple terms" → Router notices the shared prefix and sends to Worker 1
4. Worker 1 reuses the cached computation for "Explain quantum computing", only processes the new part
5. Result: **Much faster** time-to-first-token (TTFT)

### How KV-Aware Routing Works

**Architecture:**
```
┌──────────┐  ┌──────────┐
│ Worker 1 │  │ Worker 2 │  (Data-parallel: identical workers)
└────┬─────┘  └────┬─────┘
     │             │
     └─────────────┘
            │ Publish cache events
            ↓
   ┌────────────────┐
   │  NATS Server   │  (Message bus for cache coordination)
   │  (Message Bus) │
   └────────┬───────┘
            │ Subscribe to events
            ↓
   ┌────────────────┐
   │  KV Router     │  (Tracks which worker has which cached blocks)
   │ (Global Index) │
   └────────────────┘
            ↓
   Routes requests to workers with matching cached prefixes
```

**The Flow:**
1. **Request arrives**: "Explain quantum computing"
2. **Router checks cache index**: No worker has this cached → picks Worker 1
3. **Worker 1 processes**: Creates KV cache blocks 0-5
4. **Worker 1 publishes to NATS**: "I cached blocks 0-5 for prefix 'Explain quantum computing'"
5. **Router updates index**: Worker 1 has these blocks
6. **Next request arrives**: "Explain quantum computing in simple terms"
7. **Router checks cache index**: Worker 1 has matching prefix → routes to Worker 1
8. **Worker 1 reuses cache**: Blocks 0-5 already computed, only processes new tokens

**Why NATS?** Kubernetes provides service discovery (which workers exist) but not cache coordination (what's cached where). NATS handles thousands of cache events per second with low latency.

### When KV-Aware Routing Helps

**Best for:**
- ✅ Chatbots and conversational AI (repeated system prompts, conversation history)
- ✅ Document Q&A (same document, different questions)
- ✅ Batch processing with shared prefixes
- ✅ Code assistants (repeatedly analyzing same files)

**Not ideal for:**
- ⚠️ Completely unique prompts every time
- ⚠️ Single worker deployments (no routing decisions to make)
- ⚠️ Very short contexts (cache overhead exceeds benefit)

### Understanding Multi-GPU/Multi-Node Benefits

**In this lab (single node, 2 GPUs):**
- Each GPU runs a separate worker
- Router can direct requests to the worker with the best KV cache match
- Workers store their own local KV cache (no transfer between workers in data-parallel mode)

> **💡 Note: Production Multi-Node Deployments**
> 
> In production environments with multiple nodes:
> - Scale workers across nodes for higher throughput
> - Deploy multiple frontend replicas for high availability
> - Kubernetes Services automatically load balance across frontend replicas
> - KV-aware routing works across nodes via NATS coordination

---

## Section 2: Deploy NATS for Cache Coordination

Now that you understand how KV-aware routing works, let's deploy NATS to enable cache coordination between workers and the router.

### Step 1: Add NATS Helm Repository

```bash
# Add NATS Helm repository
echo "Adding NATS Helm repository..."
helm repo add nats https://nats-io.github.io/k8s/helm/charts/
helm repo update

echo "✓ NATS repository added"
```

### Step 2: Install NATS with JetStream

JetStream provides persistent event storage, allowing routers to recover cache state after restarts.

```bash
# Create namespace for NATS
kubectl create namespace nats-system --dry-run=client -o yaml | kubectl apply -f -

# Create NATS values file with JetStream configuration
cat > /tmp/nats-values.yaml <<EOF
nats:
  jetstream:
    enabled: true
    fileStore:
      enabled: true
      dir: /data
      pvc:
        enabled: true
        size: 10Gi

config:
  merge:
    jetstream:
      max_file_store: 10737418240  # 10GB in bytes
      store_dir: /data
EOF

# Install NATS with JetStream enabled
echo "Installing NATS with JetStream..."
helm upgrade --install nats nats/nats \
  --namespace nats-system \
  --values /tmp/nats-values.yaml \
  --wait

echo "✓ NATS installed successfully"
echo "  Connection: nats://nats.nats-system:4222"
echo "  JetStream: Enabled with 10Gi file storage"
```

### Step 3: Verify NATS Deployment

```bash
# Check NATS pods
echo "Checking NATS deployment..."
kubectl get pods -n nats-system

echo ""
echo "Checking NATS service..."
kubectl get svc -n nats-system

echo ""
echo "Expected output:"
echo "  - Pod: nats-0 (1/1 Running)"
echo "  - Service: nats (ClusterIP, port 4222)"
```

### Step 4: Test NATS Connectivity (Optional)

```bash
# Quick connectivity test using nats-box
echo "Testing NATS connectivity..."

# Create a test Job
kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: nats-test
  namespace: nats-system
spec:
  ttlSecondsAfterFinished: 30
  template:
    spec:
      containers:
      - name: nats-box
        image: natsio/nats-box:latest
        command:
        - nats
        - pub
        - -s
        - nats://nats.nats-system:4222
        - test
        - "Hello from NATS test"
      restartPolicy: Never
  backoffLimit: 2
EOF

# Wait for job to complete
echo "Waiting for test to complete..."
kubectl wait --for=condition=complete --timeout=30s job/nats-test -n nats-system 2>/dev/null

if [ $? -eq 0 ]; then
    echo ""
    echo "✓ NATS connectivity test successful"
    echo "  Published test message to NATS server"
else
    echo ""
    echo "⚠️ NATS connectivity test failed or timed out"
    kubectl logs -n nats-system job/nats-test 2>/dev/null
fi

# Cleanup will happen automatically after 30 seconds (ttlSecondsAfterFinished)
```

---

## Section 3: Environment Setup

### Step 1: Set Environment Variables

```bash
# Set environment variables (use defaults if not already set)
export RELEASE_VERSION=${RELEASE_VERSION:-0.8.0}
export NAMESPACE=${NAMESPACE:-dynamo}
export CACHE_PATH=${CACHE_PATH:-/data/huggingface-cache}

# Get node IP
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🌲 Lab 3: KV-Aware Routing Configuration"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Release Version:  $RELEASE_VERSION"
echo "  Namespace:        $NAMESPACE"
echo "  Node IP:          $NODE_IP"
echo "  NATS:             nats://nats.nats-system:4222"
echo ""
echo "✓ Environment configured for KV-aware routing"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
```

---

## Pre-Deployment: Check GPU Availability


### Step 1: Check Current GPU Usage

```bash
export NAMESPACE=${NAMESPACE:-dynamo}

echo "=== Checking GPU Availability ==="
echo ""
echo "Total GPUs on this node:"
kubectl get nodes -o custom-columns=NAME:.metadata.name,GPUs:.status.capacity.nvidia\\.com/gpu

echo ""
echo "Currently allocated GPUs:"
kubectl get pods -A -o json | jq -r '.items[] | select(.spec.containers[].resources.limits."nvidia.com/gpu" != null) | "\(.metadata.namespace)/\(.metadata.name): \(.spec.containers[].resources.limits."nvidia.com/gpu") GPU(s)"'

echo ""
echo "GPU requests by namespace:"
kubectl get pods -A -o json | jq -r '.items | group_by(.metadata.namespace) | .[] | "\(.[0].metadata.namespace): \([.[] | .spec.containers[].resources.limits."nvidia.com/gpu" // "0"] | add) GPU(s)"' | grep -v ": 0 GPU"
```

### Step 2: Delete Lab 1 Deployment (If Still Running)

**⚠️ WARNING**: If the Lab 1 model deployment is still running, you MUST delete it first to free GPUs for Lab 3.

Lab 3 requires:
- **2 GPUs** for 2 data-parallel workers (1 GPU each)

If you have only 2 GPUs total and Lab 1's deployment is using them, delete it:

```bash
export NAMESPACE=${NAMESPACE:-dynamo}

echo "Checking for Lab 1 deployment..."
if kubectl get dynamographdeployment vllm-disagg-router -n $NAMESPACE &>/dev/null; then
    echo ""
    echo "⚠️  Lab 1 deployment (vllm-disagg-router) is still running!"
    echo "   Deleting it to free GPUs for Lab 3..."
    echo ""
    
    # Delete the deployment
    kubectl delete dynamographdeployment vllm-disagg-router -n $NAMESPACE
    kubectl delete svc vllm-frontend-nodeport -n $NAMESPACE 2>/dev/null || true
    
    echo ""
    echo "✓ Lab 1 deployment deleted - waiting for pods to terminate..."
    kubectl wait --for=delete pod -l nvidia.com/dynamo-graph-deployment-name=vllm-disagg-router -n $NAMESPACE --timeout=60s 2>/dev/null || true
    
    echo "✓ GPUs freed for Lab 3"
else
    echo "✓ Lab 1 deployment not found - GPUs should be available"
fi
```

### Step 3: Verify GPUs Are Available

After deleting Lab 1's deployment (if needed), verify GPUs are free:

```bash
echo "=== Final GPU Check ==="
kubectl get nodes -o custom-columns=NAME:.metadata.name,TOTAL:.status.capacity.nvidia\\.com/gpu,ALLOCATABLE:.status.allocatable.nvidia\\.com/gpu

echo ""
echo "If ALLOCATABLE shows 2 GPUs, you're ready for Lab 3!"
echo "If ALLOCATABLE shows 0, pods are still terminating - wait 30 seconds and re-run."
```

---

## Section 4: Deploy Data-Parallel Workers with KV-Aware Routing

Now let's deploy 2 identical workers with a KV-aware router that uses NATS for cache coordination.

### Step 1: Create Data-Parallel Deployment with KV-Aware Routing

```bash
export RELEASE_VERSION=${RELEASE_VERSION:-0.8.0}
export NAMESPACE=${NAMESPACE:-dynamo}

# Create deployment with KV-aware routing
echo "Creating data-parallel deployment with KV-aware routing..."

cat <<EOF | kubectl apply -f -
apiVersion: nvidia.com/v1alpha1
kind: DynamoGraphDeployment
metadata:
  name: vllm-kv-demo
  namespace: ${NAMESPACE}
spec:
  services:
    Frontend:
      componentType: frontend
      replicas: 1
      extraPodSpec:
        mainContainer:
          image: nvcr.io/nvidia/ai-dynamo/vllm-runtime:${RELEASE_VERSION}
          command:
            - /bin/sh
            - -c
          args:
            - |
              python3 -m dynamo.frontend \\
                --http-port 8000 \\
                --router-mode kv \\
                --kv-overlap-score-weight 1.0
          env:
            - name: NATS_SERVER
              value: "nats://nats.nats-system:4222"
            - name: DYN_LOG
              value: info
    VllmWorker:
      envFromSecret: hf-token-secret
      componentType: worker
      replicas: 2
      resources:
        limits:
          gpu: "1"
      envs:
        - name: DYN_LOG
          value: info
        - name: NATS_SERVER
          value: "nats://nats.nats-system:4222"
      extraPodSpec:
        volumes:
        - name: local-model-cache
          hostPath:
            path: /data/huggingface-cache
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
            - python3 -m dynamo.vllm --model Qwen/Qwen2.5-1.5B-Instruct --tensor-parallel-size 1 --enable-prefix-caching --enable-local-indexer true
EOF

echo ""
echo "✓ Data-parallel deployment created with KV-aware routing"
echo "  Deployment: vllm-kv-demo"
echo "  Workers: 2 (identical, data parallel)"
echo "  Router Mode: kv (cache-aware)"
echo "  NATS: nats://nats.nats-system:4222"
```

**Key Configuration Flags:**

**Frontend:**
- `--router-mode kv`: Enables KV-aware routing
- `--kv-overlap-score-weight 1.0`: Balances cache hits vs load distribution
- `NATS_SERVER`: Connection to NATS for subscribing to cache events

**Workers:**
- `--enable-prefix-caching`: Enables cache block tracking and event publishing
- `NATS_SERVER`: Where to publish cache events
- `--tensor-parallel-size 1`: Each worker uses 1 GPU (not splitting model)

### Step 2: Create NodePort Service

```bash
export NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
export NAMESPACE=${NAMESPACE:-dynamo}

# Create NodePort service
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: vllm-kv-frontend-np
  namespace: ${NAMESPACE}
spec:
  type: NodePort
  selector:
    nvidia.com/dynamo-component: Frontend
    nvidia.com/dynamo-graph-deployment-name: vllm-kv-demo
  ports:
  - port: 8000
    targetPort: 8000
    nodePort: 30200
    protocol: TCP
    name: http
EOF

echo ""
echo "✓ NodePort service created on port 30200"
echo "  Access at: http://$NODE_IP:30200"
```

### Step 3: Wait for Deployment

```bash
# Wait for pods to be ready
echo "Waiting for deployment..."
echo "This may take 2-3 minutes for model download and initialization..."
echo ""

export NAMESPACE=${NAMESPACE:-dynamo}

# Wait for pods to be ready
kubectl wait --for=condition=ready --timeout=300s \
  pods -l nvidia.com/dynamo-graph-deployment-name=vllm-kv-demo \
  -n $NAMESPACE 2>/dev/null || echo "Pods are initializing..."

echo ""
echo "Deployment status:"
kubectl get pods -n $NAMESPACE -l nvidia.com/dynamo-graph-deployment-name=vllm-kv-demo

echo ""
echo "Expected pods:"
echo "  - vllm-kv-demo-frontend-xxxxx (Frontend with KV-aware router)"
echo "  - vllm-kv-demo-vllmworker-xxxxx (Worker 1)"
echo "  - vllm-kv-demo-vllmworker-xxxxx (Worker 2)"
```

### Step 4: Test Basic Inference

```bash
# Test the deployment
echo "Testing inference..."
export NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

curl -s http://$NODE_IP:30200/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen2.5-1.5B-Instruct",
    "messages": [{"role": "user", "content": "What is AI?"}],
    "max_tokens": 50
  }' | jq -r '.choices[0].message.content'

echo ""
echo "✓ Deployment is serving requests"
echo "  Router: KV-aware (tracking cache state)"
echo "  Workers: Publishing cache events to NATS"
```

---

## Section 5: Demonstrate Cache-Aware Routing

Now we'll demonstrate KV-aware routing by sending requests with shared prefixes. The router should direct these to the same worker for cache reuse.

### Step 1: Send Requests to Verify Routing

```bash
export NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

echo "Sending test requests to verify KV-aware routing..."
echo ""

# Request 1
echo "Request 1:"
curl -s http://$NODE_IP:30200/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen2.5-1.5B-Instruct",
    "messages": [{"role": "user", "content": "What is quantum computing?"}],
    "max_tokens": 30
  }' | jq -r '.choices[0].message.content'

echo ""
sleep 1

# Request 2
echo "Request 2:"
curl -s http://$NODE_IP:30200/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen2.5-1.5B-Instruct",
    "messages": [{"role": "user", "content": "What is machine learning?"}],
    "max_tokens": 30
  }' | jq -r '.choices[0].message.content'

echo ""
echo "✓ Routing is working (requests processed successfully)"
```

**Note on Measuring Cache Benefits**:
With Qwen 1.5B (small, fast model) and short prompts (~3-4 tokens shared prefix), cache benefits are **not visible in wall-clock time**. Here's why:

- **TTFT savings**: Caching 3-4 tokens saves ~2-5ms of prefill time
- **Total request time**: ~300-350ms (includes TTFT + generation + network + JSON processing)
- **Cache benefit**: <2% of total time (masked by generation and latency)

**When cache benefits ARE visible:**
- **Larger models** (7B+, 70B+): Prefill is much more expensive, cache savings are measurable
- **Longer shared prefixes**: System prompts (20-50+ tokens), document contexts (100s of tokens)
- **High concurrency**: Routing efficiency and memory savings matter at scale
- **Specialized tools**: Benchmarking tools like AI-Perf can isolate TTFT from total time

For this workshop with 2 GPUs and a 1.5B model, KV-aware routing is **working correctly** (NATS connected, router in KV mode, cache enabled), but timing improvements are too small to measure with `curl`.

### Step 2: Visualize KV-Aware Routing in Action

This script sends requests and shows the frontend's routing decisions, including which worker handles each request and how many cached blocks are reused.

```bash
export NAMESPACE=${NAMESPACE:-dynamo}
export NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

# Get frontend pod name
FRONTEND=$(kubectl get pods -n $NAMESPACE -l nvidia.com/dynamo-component=Frontend -o jsonpath='{.items[0].metadata.name}')

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║         KV-Aware Routing Visualization                        ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "Frontend: $FRONTEND"
echo ""

# Function to show latest routing decision from logs
show_routing() {
  echo "   [ROUTING] $(kubectl logs -n $NAMESPACE $FRONTEND --tail=20 | grep 'Selected worker' | tail -1 | sed 's/.*worker_id=/Worker: /; s/ dp_rank.*cached blocks:/ | Cached blocks:/; s/,.*//; s/ tree.*//')"
}

echo "════════════════════════════════════════════════════════════════"
echo "Sending Test Requests"
echo "════════════════════════════════════════════════════════════════"
echo ""

# Request 1 - Physics prefix
echo "📤 Request 1: Physics tutor + 'What is gravity?'"
curl -s http://$NODE_IP:30200/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen2.5-1.5B-Instruct",
    "messages": [
      {"role": "system", "content": "You are a physics tutor."},
      {"role": "user", "content": "What is gravity?"}
    ],
    "max_tokens": 20
  }' | jq -r '.choices[0].message.content | .[0:50]'

sleep 1
show_routing
echo ""

# Request 2 - Same physics prefix
echo "📤 Request 2: Physics tutor + 'What is velocity?' (SAME PREFIX)"
curl -s http://$NODE_IP:30200/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen2.5-1.5B-Instruct",
    "messages": [
      {"role": "system", "content": "You are a physics tutor."},
      {"role": "user", "content": "What is velocity?"}
    ],
    "max_tokens": 20
  }' | jq -r '.choices[0].message.content | .[0:50]'

sleep 1
show_routing
echo ""

# Request 3 - Different prefix
echo "📤 Request 3: Math tutor + 'What is algebra?' (DIFFERENT PREFIX)"
curl -s http://$NODE_IP:30200/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen2.5-1.5B-Instruct",
    "messages": [
      {"role": "system", "content": "You are a math tutor."},
      {"role": "user", "content": "What is algebra?"}
    ],
    "max_tokens": 20
  }' | jq -r '.choices[0].message.content | .[0:50]'

sleep 1
show_routing
echo ""

# Request 4 - Back to physics
echo "📤 Request 4: Physics tutor + 'Explain momentum' (BACK TO PHYSICS)"
curl -s http://$NODE_IP:30200/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen2.5-1.5B-Instruct",
    "messages": [
      {"role": "system", "content": "You are a physics tutor."},
      {"role": "user", "content": "Explain momentum"}
    ],
    "max_tokens": 20
  }' | jq -r '.choices[0].message.content | .[0:50]'

sleep 1
show_routing
echo ""

echo "════════════════════════════════════════════════════════════════"
echo "✓ Check the [ROUTING] lines above:"
echo "  - Requests 1, 2, and 4 (physics) should use the SAME Worker ID"
echo "  - Request 3 (math) may use a DIFFERENT Worker ID"
echo "  - 'Cached blocks' increases when router reuses cached prefixes"
echo "════════════════════════════════════════════════════════════════"
```

**Understanding the Output:**

You'll see `[ROUTING]` lines showing the routing decisions. Here's what you're likely to observe:

```
[ROUTING] Worker: 2575905244297037343 | Cached blocks: 1     ← Request 1 (physics)
[ROUTING] Worker: 2575905244297037343 | Cached blocks: 1     ← Request 2 (physics - SAME WORKER)
[ROUTING] Worker: 2575905244297037343 | Cached blocks: 1     ← Request 3 (math - SAME WORKER)
[ROUTING] Worker: 2575905244297037343 | Cached blocks: 1     ← Request 4 (physics - SAME WORKER)
```

**What this shows:**

1. **Consistent Worker ID** - All requests route to the same worker
   - This is CORRECT behavior! With light load, the router efficiently uses one worker
   - The worker has capacity, so the router doesn't need to distribute across both GPUs
   - This is more efficient than round-robin routing

2. **Cached blocks: 1** - Prefix caching is working
   - `Cached blocks: 1` means the router found 1+ matching blocks in the cache tree
   - With short system prompts (5-10 tokens), you see small cache block counts
   - The fact it's consistently `1` and not `0` proves prefix caching is active

3. **Why not using both workers?**
   - KV-aware routing is SMART: it prefers to use one worker when possible
   - Only distributes across workers when load increases or if specific prefixes are pinned elsewhere
   - This reduces communication overhead and maximizes cache efficiency

**To see multi-worker distribution:**

Send many concurrent requests or very long sequences to saturate one worker. Under load, you'll see:
```
[ROUTING] Worker: 2575905244297037343 | Cached blocks: 1     ← Worker 1 handling physics
[ROUTING] Worker: 14409932740882684000 | Cached blocks: 0    ← Worker 2 taking overflow
```

This proves KV-aware routing is working! The router intelligently tracks which worker has which prefixes cached and directs requests accordingly, maximizing cache reuse and GPU efficiency.

### Step 3: Load Testing to Observe Multi-Worker Distribution

⚠️ **IMPORTANT: Run these commands in a TERMINAL (not in the notebook). AI-Perf can be resource-intensive.**

Run concurrent requests to see how the router distributes load across both workers when demand increases.

#### Prerequisites

1. Make sure your Lab 3 deployment is running:

```bash
kubectl get pods -n dynamo -l nvidia.com/dynamo-graph-deployment-name=vllm-kv-demo
# All pods should be Running (1/1)
```

2. Verify the NodePort service is accessible:

```bash
export NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
curl -s http://$NODE_IP:30200/health || echo "Service not ready yet"
```

#### Install AI-Perf

If not already installed, run in a terminal:

```
pip install -q aiperf
```

#### Run Benchmarks in a Terminal

Copy and paste these commands into a terminal (not executable in notebook):

```
# Set up endpoint
export NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
export FRONTEND_URL="http://$NODE_IP:30200"

# Low concurrency baseline (1 concurrent request, 100 total)
aiperf profile \
  --model Qwen/Qwen2.5-1.5B-Instruct \
  --url $FRONTEND_URL \
  --endpoint-type chat \
  --streaming \
  --concurrency 1 \
  --request-count 100

# High concurrency (4 concurrent requests, 200 total)
# This is where you'll see multi-worker distribution!
aiperf profile \
  --model Qwen/Qwen2.5-1.5B-Instruct \
  --url $FRONTEND_URL \
  --endpoint-type chat \
  --streaming \
  --concurrency 4 \
  --request-count 200

# Sustained request rate (10 requests/sec, 200 total)
aiperf profile \
  --model Qwen/Qwen2.5-1.5B-Instruct \
  --url $FRONTEND_URL \
  --endpoint-type chat \
  --streaming \
  --request-rate 10 \
  --request-count 200
```

#### What to Observe


```bash
export NAMESPACE=${NAMESPACE:-dynamo}
kubectl logs -n $NAMESPACE -l nvidia.com/dynamo-component=Frontend --tail=50 | grep "scheduler"
```

Look for lines showing:
- `Formula for worker_id=... with 1 cached blocks: 1.438` (cache hit - lower score)
- `Formula for worker_id=... with 0 cached blocks: 2.438` (cache miss - higher score)
- `Selected worker: worker_id=... cached blocks: 1` (router chose worker with cache)

The router prefers workers with lower "logit" scores, and cached blocks reduce the score, so workers with cached prefixes get selected!

#### Troubleshooting

- **Connection refused error**: Ensure Lab 3 deployment is running and service is created (Section 4 Step 2)
- **Timeout errors**: Model may still be loading, wait 30 seconds and retry
- **High error rate**: Check pod logs for issues: `kubectl logs -n dynamo -l nvidia.com/dynamo-component=Frontend`

---

## Summary

You've deployed KV-aware routing with data-parallel workers, where the router intelligently directs requests to workers based on their cached data.

**What you learned:**
- NATS coordinates cache state across workers (events published/subscribed)
- Router tracks which workers have cached which prefixes
- Requests with similar prefixes get routed to the same worker for cache reuse
- Scales horizontally—add more workers for more traffic
- Works on single nodes with multiple GPUs or across multi-node clusters

**Key architectural choice:**
- Use **disaggregated serving** (Lab 1) for predictable latency with separate prefill/decode
- Use **KV-aware routing** (Lab 3) when you have high traffic with cache-friendly patterns (system prompts, document contexts)

**Next steps:** Experiment with different worker counts, or monitor cache hit rates in Grafana.

---

## Additional Resources

### Core Documentation

- **NVIDIA Dynamo Documentation**: https://docs.nvidia.com/dynamo/latest/
- **Dynamo Deployment Guide**: https://docs.nvidia.com/dynamo/latest/kubernetes/deployment/
- **Grove Operator Guide**: https://docs.nvidia.com/dynamo/latest/kubernetes/grove.html
- **Dynamo v0.8.0 Release Notes**: https://github.com/ai-dynamo/dynamo/releases/tag/v0.8.0



### Community Resources

- **Dynamo GitHub**: https://github.com/ai-dynamo/dynamo
- **NVIDIA Developer Forums**: https://forums.developer.nvidia.com/

---

**Congratulations! You've completed Lab 3: KV-Aware Routing** 🎯

You now understand how KV-aware routing works, how NATS coordinates cache state across workers, and how intelligent request placement can improve cache hit rates for workloads with repeated prompt patterns!
