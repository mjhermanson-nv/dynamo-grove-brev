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

# Lab 3: Distributed Dynamo with Multi-GPU/Multi-Node Serving

## Overview

In this lab, you will:
- Deploy distributed Dynamo across multiple GPUs or nodes
- Understand multi-GPU and multi-node serving architectures
- Enable distributed KV cache awareness and transfer via NIXL
- Monitor distributed components with Grafana
- Learn when to add optional infrastructure (NATS/etcd) for large-scale deployments

**Prerequisites**: Complete Lab 1 (Dynamo Deployment) and Lab 2 (Monitoring)

**What You'll Learn:**
- How Dynamo discovers and coordinates workers across GPUs/nodes
- KV cache sharing between workers for improved performance
- Two deployment modes: Standard (built-in) vs Advanced (NATS/etcd)
- Monitoring distributed inference metrics

**Note**: Distributed Dynamo is designed for multi-node Kubernetes clusters or single nodes with multiple GPUs. While we'll deploy it on a single node for learning purposes, maximum benefits are realized when scaling across multiple nodes with high cache hit workloads.

## Duration: ~45 minutes (standard path) / ~75 minutes (with optional NATS/etcd)

---

## Section 1: Understanding Distributed Dynamo Architecture

### What is Grove vs Dynamo?

**Dynamo** is NVIDIA's inference serving framework (the Python code, Router, Frontend, Workers).

**Grove** is the Kubernetes Operator that orchestrates Dynamo deployments (handling CRDs like `DynamoGraphDeployment`, pod gangs, startup order).

**Distributed Dynamo** (orchestrated by Grove) enables:
- **Multi-node deployments** across Kubernetes clusters or multi-GPU single nodes
- **KV-aware routing** where the Router knows which worker has which cache blocks
- **Distributed KV cache transfer** between workers via NIXL (NVIDIA Inference Transfer Library)
- **Coordination and discovery** using either:
  - **K8s-native (v0.8.0+)**: EndpointSlices + TCP (simpler, recommended for most use cases)
  - **NATS/etcd (optional)**: For extreme scale (very large clusters, multi-region, complex topologies)

### Architecture: K8s-Native (Recommended for Most Users)

```
               ┌────────────────────────────┐
               │  Cloud Load Balancer       │
               │  or Ingress Controller     │
               └──────────┬─────────────────┘
                          │
         ┌────────────────┼────────────────┐
         │                │                │
    ┌────▼─────┐    ┌────▼─────┐    ┌────▼─────┐
    │Frontend 1│    │Frontend 2│    │Frontend 3│
    │ (Node 1) │    │ (Node 2) │    │ (Node 3) │
    └────┬─────┘    └────┬─────┘    └────┬─────┘
         │                │                │
         └────────────────┼────────────────┘
                          │
              ┌───────────▼───────────┐
              │ Kubernetes            │
              │  - EndpointSlices     │
              │    (Discovery)        │
              │  - TCP (Transport)    │
              └───────────┬───────────┘
                          │
         ┌────────────────┼────────────────┐
         │                │                │
    ┌────▼─────┐    ┌────▼─────┐    ┌────▼─────┐
    │ Worker 1 │    │ Worker 2 │    │ Worker 3 │
    │ (Node 4) │    │ (Node 5) │    │ (Node 6) │
    │  +GPU    │    │  +GPU    │    │  +GPU    │
    └────┬─────┘    └────┬─────┘    └────┬─────┘
         │                │                │
         └────────────────┼────────────────┘
                          │
              ┌───────────▼───────────┐
              │  NIXL (KV Cache       │
              │   Data Transfer)      │
              │  RDMA/TCP/SSD         │
              └───────────────────────┘

Benefits:
- Built-in: Uses Kubernetes service discovery (no extra components)
- Fast: Direct TCP connections between components
- Reliable: Fewer moving parts to maintain
- Recommended for most deployments

Note: Workers require GPU nodes. Frontends don't require GPUs
      and can run on any node. The diagram shows them on separate
      nodes, but they can share nodes in smaller clusters.

**For NATS/etcd architecture (extreme scale deployments)**, see Appendix A.
```

### Key Concepts

**Kubernetes-native Discovery (v0.8.0+)**: Built-in service discovery:
- Uses EndpointSlices (standard Kubernetes API)
- Workers register with K8s API server automatically
- Frontends watch EndpointSlices for worker availability
- No additional infrastructure required

**TCP Transport (v0.8.0+ default)**: Direct worker communication:
- Frontends connect to workers via TCP
- Lower latency than pub/sub patterns
- Simpler debugging with standard networking tools

