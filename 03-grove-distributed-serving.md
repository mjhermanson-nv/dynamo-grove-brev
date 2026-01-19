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
- **Primary Path:** Deploy distributed Dynamo using K8s-native discovery (simplified, v0.8.0)
- Understand multi-GPU and multi-node serving architectures
- Enable distributed KV cache awareness and transfer via NIXL
- Monitor distributed components with Grafana
- **Optional Advanced:** Deploy with NATS/etcd for extreme scale (multi-region, 100+ nodes)

**Prerequisites**: Complete Lab 1 (Dynamo Deployment) and Lab 2 (Monitoring)

**What's New in v0.8.0:**
- ✅ K8s-native discovery (EndpointSlices) - no etcd needed
- ✅ TCP transport - no NATS needed
- ✅ Simpler deployment for 2-50 node clusters
- ✅ NATS/etcd now optional for extreme scale only

**Note**: Distributed Dynamo is designed for multi-node Kubernetes clusters or single nodes with multiple GPUs. While we'll deploy it on a single node for learning purposes, maximum benefits are realized when scaling across multiple nodes with high cache hit workloads.

## Duration: ~45 minutes (K8s-native path) / ~75 minutes (with optional NATS/etcd)

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
  - **NATS/etcd (optional)**: For extreme scale (100+ nodes, multi-region, complex topologies)

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
- Simpler: No additional infrastructure (NATS/etcd)
- Lower latency: Direct TCP connections
- Easier ops: Fewer moving parts
- Sufficient for 2-50 node clusters

Note: Workers typically run on GPU nodes (4-6), separate from
      CPU-only frontend nodes (1-3). In smaller clusters, they
      may share nodes with frontends.
```

### Architecture: NATS/etcd (Optional - For Extreme Scale)

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

When to use NATS/etcd:
- 100+ node clusters
- Multi-region deployments
- Complex custom routing logic
- Advanced cache policies
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
- Transfers gigabytes of tensor data between workers
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
- **When to use**: 100+ nodes, multi-region, custom routing policies
- **Note**: NATS does NOT transfer KV cache data (NIXL does that)
- Router directs requests to workers with relevant cached prefixes
- Improves cache hit rates even on single node with multiple GPUs
- Workers transfer actual cache data via NIXL when needed

### How Multiple Frontends Work

The architecture diagram shows 2 frontends, but **frontend replicas ≠ one per node**. Here's how it actually works in production:

**Frontend Scaling Strategy**:
```
Small cluster (3 nodes):    2-3 frontend replicas
Medium cluster (10 nodes):  3-5 frontend replicas
Large cluster (50+ nodes):  5-10 frontend replicas
```

**Load Balancing via Kubernetes Service**:

When you create a Service (NodePort or LoadBalancer), Kubernetes automatically load balances across all frontend pods:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: frontend-service
spec:
  type: LoadBalancer  # or NodePort
  selector:
    component: frontend  # Selects ALL frontend pods
  ports:
  - port: 8000
```

**How Traffic Flows**:
1. **External Load Balancer** (cloud provider or Ingress) receives request
2. **Kubernetes Service** load balances to any frontend pod
3. **Frontend** sends inference request via NATS
4. **NATS** routes to an available worker (KV-aware routing if enabled)
5. **Worker** may receive KV cache data from another worker via NIXL
6. **Worker** responds via NATS
7. **Frontend** returns HTTP response

**Key Benefits**:
- ✅ **High Availability**: If one frontend crashes, others continue
- ✅ **Load Distribution**: Spread HTTP connections across pods
- ✅ **Dynamic Discovery**: NATS decouples frontends from workers (Dynamo 0.7.x requires NATS/etcd; 0.8+ supports K8s-native discovery)
- ✅ **Flexible Scaling**: Add/remove frontends independently
- ✅ **KV-Aware Routing**: Route requests to workers with relevant cached data

**Single Node (This Lab)**:
Even in a single-node setup with multiple GPUs/workers, KV-aware routing provides benefits! The Router uses NATS to track which worker has which cached prefixes, directing requests to the worker with the best cache hit potential.

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

## Section 2: Deploy Distributed Dynamo (K8s-Native)

