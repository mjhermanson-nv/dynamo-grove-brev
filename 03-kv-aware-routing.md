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

# Install NATS with JetStream enabled
echo "Installing NATS with JetStream..."
helm upgrade --install nats nats/nats \
  --namespace nats-system \
  --set nats.jetstream.enabled=true \
  --set nats.jetstream.memStorage.enabled=true \
  --set nats.jetstream.memStorage.size=1Gi \
  --set nats.jetstream.fileStorage.enabled=true \
  --set nats.jetstream.fileStorage.size=2Gi \
  --wait

echo "✓ NATS installed successfully"
echo "  Connection: nats://nats.nats-system:4222"
echo "  JetStream: Enabled (1Gi memory + 2Gi disk)"
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
# Quick connectivity test (publishes a test message)
kubectl run --rm nats-test --image=natsio/nats-box:latest --restart=Never -- \
  nats pub -s nats://nats.nats-system:4222 test "Hello from NATS test"

# If successful, you'll see "Published [test] : 'Hello from NATS test'"
echo "✓ NATS is reachable and accepting connections"
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
    echo "   This deployment is using GPUs needed for Lab 3."
    echo ""
    echo "Delete Lab 1 deployment? (you can redeploy it later)"
    echo ""
    echo "Run: kubectl delete dynamographdeployment vllm-disagg-router -n $NAMESPACE"
    echo "     kubectl delete svc vllm-frontend-nodeport -n $NAMESPACE"
    echo ""
    echo "Or press Ctrl+C to keep Lab 1 running (Lab 3 will fail if insufficient GPUs)"
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
      dynamoNamespace: vllm-kv-demo
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
      dynamoNamespace: vllm-kv-demo
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
            - python3 -m dynamo.vllm --model Qwen/Qwen2.5-1.5B-Instruct --tensor-parallel-size 1 --enable-prefix-caching
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

### Step 1: Send Requests with Shared Prefix

```bash
export NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

echo "Demonstrating KV-aware routing with shared prefix..."
echo "All requests start with 'Explain quantum computing'"
echo ""

# Request 1: Baseline (cache miss expected)
echo "Request 1: Full explanation (cache miss expected)"
time curl -s http://$NODE_IP:30200/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen2.5-1.5B-Instruct",
    "messages": [{"role": "user", "content": "Explain quantum computing"}],
    "max_tokens": 50
  }' | jq -r '.choices[0].message.content'

echo ""
sleep 2

# Request 2: Similar prefix (cache hit expected)
echo "Request 2: Simple explanation (cache hit expected - shared prefix)"
time curl -s http://$NODE_IP:30200/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen2.5-1.5B-Instruct",
    "messages": [{"role": "user", "content": "Explain quantum computing in simple terms"}],
    "max_tokens": 50
  }' | jq -r '.choices[0].message.content'

echo ""
sleep 2

# Request 3: Another variation (cache hit expected)
echo "Request 3: Brief explanation (cache hit expected - shared prefix)"
time curl -s http://$NODE_IP:30200/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen2.5-1.5B-Instruct",
    "messages": [{"role": "user", "content": "Explain quantum computing briefly"}],
    "max_tokens": 50
  }' | jq -r '.choices[0].message.content'

echo ""
echo "✓ Requests completed"
echo "  Request 1 should be slower (no cache)"
echo "  Requests 2-3 should be faster (cache hits with KV-aware routing)"
```

**Expected Behavior:**
- Request 1: Slower TTFT (Time To First Token) - no cached blocks
- Requests 2 & 3: Faster TTFT - router directs to worker with cached prefix "Explain quantum computing"

### Step 2: Check Worker Logs for Cache Activity

```bash
export NAMESPACE=${NAMESPACE:-dynamo}

# Get worker pod names  
WORKER_PODS=$(kubectl get pods -n $NAMESPACE -l nvidia.com/dynamo-component=VllmWorker,nvidia.com/dynamo-graph-deployment-name=vllm-kv-demo -o jsonpath='{.items[*].metadata.name}')

echo "Checking worker logs for cache events..."
for POD in $WORKER_PODS; do
    echo ""
    echo "=== Worker: $POD ==="
    kubectl logs -n $NAMESPACE $POD --tail=30 | grep -E "(prefix.*cache|kv.*cache|blocks)" || echo "No cache messages in recent logs"
done
```

**What to look for:**
- "Prefix cache hit" messages
- Block allocation/reuse statistics
- Most requests should hit the same worker (indicated by same pod having activity)

### Step 3: Conversation-Style Traffic (System Prompt Reuse)

```bash
export NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

echo "Testing cache reuse with shared system prompt..."

# Turn 1
echo "Turn 1: Physics question"
curl -s http://$NODE_IP:30200/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen2.5-1.5B-Instruct",
    "messages": [
      {"role": "system", "content": "You are a helpful AI assistant specialized in physics. Always explain concepts clearly."},
      {"role": "user", "content": "What is quantum mechanics?"}
    ],
    "max_tokens": 80
  }' | jq -r '.choices[0].message.content'

echo ""
sleep 2

# Turn 2 (shares system prompt - cache hit expected)
echo "Turn 2: Different question, same system prompt"
curl -s http://$NODE_IP:30200/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen2.5-1.5B-Instruct",
    "messages": [
      {"role": "system", "content": "You are a helpful AI assistant specialized in physics. Always explain concepts clearly."},
      {"role": "user", "content": "What is relativity?"}
    ],
    "max_tokens": 80
  }' | jq -r '.choices[0].message.content'

echo ""
echo "✓ Both requests shared the system prompt"
echo "  KV-aware router should route to same worker for cache reuse"
echo "  System prompt tokens (cached): ~20 tokens"
echo "  Only the user questions needed to be processed fresh"
```