**NIXL (NVIDIA Inference Transfer Library)**: Handles actual KV cache data transfer:
- Uses high-speed transports (RDMA, TCP, or CPU/SSD offload)
- Transfers large tensor data between workers efficiently
- Direct worker-to-worker communication
- Works with both K8s-native and NATS/etcd modes

**KV-Aware Routing**: The Router knows which worker has which cache blocks:
- In K8s-native mode: Routing metadata shared via API or direct communication
- In NATS mode: NATS shares metadata about cache state
- Enables intelligent request routing to workers with relevant cached data
- Dramatically reduces prefill latency when cache hits occur

**Optional NATS/etcd (for extreme scale)**: Advanced coordination:
- **NATS**: Pub/sub messaging for metadata (cache events, routing tables)
- **etcd**: Distributed configuration and service discovery
- **When to use**: Very large clusters, multi-region, custom routing policies
- **Note**: NATS does NOT transfer KV cache data (NIXL does that)
- Router directs requests to workers with relevant cached prefixes
- Improves cache hit rates even on single node with multiple GPUs
- Workers transfer actual cache data via NIXL when needed

### Understanding Multi-GPU/Multi-Node Benefits

**In this lab (single node, 2 GPUs):**
- Each GPU runs a separate worker
- Router can direct requests to the worker with the best KV cache match
- NIXL can transfer cache data between workers on the same node

**In production (multi-node):**
- Scale workers across multiple nodes
- Scale frontends for high availability (multiple frontend replicas)
- NIXL transfers cache data between nodes over the network (RDMA/TCP)
- Kubernetes Services automatically load balance traffic across frontend replicas

### When to Use Distributed Dynamo

| Scenario | Use Distributed Dynamo? | Why |
|----------|-----------|-----|
| Single GPU | ❌ No | Adds overhead without benefit |
| Multiple GPUs, single node | ✅ Yes | KV-aware routing improves cache hits between GPU workers |
| 2-3 nodes | ✅ Yes | Cache awareness and coordination provide benefits |
| 4+ nodes | ✅ Strongly Yes | Significant performance improvements from distributed cache awareness |
| High traffic, repeated queries | ✅ Yes | Cache-aware routing reduces latency |
| Low traffic, unique queries | ⚠️ Maybe | Lower cache hit rates, but coordination still useful |
| Dynamo 0.8+ | ℹ️ Info | Can use K8s-native discovery (no NATS/etcd required) for simple deployments |

---

## Section 2: Environment Setup

### Overview

This lab uses **K8s-native deployment** - no NATS or etcd installation required. Dynamo uses Kubernetes EndpointSlices for service discovery and TCP for transport.

**For NATS/etcd deployment** (extreme scale only), see Appendix A after completing this lab.

### Step 1: Set Environment Variables

```bash
# Set environment variables (use defaults if not already set)
export RELEASE_VERSION=${RELEASE_VERSION:-0.8.0}
export NAMESPACE=${NAMESPACE:-dynamo}
export CACHE_PATH=${CACHE_PATH:-/data/huggingface-cache}

# Get node IP
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🌲 Lab 3: Distributed Dynamo Configuration"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Release Version:  $RELEASE_VERSION"
echo "  Namespace:        $NAMESPACE"
echo "  Node IP:          $NODE_IP"
echo ""
echo "✓ Environment configured for distributed Dynamo setup"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
```

---

## Pre-Deployment: Check GPU Availability

**⚠️ CRITICAL**: Lab 3 requires GPUs for distributed workers. Before proceeding, verify you have sufficient GPU resources available.

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

### Step 2: Clean Up Lab 1 Deployment (If Still Running)

**⚠️ WARNING**: If Lab 1 deployment is still running, you MUST delete it first to free GPUs for Lab 3.

Lab 3 deployment requires:
- **2 GPUs** for 2 distributed workers (1 GPU each)

If you have only 2 GPUs total and Lab 1 is using them, run this cleanup:

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

After cleaning up Lab 1 (if needed), verify GPUs are free:

```bash
echo "=== Final GPU Check ==="
kubectl get nodes -o custom-columns=NAME:.metadata.name,TOTAL:.status.capacity.nvidia\\.com/gpu,ALLOCATABLE:.status.allocatable.nvidia\\.com/gpu

echo ""
echo "If ALLOCATABLE shows 2 GPUs, you're ready for Lab 3!"
echo "If ALLOCATABLE shows 0, pods are still terminating - wait 30 seconds and re-run."
```

---

## Section 3: Deploy Distributed Dynamo Model

### Understanding Dynamo's Distributed Architecture

Dynamo (orchestrated by Grove) uses Kubernetes-native service discovery to coordinate distributed components. The deployment works as follows:

**1. Workers register with Kubernetes**: Each worker pod registers itself via K8s services
**2. Frontend discovers workers**: The frontend uses EndpointSlices to find available workers
**3. KV-aware Router**: Routes requests intelligently across workers
**4. NIXL handles KV cache data**: Workers transfer KV cache tensors directly via NIXL (RDMA/TCP)

**Note**: For extreme scale deployments, NATS/etcd can be added for advanced coordination (see Appendix A & B).

### Step 1: Create Distributed Dynamo Deployment

We'll create a deployment with 2 workers to demonstrate distributed architecture and KV-aware routing:

**Configuration Notes:**
- **Data Parallelism**: `replicas: 2` with `tensor-parallel-size: 1` creates 2 independent workers that share KV cache via NIXL
- **Not Tensor Parallelism**: Each worker loads the full model on 1 GPU (not splitting 1 model across 2 GPUs)
- **K8s-Native Discovery**: Workers register via Kubernetes EndpointSlices (v0.8.0+)

```bash
# Create distributed Dynamo deployment
echo "Creating distributed Dynamo deployment with 2 workers..."

cat <<'EOF' | kubectl apply -f -
apiVersion: nvidia.com/v1alpha1
kind: DynamoGraphDeployment
metadata:
  name: vllm-distributed-demo
  namespace: dynamo
spec:
  services:
    Frontend:
      dynamoNamespace: vllm-distributed-demo
      componentType: frontend
      replicas: 1
      extraPodSpec:
        mainContainer:
          image: nvcr.io/nvidia/ai-dynamo/vllm-runtime:0.8.0
    VllmWorker:
      envFromSecret: hf-token-secret
      dynamoNamespace: vllm-distributed-demo
      componentType: worker
      replicas: 2
      resources:
        limits:
          gpu: "1"
      envs:
        - name: DYN_LOG
          value: info
      extraPodSpec:
        volumes:
        - name: local-model-cache
          hostPath:
            path: /data/huggingface-cache
            type: DirectoryOrCreate
        mainContainer:
          image: nvcr.io/nvidia/ai-dynamo/vllm-runtime:0.8.0
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
            - python3 -m dynamo.vllm --model Qwen/Qwen2.5-1.5B-Instruct --tensor-parallel-size 1
EOF

echo ""
echo "✓ Distributed Dynamo deployment created"
echo "  Deployment: vllm-distributed-demo"
echo "  Workers: 2 (data parallelism with KV cache sharing via NIXL)"
```

### Step 2: Create NodePort Service

Expose the frontend for testing:

```bash
# Create NodePort service
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: vllm-distributed-demo-frontend-np
  namespace: dynamo
spec:
  type: NodePort
  selector:
    nvidia.com/dynamo-component: Frontend
    nvidia.com/dynamo-graph-deployment-name: vllm-distributed-demo
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
echo "Waiting for distributed Dynamo deployment..."
echo "This may take 2-3 minutes for model download and initialization..."
echo ""

NAMESPACE=${NAMESPACE:-dynamo}

# Wait for pods to be ready
kubectl wait --for=condition=ready --timeout=300s \
  pods -l nvidia.com/dynamo-graph-deployment-name=vllm-distributed-demo \
  -n $NAMESPACE 2>/dev/null || echo "Pods are initializing..."

echo ""
echo "Deployment status:"
kubectl get pods -n $NAMESPACE -l nvidia.com/dynamo-graph-deployment-name=vllm-distributed-demo

echo ""
echo "✓ Distributed Dynamo deployment ready"
```

### Step 4: Test Inference

```bash
# Test the deployment
echo "Testing inference..."
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

curl -s http://$NODE_IP:30200/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen2.5-1.5B-Instruct",
    "messages": [{"role": "user", "content": "Explain distributed inference in one sentence"}],
    "max_tokens": 50
  }' | python3 -m json.tool

echo ""
echo "✓ Distributed Dynamo deployment is serving requests"
echo "  Multiple workers coordinated via K8s-native discovery"
echo "  NIXL handles KV cache data transfer between workers"
```

---

## Section 4: Monitoring Distributed Components

### Step 1: Access Dynamo Metrics in Grafana

Monitor your distributed Dynamo deployment using Grafana:

```bash
# Get Grafana URL
BREV_ID=$(hostname | cut -d'-' -f2)
GRAFANA_URL="https://grafana0-${BREV_ID}.brevlab.com/"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 Distributed Dynamo Monitoring"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Grafana URL: $GRAFANA_URL"
echo ""
echo "  Dashboard: Dynamo Inference Metrics"
echo "    • Request rates across multiple workers"
echo "    • Time to First Token (TTFT) distribution"
echo "    • Inter-Token Latency (ITL) per worker"
echo "    • Worker utilization and queue depths"
echo ""
echo "🔗 Open Grafana and search for 'Dynamo Inference'"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
```