### ⚠️ IMPORTANT: Choose Your Deployment Mode

**For v0.8.0, we recommend K8s-native mode (simpler, no extra infrastructure):**
- **K8s-Native Path**: Skip Steps 2-4 below and go directly to Section 3
- **NATS/etcd Path** (100+ nodes only): Continue with Steps 2-4

### Overview

**K8s-Native Mode (Recommended)**:
- No NATS or etcd installation required
- Uses Kubernetes EndpointSlices for discovery
- TCP transport (default)
- Sufficient for 2-50 node clusters

**NATS/etcd Mode (Optional Advanced)**:
- Requires Steps 2-4 below
- For 100+ nodes, multi-region, custom routing
- See release notes for configuration details

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

### Step 2: Install NATS Message Bus

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

### Step 3: Install etcd Coordination Layer

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

### Step 4: Verify Grove Infrastructure

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
echo "✓ Grove infrastructure verified"
echo "  NATS:  nats://nats.nats-system:4222 (metadata/coordination)"
echo "  etcd:  http://etcd.etcd-system:2379 (service discovery)"
echo "  NIXL will handle KV cache data transfer between workers"
```

### Step 4: Enable Prometheus Monitoring

Create PodMonitors so Prometheus can scrape NATS and etcd metrics:

```bash
# Create PodMonitor for NATS (scrapes the prometheus-nats-exporter sidecar)
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
echo "✓ Prometheus monitoring enabled for distributed infrastructure"
echo "  Metrics will be available in Grafana within 2-3 minutes"
echo ""
echo "  NATS metrics: Scraped from prometheus-nats-exporter (port: prom-metrics)"
echo "  etcd metrics: Scraped directly from etcd's /metrics endpoint (port: client)"
echo ""
echo "Note: etcd metrics typically appear faster than NATS metrics"
echo "      NATS metrics show coordination traffic, not KV cache data volume"
```

---

## Section 3: Deploy Distributed Dynamo Model

### Understanding Dynamo's Distributed Architecture

Dynamo (orchestrated by Grove) automatically uses NATS and etcd for distributed coordination when they are available in the cluster. The deployment will:

**1. Workers register via NATS**: Each worker announces itself and its cache state
**2. Frontend discovers workers**: The frontend finds workers through NATS service discovery
**3. KV-aware Router**: Routes requests to workers with relevant cached data
**4. NIXL handles KV cache data**: Workers transfer actual KV cache tensors via NIXL (RDMA/TCP), not through NATS

**Note**: In Dynamo 0.8+, Kubernetes-native discovery (EndpointSlices) is available as an alternative to NATS/etcd for simpler deployments without KV-aware routing.

### Step 1: Create Distributed Dynamo Deployment

We'll create a deployment with 2 workers to demonstrate distributed architecture and KV-aware routing:

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
          image: nvcr.io/nvidia/ai-dynamo/vllm-runtime:0.7.1
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
          image: nvcr.io/nvidia/ai-dynamo/vllm-runtime:0.7.1
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
echo "  Workers: 2 (will use NATS for coordination and NIXL for cache transfer)"
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
echo "  Router uses NATS for worker coordination"
echo "  NIXL handles KV cache data transfer between workers"
```

### Step 5: Verify NATS and NIXL Integration

```bash
# Check worker logs for NATS connectivity and NIXL initialization
echo "Verifying NATS and NIXL integration..."
NAMESPACE=${NAMESPACE:-dynamo}

WORKER_POD=$(kubectl get pods -n $NAMESPACE -l nvidia.com/dynamo-component=VllmWorker,nvidia.com/dynamo-graph-deployment-name=vllm-distributed-demo -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -n "$WORKER_POD" ]; then
    echo "Checking worker: $WORKER_POD"
    kubectl logs -n $NAMESPACE $WORKER_POD 2>&1 | grep -i "nats\|nixl" | head -5
    
    echo ""
    echo "✓ Workers are using:"
    echo "  • NATS for coordination and cache awareness"
    echo "  • NIXL for KV cache data transfer (RDMA/TCP/SSD)"
    echo ""
    echo "Note: NATS carries metadata (cache events, routing tables)."
    echo "      NIXL transfers the actual tensor data between workers."
else
    echo "⚠️ No worker pods found. Make sure the deployment is running:"
    kubectl get pods -n $NAMESPACE -l nvidia.com/dynamo-graph-deployment-name=vllm-distributed-demo
fi
```