### Step 4: Check Worker Logs for Cache Activity

```bash
# Get cache stats from worker logs
export NAMESPACE=${NAMESPACE:-dynamo}

WORKER_POD=$(kubectl get pods -n $NAMESPACE -l nvidia.com/dynamo-component=VllmWorker,nvidia.com/dynamo-graph-deployment-name=vllm-kv-demo -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -n "$WORKER_POD" ]; then
    echo "Checking cache activity in worker logs..."
    echo ""
    kubectl logs -n $NAMESPACE $WORKER_POD --tail=100 | grep -i "cache\|prefix" | tail -10
    
    echo ""
    echo "Worker pod: $WORKER_POD"
    echo ""
    echo "What to look for:"
    echo "  - Prefix cache hits/misses"
    echo "  - KV cache block creation events"
    echo "  - Cache eviction messages"
    echo "  - NATS connection status"
else
    echo "⚠️ No worker pods found"
    echo "Make sure the vllm-kv-demo deployment is running"
fi
```

**What to observe:**
- Prefix cache hit/miss rates in worker logs
- NATS connection status (should be connected)
- Cache block allocation and reuse patterns
- Router routing requests to the same worker for similar prefixes

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
- Use **disaggregated serving** (Lab 1) for predictable latency on individual requests
- Use **distributed serving** (Lab 3) when you have high traffic with cache-friendly patterns

**Next steps:** Experiment with different worker counts, or monitor cache hit rates in Grafana.

---

## Troubleshooting

### Deployment Not Starting

```bash
# Check deployment status
export NAMESPACE=${NAMESPACE:-dynamo}
kubectl describe dynamographdeployment vllm-kv-demo -n $NAMESPACE

# Check pod status
kubectl get pods -n $NAMESPACE -l nvidia.com/dynamo-graph-deployment-name=vllm-kv-demo

# Check worker logs
kubectl logs -n $NAMESPACE -l nvidia.com/dynamo-component=VllmWorker

# Common issues:
# - Insufficient GPU resources
# - Worker gang scheduling waiting for all pods
# - Image pull errors
```

### Workers Not Discovered

```bash
# Check K8s services and endpoints
export NAMESPACE=${NAMESPACE:-dynamo}
kubectl get svc -n $NAMESPACE
kubectl get endpoints -n $NAMESPACE

# Check EndpointSlices (K8s-native discovery)
kubectl get endpointslices -n $NAMESPACE

# Check worker pods are running
kubectl get pods -n $NAMESPACE -l nvidia.com/dynamo-component=VllmWorker

# Common issues:
# - Workers not fully ready (check 1/1 Running)
# - Service selectors not matching pods
# - Network policies blocking communication
```

### No Requests Reaching Workers

```bash
# Test frontend endpoint
export NAMESPACE=${NAMESPACE:-dynamo}
export NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
curl -v http://$NODE_IP:30200/v1/models

# Check frontend logs
kubectl logs -n $NAMESPACE -l nvidia.com/dynamo-component=Frontend

# Verify NodePort service exists
kubectl get svc vllm-kv-frontend-np -n $NAMESPACE

# Common issues:
# - NodePort service not created
# - Frontend pod not ready
# - Port conflicts on node
```

### Understanding Cache Sharing with NIXL

**NIXL** (NVIDIA Inference Transfer Library) handles KV cache transfer between workers:

- Transfers actual KV cache data (gigabytes of tensors)
- Uses RDMA, TCP, or CPU/SSD offload  
- Direct worker-to-worker communication
- Not visible in application logs (happens at library level)

**On Single Node**:
- Cache transfers via NIXL are faster (local)
- Workers coordinate via K8s-native discovery
- Benefits still apply with multiple GPU workers

**Benefits Require**:
- Multiple workers (even on same node)
- Repeated queries with shared prefixes
- Workload that generates cache hits

**For NATS troubleshooting**, check NATS pod logs in the `nats-system` namespace

---

## Appendix A: Cleanup

### Step 1: Remove KV-Aware Routing Deployment

```bash
# Delete the KV-aware routing deployment
echo "Removing KV-aware routing deployment..."
export NAMESPACE=${NAMESPACE:-dynamo}

kubectl delete dynamographdeployment vllm-kv-demo -n $NAMESPACE
kubectl delete svc vllm-kv-frontend-np -n $NAMESPACE

echo "✓ KV-aware routing deployment removed"
```

### Step 2: Verify Lab 1 Deployment is Still Running

Your original Lab 1 deployment should still be running on port 30100:

```bash
# Check Lab 1 deployment status
export NAMESPACE=${NAMESPACE:-dynamo}
export NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

echo "Checking Lab 1 deployment..."
kubectl get dynamographdeployment vllm-disagg-router -n $NAMESPACE

echo ""
echo "Lab 1 pods:"
kubectl get pods -n $NAMESPACE -l nvidia.com/dynamo-graph-deployment-name=vllm-disagg-router

echo ""
echo "✓ Lab 1 deployment is available at: http://$NODE_IP:30100"
echo ""
echo "Test it:"
echo "  curl http://$NODE_IP:30100/v1/models"
```

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