### Step 2: Test Distributed Dynamo with Traffic

Generate meaningful traffic to see distributed coordination in action:

```bash
# Generate test traffic with concurrent requests
echo "Generating traffic to distributed Dynamo deployment..."
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

# Function to send a request
send_request() {
    local id=$1
    curl -s http://$NODE_IP:30200/v1/chat/completions \
      -H "Content-Type: application/json" \
      -d "{
        \"model\": \"Qwen/Qwen2.5-1.5B-Instruct\",
        \"messages\": [{\"role\": \"user\", \"content\": \"Explain distributed systems in 2 sentences. Request $id\"}],
        \"stream\": false,
        \"max_tokens\": 100
      }" > /dev/null 2>&1
}

# Send 30 requests with 3 concurrent workers
echo "Sending 30 requests with 3 concurrent connections..."
echo "This will generate metrics for:"
echo "  - Request throughput across multiple workers"
echo "  - Worker utilization and load balancing"
echo "  - KV cache effectiveness and NIXL transfers"
echo ""

for i in {1..10}; do
    send_request $((i*3-2)) &
    send_request $((i*3-1)) &
    send_request $((i*3)) &
    wait
    echo "Batch $i/10 complete (requests $((i*3-2))-$((i*3)))"
    sleep 0.5
done

echo ""
echo "✓ Sent 30 requests with concurrent load"
echo ""
echo "Check metrics in Grafana:"
echo "  - Dynamo Inference Dashboard"
echo "  - Request throughput, TTFT, ITL across workers"
echo "  - Worker queue depths and GPU utilization"
echo ""
echo "View Grafana: https://grafana0-$(hostname | sed 's/^brev-//').brevlab.com/"
```

---

## Section 5: Understanding Distributed Dynamo Trade-offs

### K8s-Native vs NATS/etcd Comparison (v0.8.0+)

| Aspect | K8s-Native | NATS/etcd |
|--------|------------|-----------|
| **Setup Complexity** | ✅ Simple (no extra infra) | ⚠️ Complex (2 systems to manage) |
| **Latency** | ✅ Lower (direct TCP) | ⚠️ Slightly higher (pub/sub) |
| **Scale Sweet Spot** | Most deployments | Extreme scale |
| **Discovery** | EndpointSlices (built-in) | etcd (external) |
| **Transport** | TCP | NATS + TCP |
| **Ops Burden** | ✅ Low | ⚠️ Medium-High |
| **Multi-Region** | ⚠️ Limited | ✅ Excellent |
| **Custom Routing** | ⚠️ Basic | ✅ Advanced |
| **Cache Coordination** | ✅ Yes (via planner) | ✅ Yes (via NATS) |
| **NIXL Support** | ✅ Yes | ✅ Yes |

**Recommendation:** Start with K8s-native. Only add NATS/etcd if you need extreme scale or multi-region capabilities.

### Single-Node vs Multi-Node

**Single Node with Multiple GPUs (Typical Dev Setup)**:
```
✓ KV-aware routing still beneficial (routes to worker with cached data)
✓ Learning opportunity to understand architecture
✓ Workers can share cache blocks via NIXL locally
✓ K8s-native = simpler (no NATS/etcd overhead)
✗ Less dramatic network benefits (same machine)
```

**Multi-Node (Production)**:
```
✓ KV-aware Router directs requests to nodes with relevant cache
✓ NIXL transfers cache data efficiently (RDMA/TCP between nodes)
✓ Improved cache hit rates = lower latency
✓ Better resource utilization across cluster
✓ K8s-native recommended for most deployments
✓ NATS/etcd for extreme scale or multi-region
```
✓ Enables advanced features (cache migration, load balancing)
✗ Network latency between nodes
✗ Increased complexity in debugging
```

### Performance Characteristics

```bash
# Display performance comparison
cat <<'EOF'

Performance Impact of Distributed Dynamo:

┌─────────────────────┬──────────────────┬──────────────┐
│ Metric              │ Single Node      │ Multi-Node   │
│                     │ (Multi-GPU)      │              │
├─────────────────────┼──────────────────┼──────────────┤
│ Cache Hit Rate      │ +10-20%          │ +20-40%      │
│ Latency (P50)       │ +2-5ms           │ +2-5ms       │
│ Latency (P99)       │ +5-10ms          │ +5-10ms      │
│ Throughput          │ Same to +10%     │ +30-60%      │
│ Memory Overhead     │ +100-200MB       │ +100-200MB   │
└─────────────────────┴──────────────────┴──────────────┘