---

## Section 4: Monitoring Distributed Components

### Step 1: Access Grafana Dashboards

The distributed infrastructure dashboards were created during the oneshot.sh bootstrap:

```bash
# Get Grafana URL
BREV_ID=$(hostname | cut -d'-' -f2)
GRAFANA_URL="https://grafana0-${BREV_ID}.brevlab.com/"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 Distributed Dynamo Monitoring Dashboards"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Grafana URL: $GRAFANA_URL"
echo ""
echo "  Available Dashboards:"
echo "    • NATS Overview - Message bus metrics (metadata/coordination)"
echo "    • etcd Overview - Service discovery metrics"
echo "    • Dynamo Inference Metrics - Model serving metrics"
echo ""
echo "🔗 Open Grafana and search for these dashboards"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
```

### Step 2: Understanding NATS Metrics

The NATS Overview dashboard shows real-time metrics about the message bus that Dynamo uses for distributed coordination metadata (not KV cache data).

#### Connection Metrics (Top Left Panel)

**`nats_varz_connections`** - Current active connections to NATS
- **What it shows**: Number of Dynamo components connected to NATS
- **Expected value**: 
  - With distributed deployment running: 2-4 connections (workers + frontend)
  - Without active deployment: 0
- **Why it matters**: Each Dynamo component (frontend, workers) maintains a connection to NATS for coordination

#### Message Rate Metrics (Top Center Panels)

**`rate(nats_varz_in_msgs[1m])`** - Incoming messages per second
- **What it shows**: Coordination messages NATS is receiving (cache events, routing metadata)
- **Expected value**: 
  - Idle: Low (< 1 msg/s for heartbeats)
  - During load: 10-100+ msg/s depending on request rate
- **Why it matters**: Shows the coordination throughput (NOT KV cache data volume)
- **Important**: NATS messages are small metadata packets, not gigabytes of tensor data

**`rate(nats_varz_out_msgs[1m])`** - Outgoing messages per second
- **What it shows**: How many coordination messages NATS is distributing
- **Expected value**: Similar to or slightly higher than incoming rate
- **Why it matters**: NATS may send multiple copies of messages to subscribers (pub/sub pattern)

#### Resource Metrics (Top Right Panel)

**`nats_varz_cpu`** - NATS CPU usage percentage
- **What it shows**: CPU usage of the NATS process
- **Expected value**: 
  - Idle: < 1%
  - Under load: 5-20%
  - High load: > 50% (consider scaling)
- **Why it matters**: High CPU might indicate NATS is becoming a bottleneck

#### Message Rate Graph (Middle Panel)

**Time series visualization** of message rates
- **Green line**: Incoming messages (rate(nats_varz_in_msgs[1m]))
- **Blue line**: Outgoing messages (rate(nats_varz_out_msgs[1m]))
- **What to look for**:
  - Spikes during traffic bursts
  - Correlation between in/out rates
  - Steady state during constant load
  - Drops to zero when idle

#### Memory Usage (Bottom Left Panel)

**`nats_varz_mem`** - NATS memory consumption in MB
- **What it shows**: RAM used by the NATS process
- **Expected value**: 
  - Base: 20-50 MB
  - With JetStream: 50-200 MB
  - Under load: May increase with buffered messages
- **Why it matters**: Monitors memory leaks or excessive buffering

#### NATS Statistics (Bottom Right Panel)

**`nats_varz_subscriptions`** - Active subscriptions
- **What it shows**: Number of topics/subjects that components are subscribed to
- **Expected value**: 5-20 subscriptions (depending on number of workers and endpoints)
- **Why it matters**: Each Dynamo service registers subscriptions for the requests it can handle

**`nats_server_total_messages`** - Total messages processed
- **What it shows**: Cumulative count of all messages since NATS started
- **Expected value**: Increases steadily under load
- **Why it matters**: Overall message volume indicator

**`nats_server_total_streams`** - JetStream streams
- **What it shows**: Number of persistent message streams
- **Expected value**: Usually 0-2 for Grove (depends on configuration)
- **Why it matters**: JetStream provides message persistence and replay capabilities