When Distributed Dynamo Helps Most:
  • Multiple GPUs or nodes with high traffic
  • Repeated queries (high cache hit potential)
  • Long context lengths (expensive to recompute)
  • Batch processing workloads

When It May Not Help:
  • Single GPU deployments
  • Unique queries every time (low cache hit rate)
  • Very short context lengths
  • Real-time streaming with completely unique prompts

Architecture Notes:
  • Grove = Kubernetes Operator (orchestration)
  • Dynamo = Serving Framework (actual inference)
  • NATS = Metadata/coordination (small messages)
  • NIXL = KV cache data transfer (large tensors via RDMA/TCP)
EOF
```

---

## Section 6: Advanced Distributed Features

### Cache Monitoring

Check distributed coordination through worker logs:

```bash
# Get cache stats from worker logs
NAMESPACE=${NAMESPACE:-dynamo}

WORKER_POD=$(kubectl get pods -n $NAMESPACE -l nvidia.com/dynamo-component=VllmWorker,nvidia.com/dynamo-graph-deployment-name=vllm-distributed-demo -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -n "$WORKER_POD" ]; then
    echo "Checking NIXL/NATS activity in worker logs..."
    echo ""
    kubectl logs -n $NAMESPACE $WORKER_POD --tail=100 | grep -i "nixl\|nats" | tail -10
    
    echo ""
    echo "Worker pod: $WORKER_POD"
    echo ""
    echo "What to look for:"
    echo "  - NIXL initialization messages (KV cache transfer setup)"
    echo "  - NATS connection status (coordination layer)"
    echo "  - KV cache registration events"
    echo "  - UCX backend messages (if using RDMA for cache transfer)"
else
    echo "⚠️ No worker pods found"
    echo "Make sure the vllm-distributed-demo deployment is running"
fi
```

**Note**: Cache hit/miss metrics depend on workload patterns. Even on a single node with multiple GPUs, KV-aware routing can improve cache hits by directing requests to the worker that already has relevant cache blocks.

### NATS Health Check

Verify NATS is functioning correctly:

```bash
# Check NATS service health
echo "Checking NATS health..."
kubectl exec -n nats-system nats-0 -- nats-server --version 2>/dev/null || kubectl get pods -n nats-system

echo ""
echo "NATS endpoints:"
kubectl get svc -n nats-system
```

### etcd Health Check

Verify etcd cluster health:

```bash
# Check etcd health
echo "Checking etcd health..."
ETCD_POD=$(kubectl get pods -n etcd-system -l app.kubernetes.io/name=etcd -o jsonpath='{.items[0].metadata.name}')

if [ -n "$ETCD_POD" ]; then
    kubectl exec -n etcd-system $ETCD_POD -- etcdctl endpoint health 2>/dev/null || echo "etcd health check requires auth setup"
    echo ""
    kubectl exec -n etcd-system $ETCD_POD -- etcdctl member list 2>/dev/null || echo "etcd member list requires auth setup"
else
    echo "⚠️ No etcd pods found"
fi

echo ""
echo "etcd endpoints:"
kubectl get svc -n etcd-system
```

---

## Section 7: Cleanup

### Step 1: Remove Distributed Demo Deployment

```bash
# Delete the distributed deployment
echo "Removing distributed Dynamo deployment..."
NAMESPACE=${NAMESPACE:-dynamo}

kubectl delete dynamographdeployment vllm-distributed-demo -n $NAMESPACE
kubectl delete svc vllm-distributed-demo-frontend-np -n $NAMESPACE

echo "✓ Distributed deployment removed"
```

### Step 2: Verify Lab 1 Deployment is Still Running

Your original Lab 1 deployment should still be running on port 30100:

```bash
# Check Lab 1 deployment status
NAMESPACE=${NAMESPACE:-dynamo}
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

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

## Known Issues (v0.8.0 Distributed Serving)

**⚠️ Distributed Deployment Issues:**

1. **K8s-native Discovery Propagation**: EndpointSlices may take 5-15 seconds to propagate in large clusters (20+ nodes). First requests may fail with "no available workers" until discovery completes.

2. **NIXL KV Cache Transfer on ARM**: RDMA support on ARM-based nodes (Graviton, Ampere) is experimental in v0.8.0. Fall back to TCP transport if encountering issues.

3. **Multi-Frontend KV-Aware Routing**: In some edge cases with >10 frontend replicas, routing metadata may be stale for 1-2 seconds, resulting in suboptimal cache hits (not failures, just less efficient).

4. **NATS/etcd Compatibility**: If mixing K8s-native and NATS/etcd modes in the same cluster, ensure workers use consistent discovery method. Mixed modes are not supported.

5. **Worker Gang Scheduling**: In v0.8.0, workers must all be ready before accepting traffic. If one worker pod fails, the entire deployment may be blocked. Use `kubectl describe dynamographdeployment` to debug.

**Workarounds:**
- Discovery delays: Add `--wait-for-workers-timeout=30s` flag to frontend
- NIXL issues: Set `NIXL_TRANSPORT=tcp` env var to force TCP mode
- Routing staleness: Reduce frontend replicas to 3-5 for optimal cache awareness
- Gang scheduling: Use pod disruption budgets and ensure adequate node resources

**Migration from v0.7.x:**
- K8s-native discovery is backward compatible
- Existing NATS/etcd deployments continue to work
- Can upgrade in-place, but test K8s-native in staging first

---

## Summary

### What You Learned

- ✅ Distributed Dynamo architecture with K8s-native discovery
- ✅ Difference between Grove (operator) and Dynamo (serving framework)
- ✅ Deploying distributed Dynamo with multiple workers
- ✅ Creating a distributed deployment with KV-aware routing
- ✅ Monitoring distributed Dynamo metrics with Grafana
- ✅ Understanding NIXL for KV cache data transfer between workers
- ✅ Trade-offs between single-node and multi-node setups
- ✅ When to consider NATS/etcd for extreme scale (Appendix A & B)

### Key Takeaways

**Architecture Clarity**:
- **Grove**: Kubernetes Operator (orchestrates Dynamo deployments)
- **Dynamo**: Inference serving framework (does the actual work)
- **K8s-native Discovery**: EndpointSlices for worker discovery (v0.8.0+)
- **NIXL**: Transfers actual KV cache data (gigabytes via RDMA/TCP/SSD)

**Distributed Dynamo is Powerful**:
- Enables KV-aware routing (even on single node with multiple GPUs)
- NIXL transfers cache data efficiently between workers
- Improves cache hit rates and throughput
- Essential for production scale-out scenarios

**Benefits of K8s-Native (v0.8.0+)**:
- Simpler deployment (no NATS/etcd required)
- Lower latency (direct TCP connections)
- Fewer moving parts to maintain
- Built-in Kubernetes service discovery

**Production Considerations**:
- Use distributed Dynamo when scaling beyond single GPU
- Monitor worker metrics for health and utilization
- Plan for network latency between nodes in multi-node setups
- Consider cache hit patterns for your workload
- NATS/etcd optional for extreme scale (see Appendix A)

### Real-World Applications

**When Companies Use Distributed Dynamo**:
- Multi-region LLM deployments
- High-traffic serving (1000+ RPS)
- Multi-GPU and multi-node clusters
- Cost optimization (share expensive cache computation)
- Enterprise multi-tenant platforms

**Deployment Options**:
- **Single GPU**: No distributed coordination needed
- **Multiple GPUs, single node**: Distributed Dynamo with KV-aware routing beneficial
- **Small clusters**: K8s-native discovery (simple, effective)
- **Large clusters**: K8s-native for most; NATS/etcd for extreme scale

### Next Steps

- **Experiment**: Try different worker replica counts to see KV-aware routing
- **Monitor**: Watch Dynamo metrics dashboards during traffic
- **Scale**: If you have access to multi-node clusters, test distributed benefits
- **Learn**: Understand NIXL for KV cache data transfer in Dynamo docs
- **Explore**: Review Appendix A & B if you need NATS/etcd for extreme scale

---

## Troubleshooting

### Deployment Not Starting