#### Interpreting the Dashboard

**Healthy State**:
- ✅ Connections: 2-4 (workers + frontend connected)
- ✅ Message rates: Correlated with request traffic (metadata only)
- ✅ CPU: < 20%
- ✅ Memory: Stable, not growing continuously
- ✅ Subscriptions: Non-zero (services registered)

**Problem Indicators**:
- ⚠️ Connections: 0 when deployment exists → connectivity issue
- ⚠️ Message rate: Out > In by large margin → message amplification/looping
- ⚠️ CPU: Sustained > 80% → NATS bottleneck
- ⚠️ Memory: Continuously growing → memory leak or message backlog
- ⚠️ Subscriptions: 0 → services not registering with NATS

**Important Note**: NATS message volume does NOT reflect KV cache data transfer volume. NIXL handles the heavy tensor data transfer (gigabytes) separately via RDMA/TCP.

### Step 3: Understanding etcd Metrics

Key etcd metrics to monitor:

**Health Metrics**:
- `etcd_server_has_leader` - Whether cluster has a leader (should be 1)
- `etcd_server_is_leader` - Whether this instance is the leader

**Performance Metrics**:
- `etcd_mvcc_db_total_size_in_bytes` - Database size
- `rate(etcd_server_proposals_committed_total[5m])` - Proposal commit rate

**Operation Metrics**:
- `etcd_debugging_mvcc_put_total` - Total PUT operations
- `etcd_debugging_mvcc_range_total` - Total GET operations

### Step 4: Test Distributed Dynamo with Traffic

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
echo "  - NATS coordination message throughput"
echo "  - Worker utilization across 2 workers"
echo "  - KV-aware request routing"
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
echo "  - Dynamo Inference: Request throughput, TTFT, ITL across workers"
echo "  - NATS Overview: Coordination message rates (metadata only)"
echo "  - etcd Overview: Service discovery operations"
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
| **Scale Sweet Spot** | 2-50 nodes | 50-1000+ nodes |
| **Discovery** | EndpointSlices (built-in) | etcd (external) |
| **Transport** | TCP | NATS + TCP |
| **Ops Burden** | ✅ Low | ⚠️ Medium-High |
| **Multi-Region** | ⚠️ Limited | ✅ Excellent |
| **Custom Routing** | ⚠️ Basic | ✅ Advanced |
| **Cache Coordination** | ✅ Yes (via planner) | ✅ Yes (via NATS) |
| **NIXL Support** | ✅ Yes | ✅ Yes |

**Recommendation:** Start with K8s-native. Only add NATS/etcd if you hit scale limits (100+ nodes) or need multi-region.

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
✓ K8s-native sufficient for 2-50 nodes
✓ NATS/etcd for 100+ nodes or multi-region
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

### Step 3: Remove Distributed Infrastructure (Optional)

Only remove NATS and etcd if you're done experimenting with distributed Dynamo:

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
echo "✓ Distributed infrastructure removed"
echo ""
echo "Note: You can reinstall NATS/etcd anytime by re-running Section 2 of this lab"
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

- ✅ Distributed Dynamo architecture and components (NATS, etcd, NIXL)
- ✅ Difference between Grove (operator) and Dynamo (serving framework)
- ✅ Deploying distributed coordination infrastructure
- ✅ Creating a distributed Dynamo deployment with KV-aware routing
- ✅ Monitoring NATS and etcd with Grafana
- ✅ Understanding NATS (metadata) vs NIXL (KV cache data transfer)
- ✅ Trade-offs between single-node and multi-node setups

### Key Takeaways

**Architecture Clarity**:
- **Grove**: Kubernetes Operator (orchestrates Dynamo deployments)
- **Dynamo**: Inference serving framework (does the actual work)
- **NATS**: Handles coordination metadata and cache events (small messages)
- **NIXL**: Transfers actual KV cache data (gigabytes via RDMA/TCP/SSD)

**Distributed Dynamo is Powerful**:
- Enables KV-aware routing (even on single node with multiple GPUs)
- NIXL transfers cache data efficiently between workers
- Improves cache hit rates and throughput
- Essential for production scale-out scenarios