```bash
# Check deployment status
NAMESPACE=${NAMESPACE:-dynamo}
kubectl describe dynamographdeployment vllm-distributed-demo -n $NAMESPACE

# Check pod status
kubectl get pods -n $NAMESPACE -l nvidia.com/dynamo-graph-deployment-name=vllm-distributed-demo

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
NAMESPACE=${NAMESPACE:-dynamo}
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
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
curl -v http://$NODE_IP:30200/v1/models

# Check frontend logs
kubectl logs -n $NAMESPACE -l nvidia.com/dynamo-component=Frontend

# Verify NodePort service exists
kubectl get svc vllm-distributed-demo-frontend-np -n $NAMESPACE

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

**For NATS/etcd troubleshooting**, see Appendix B

---

## Appendix A: NATS/etcd Architecture (Optional - Extreme Scale)

This appendix covers the NATS/etcd deployment architecture for extreme scale deployments or multi-region setups. **Most users should use K8s-native deployment** (covered in the main lab).

### When You Need NATS/etcd

Consider NATS/etcd if you have:
- Very large Kubernetes clusters (extreme scale)
- Multi-region deployments
- Complex custom routing logic
- Advanced cache policies and coordination requirements

### NATS/etcd Architecture Diagram

```
               ┌────────────────────────────┐
               │  Cloud Load Balancer       │
               │  or Ingress Controller     │
               └──────────┬─────────────────┘
                          │
         ┌────────────────┼────────────────┐
         │                │                │
    ┌────▼─────┐    ┌────▼─────┐    ┌────▼─────┐
    │Frontend 1│    │Frontend 2│    │Frontend 3│
    │ (Node 1) │    │ (Node 2) │    │ (Node 3) │
    └────┬─────┘    └────┬─────┘    └────┬─────┘
         │                │                │
         └────────────────┼────────────────┘
                          │
              ┌───────────▼───────────┐
              │  NATS Message Bus     │
              │  (Metadata, Routing,  │
              │   Cache Awareness)    │
              └───────────┬───────────┘
                          │
              ┌───────────▼───────────┐
              │  etcd (Coordination)  │
              │  (Service Discovery)  │
              └───────────┬───────────┘
                          │
         ┌────────────────┼────────────────┐
         │                │                │
    ┌────▼─────┐    ┌────▼─────┐    ┌────▼─────┐
    │ Worker 1 │    │ Worker 2 │    │ Worker 3 │
    │ (Node 4) │    │ (Node 5) │    │ (Node 6) │
    │  +GPU    │    │  +GPU    │    │  +GPU    │
    └────┬─────┘    └────┬─────┘    └────┬─────┘
         │                │                │
         └────────────────┼────────────────┘
                          │
              ┌───────────▼───────────┐
              │  NIXL (KV Cache       │
              │   Data Transfer)      │
              │  RDMA/TCP/SSD         │
              └───────────────────────┘
```

### Components

**NATS Message Bus:**
- Pub/sub messaging for metadata (cache events, routing tables)
- Low-latency coordination between frontends and workers
- Does NOT transfer KV cache data (NIXL handles that)

**etcd:**
- Distributed configuration and service discovery
- Leader election and coordination
- Cluster state management

**NIXL:**
- Handles actual KV cache data transfer (same as K8s-native mode)
- Uses RDMA/TCP for high-speed transfer
- Direct worker-to-worker communication

### Deployment Steps (Optional)

If you need to deploy NATS/etcd, refer to Section 2a in the main lab (marked as "Optional - Skip for K8s-Native"). The steps are preserved but skipped in the standard lab flow.

### Trade-offs vs K8s-Native

| Aspect | K8s-Native | NATS/etcd |
|--------|------------|-----------|
| Setup Complexity | Simple | Complex |
| Ops Burden | Low | Medium-High |
| Max Scale | Standard clusters | Extreme scale |
| Multi-Region | Limited | Excellent |
| Custom Routing | Basic | Advanced |

---

## Appendix B: NATS/etcd Deployment Steps (Optional)

**⚠️ WARNING:** These steps are ONLY for users deploying NATS/etcd for extreme-scale scenarios. Most users should skip this appendix and use K8s-native deployment (covered in the main lab).

### When to Use These Steps

Deploy NATS/etcd only if you have:
- Very large Kubernetes clusters (extreme scale)
- Multi-region deployments
- Complex custom routing requirements
- Advanced cache coordination policies

### Prerequisites

- Complete Section 2 Step 1 (Environment Setup)
- Have cluster-admin access for cluster-wide resources

### Step 1: Install NATS Message Bus

NATS handles distributed coordination metadata between Dynamo components:

```bash
# Create namespace for NATS
kubectl create namespace nats-system --dry-run=client -o yaml | kubectl apply -f -

# Add NATS Helm repository
echo "Adding NATS Helm repository..."
helm repo add nats https://nats-io.github.io/k8s/helm/charts/
helm repo update

# Install NATS (with Prometheus exporter)
echo "Installing NATS with metrics exporter..."
helm upgrade --install nats nats/nats \
  --namespace nats-system \
  --set config.jetstream.enabled=true \
  --set config.jetstream.fileStore.pvc.size=1Gi \
  --set promExporter.enabled=true \
  --set promExporter.port=7777 \
  --wait \
  --timeout 5m

echo ""
echo "✓ NATS installed successfully"
echo "  Connection: nats://nats.nats-system:4222"
echo "  Metrics: Port 7777"
echo ""
echo "Note: NATS handles metadata (cache events, routing tables)."
echo "      Actual KV cache data transfers via NIXL (RDMA/TCP)."
```

### Step 2: Install etcd Coordination Layer

etcd provides distributed coordination for Grove components:

```bash
# Create namespace for etcd
kubectl create namespace etcd-system --dry-run=client -o yaml | kubectl apply -f -

# Add Bitnami Helm repository
echo "Adding Bitnami Helm repository..."
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update

# Install etcd (using legacy Bitnami mirror)
echo "Installing etcd..."
helm upgrade --install etcd bitnami/etcd \
  --namespace etcd-system \
  --set replicaCount=1 \
  --set auth.rbac.create=false \
  --set image.registry=docker.io \
  --set image.repository=bitnamilegacy/etcd \
  --set persistence.size=1Gi \
  --set preUpgradeHook.enabled=false \
  --wait \
  --timeout 5m

echo ""
echo "✓ etcd installed successfully"
```

### Step 3: Verify Infrastructure

Check that NATS and etcd are running:

```bash
# Check NATS pods
echo "Checking NATS deployment..."
kubectl get pods -n nats-system

echo ""
echo "Checking NATS service..."
kubectl get svc -n nats-system

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Check etcd pods
echo "Checking etcd deployment..."
kubectl get pods -n etcd-system

echo ""
echo "Checking etcd service..."
kubectl get svc -n etcd-system

echo ""
echo "✓ Infrastructure verified"
echo "  NATS:  nats://nats.nats-system:4222 (metadata/coordination)"
echo "  etcd:  http://etcd.etcd-system:2379 (service discovery)"
echo "  NIXL will handle KV cache data transfer between workers"
```

### Step 4: Enable Prometheus Monitoring (Optional)

Create PodMonitors so Prometheus can scrape NATS and etcd metrics:

```bash
# Create PodMonitor for NATS
echo "Enabling NATS metrics collection..."
cat <<'EOF' | kubectl apply -f -
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: nats
  namespace: nats-system
  labels:
    release: kube-prometheus-stack
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: nats
  podMetricsEndpoints:
  - port: prom-metrics
    path: /metrics
EOF

# Create PodMonitor for etcd
echo "Enabling etcd metrics collection..."
cat <<'EOF' | kubectl apply -f -
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: etcd
  namespace: etcd-system
  labels:
    release: kube-prometheus-stack
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: etcd
  podMetricsEndpoints:
  - port: client
    path: /metrics
EOF

echo ""
echo "✓ Prometheus monitoring enabled"
echo "  Metrics will be available in Grafana within 2-3 minutes"
```

### Cleanup (NATS/etcd)

When you're done with NATS/etcd:

```bash
# Remove NATS
echo "Removing NATS..."
helm uninstall nats -n nats-system
kubectl delete namespace nats-system

# Remove etcd  
echo "Removing etcd..."
helm uninstall etcd -n etcd-system
kubectl delete namespace etcd-system

# Remove PodMonitors
kubectl delete podmonitor nats -n nats-system 2>/dev/null || true
kubectl delete podmonitor etcd -n etcd-system 2>/dev/null || true

echo ""
echo "✓ Infrastructure removed"
```

### Configuring Dynamo to Use NATS/etcd

After installing NATS/etcd, you need to configure your `DynamoGraphDeployment` to use them. Add these annotations to your deployment spec:

```yaml
metadata:
  annotations:
    dynamo.nvidia.com/discovery-backend: "nats"  # Use NATS/etcd instead of K8s-native
    dynamo.nvidia.com/nats-url: "nats://nats.nats-system:4222"
    dynamo.nvidia.com/etcd-url: "http://etcd.etcd-system:2379"
```

Refer to Dynamo documentation for complete configuration options.

---

## Additional Resources

### Core Documentation

- **NVIDIA Dynamo Documentation**: https://docs.nvidia.com/dynamo/latest/
- **Dynamo Deployment Guide**: https://docs.nvidia.com/dynamo/latest/kubernetes/deployment/
- **Grove Operator Guide**: https://docs.nvidia.com/dynamo/latest/kubernetes/grove.html
- **Dynamo v0.8.0 Release Notes**: https://github.com/ai-dynamo/dynamo/releases/tag/v0.8.0

### Advanced Topics (NATS/etcd - Optional)

- **NATS Documentation**: https://docs.nats.io/
- **etcd Documentation**: https://etcd.io/docs/

### Community Resources

- **Dynamo GitHub**: https://github.com/ai-dynamo/dynamo
- **NVIDIA Developer Forums**: https://forums.developer.nvidia.com/

---

**Congratulations! You've completed Lab 3: Distributed Dynamo with Grove Orchestration** 🌲

You now understand the fundamentals of distributed LLM serving, the difference between Grove (operator) and Dynamo (serving framework), and how K8s-native discovery enables distributed coordination!