**Benefits Even on Single Node with Multiple GPUs**:
- KV-aware Router directs requests to workers with relevant cache
- Improved cache hit rates compared to random routing
- Coordination overhead is minimal with NATS

**Production Considerations**:
- Use distributed Dynamo when scaling beyond single GPU
- Monitor NATS message rates for coordination health (not data volume)
- Plan for network latency between nodes in multi-node setups
- Consider cache hit patterns for your workload
- Dynamo 0.8+ supports K8s-native discovery (optional NATS/etcd)

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
- **Small clusters (2-5 nodes)**: Distributed Dynamo provides clear benefits
- **Large clusters (10+ nodes)**: Distributed Dynamo essential for coordination
- **Dynamo 0.8+**: Can use K8s-native discovery for simpler deployments

### Next Steps

- **Experiment**: Try different worker replica counts to see KV-aware routing
- **Monitor**: Watch NATS/etcd dashboards during traffic (coordination metadata)
- **Compare**: Deploy same model without NATS/etcd and compare metrics
- **Scale**: If you have access to multi-node clusters, test distributed benefits
- **Learn**: Understand NIXL for KV cache data transfer in Dynamo docs
- **Explore**: Check out Dynamo 0.8+ features (K8s-native discovery)

---

## Troubleshooting

### NATS Not Starting

```bash
# Check NATS pods
kubectl get pods -n nats-system
kubectl logs -n nats-system nats-0

# Common issues:
# - Insufficient resources (need ~256MB RAM)
# - Port conflicts (4222 already in use)
# - PersistentVolume issues
```

### etcd Not Starting

```bash
# Check etcd pods
kubectl get pods -n etcd-system
kubectl logs -n etcd-system etcd-0

# Common issues:
# - Insufficient resources (need ~512MB RAM)
# - Volume mounting issues
# - Network policies blocking ports
```

### Workers Not Connecting to Distributed Infrastructure

```bash
# Check worker logs for NATS/NIXL connection messages
NAMESPACE=${NAMESPACE:-dynamo}

kubectl logs -n $NAMESPACE -l nvidia.com/dynamo-component=VllmWorker | grep -i "nats\|nixl"

# Verify NATS/etcd service endpoints are correct
kubectl get svc -n nats-system
kubectl get svc -n etcd-system
```

### No Cache Sharing Observed

**This is normal behavior!** Understanding what's actually happening:

**What NATS Does** (visible in metrics):
- Shares metadata about cache state between workers
- Enables KV-aware routing (Router knows which worker has which cache blocks)
- Low message volume (small coordination packets)

**What NIXL Does** (not visible in NATS metrics):
- Transfers actual KV cache data (gigabytes of tensors)
- Uses RDMA, TCP, or CPU/SSD offload
- Direct worker-to-worker communication

**On Single Node**:
- Workers can still benefit from KV-aware routing
- Cache transfers via NIXL are faster (no network)
- NATS provides coordination, not data transfer

**Benefits Require**:
- Multiple workers (even on same node)
- Repeated queries with shared prefixes
- Workload that generates cache hits

---

## Additional Resources

- **Dynamo Deployment Guide**: https://docs.nvidia.com/dynamo/latest/guides/dynamo_deploy/
- **Grove Operator Guide**: https://docs.nvidia.com/dynamo/latest/guides/dynamo_deploy/grove.html
- **Grove GitHub Repository**: https://github.com/NVIDIA/grove
- **NIXL Documentation**: NVIDIA Inference Transfer Library (check Dynamo docs)
- **NATS Documentation**: https://docs.nats.io/
- **etcd Documentation**: https://etcd.io/docs/
- **NVIDIA Dynamo Documentation**: https://docs.nvidia.com/dynamo/latest/
- **Distributed Systems Patterns**: Understanding consensus and coordination
- **KV Cache Architecture**: Understanding distributed cache strategies

---

**Congratulations! You've completed Lab 3: Distributed Dynamo with Grove Orchestration** 🌲

You now understand the fundamentals of distributed LLM serving, the difference between Grove (operator) and Dynamo (serving framework), and how NATS (metadata) and NIXL (data transfer) work together for distributed coordination!
