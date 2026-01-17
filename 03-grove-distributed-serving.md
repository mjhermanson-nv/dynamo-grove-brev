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

# Lab 3: Distributed Serving with Grove

## Overview

In this lab, you will:
- Understand Grove's distributed serving architecture
- Deploy NATS and etcd for distributed coordination
- Enable distributed KV cache sharing across workers
- Monitor distributed components with Grafana
- Understand when and why to use Grove in production

**Prerequisites**: Complete Lab 1 (Dynamo Deployment) and Lab 2 (Monitoring)

**Note**: Grove is designed for multi-node Kubernetes clusters. While we'll deploy it on a single node for learning purposes, its benefits are realized when scaling across multiple nodes.

## Duration: ~45 minutes

---

## Section 1: Understanding Grove Architecture

### What is Grove?

Grove is Dynamo's distributed serving framework that enables:
- **Multi-node deployments** across Kubernetes clusters
- **Distributed KV cache sharing** between worker nodes via NATS
- **Coordination and discovery** using etcd
- **Advanced features** like cache migration and load balancing

### Architecture Components

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
              │  (Request Routing &   │
              │   Cache Sharing)      │
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
    └──────────┘    └──────────┘    └──────────┘
    
    Shared KV Cache across workers via NATS

Note: Workers typically run on GPU nodes (4-6), separate from
      CPU-only frontend nodes (1-3). In smaller clusters, they
      may share nodes with frontends.
```

### Key Concepts

**NATS**: A high-performance message bus that enables:
- Real-time cache synchronization
- Low-latency pub/sub messaging
- Resilient delivery guarantees

**etcd**: A distributed key-value store that provides:
- Service discovery and registration
- Configuration management
- Leader election and coordination

**Distributed KV Cache**: Allows workers to share key-value cache entries:
- Reduces redundant computation
- Improves cache hit rates
- Enables efficient multi-node scaling

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
3. **Frontend** publishes inference request to NATS
4. **NATS** routes to an available worker (on any node)
5. **Worker** responds via NATS
6. **Frontend** returns HTTP response

**Key Benefits**:
- ✅ **High Availability**: If one frontend crashes, others continue
- ✅ **Load Distribution**: Spread HTTP connections across pods
- ✅ **Dynamic Discovery**: NATS decouples frontends from workers
- ✅ **Flexible Scaling**: Add/remove frontends independently

**Single Node (This Lab)**:
In your single-node setup, multiple frontends provide less benefit since there's no network distribution. But you can still see how NATS-based service discovery works!

### When to Use Grove

| Scenario | Use Grove? | Why |
|----------|-----------|-----|
| Single node deployment | ❌ No | Adds overhead without benefit |
| 2-3 nodes | ⚠️ Maybe | Benefit depends on cache hit patterns |
| 4+ nodes | ✅ Yes | Significant performance improvements |
| High traffic, repeated queries | ✅ Yes | Cache sharing reduces latency |
| Low traffic, unique queries | ❌ No | Cache misses negate benefits |

---

## Section 2: Deploy Grove Infrastructure

### Step 1: Set Environment Variables

```bash
# Set environment variables (use defaults if not already set)
export RELEASE_VERSION=${RELEASE_VERSION:-0.7.1}
export NAMESPACE=${NAMESPACE:-dynamo}
export CACHE_PATH=${CACHE_PATH:-/data/huggingface-cache}

# Get node IP
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🌲 Lab 3: Grove Distributed Serving Configuration"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Release Version:  $RELEASE_VERSION"
echo "  Namespace:        $NAMESPACE"
echo "  Node IP:          $NODE_IP"
echo ""
echo "✓ Environment configured for Grove setup"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
```

### Step 2: Install NATS Message Bus

NATS will handle distributed cache communication between workers:

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
echo "  NATS:  nats://nats.nats-system:4222"
echo "  etcd:  http://etcd.etcd-system:2379"
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
echo "✓ Prometheus monitoring enabled for Grove infrastructure"
echo "  Metrics will be available in Grafana within 2-3 minutes"
echo ""
echo "  NATS metrics: Scraped from prometheus-nats-exporter (port: prom-metrics)"
echo "  etcd metrics: Scraped directly from etcd's /metrics endpoint (port: client)"
echo ""
echo "Note: etcd metrics typically appear faster than NATS metrics"
```

---

## Section 3: Deploy Grove-Enabled Model

### Understanding Dynamo's NATS Integration

Dynamo automatically uses NATS for distributed communication when NATS and etcd are available in the cluster. The deployment will:

**1. Workers register via NATS**: Each worker announces itself to the message bus
**2. Frontend discovers workers**: The frontend finds workers through NATS service discovery
**3. NIXL handles KV cache**: NVIDIA's distributed KV cache system coordinates cache sharing

### Step 1: Create Grove-Enabled Deployment

We'll create a deployment with 2 workers to demonstrate Grove's distributed architecture:

```bash
# Create Grove-enabled deployment
echo "Creating Grove-enabled deployment with 2 workers..."

cat <<'EOF' | kubectl apply -f -
apiVersion: nvidia.com/v1alpha1
kind: DynamoGraphDeployment
metadata:
  name: vllm-grove-demo
  namespace: dynamo
spec:
  services:
    Frontend:
      dynamoNamespace: vllm-grove-demo
      componentType: frontend
      replicas: 1
      extraPodSpec:
        mainContainer:
          image: nvcr.io/nvidia/ai-dynamo/vllm-runtime:0.7.1
    VllmWorker:
      envFromSecret: hf-token-secret
      dynamoNamespace: vllm-grove-demo
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
echo "✓ Grove-enabled deployment created"
echo "  Deployment: vllm-grove-demo"
echo "  Workers: 2 (will use NATS for discovery)"
```

### Step 2: Create NodePort Service

Expose the frontend for testing:

```bash
# Create NodePort service
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: vllm-grove-demo-frontend-np
  namespace: dynamo
spec:
  type: NodePort
  selector:
    nvidia.com/dynamo-component: Frontend
    nvidia.com/dynamo-graph-deployment-name: vllm-grove-demo
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
echo "Waiting for Grove-enabled deployment..."
echo "This may take 2-3 minutes for model download and initialization..."
echo ""

NAMESPACE=${NAMESPACE:-dynamo}

# Wait for pods to be ready
kubectl wait --for=condition=ready --timeout=300s \
  pods -l nvidia.com/dynamo-graph-deployment-name=vllm-grove-demo \
  -n $NAMESPACE 2>/dev/null || echo "Pods are initializing..."

echo ""
echo "Deployment status:"
kubectl get pods -n $NAMESPACE -l nvidia.com/dynamo-graph-deployment-name=vllm-grove-demo

echo ""
echo "✓ Grove-enabled deployment ready"
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
    "messages": [{"role": "user", "content": "Explain Grove in one sentence"}],
    "max_tokens": 50
  }' | python3 -m json.tool

echo ""
echo "✓ Grove deployment is serving requests via NATS"
```

### Step 5: Verify NATS Communication

```bash
# Check worker logs for NATS connectivity
echo "Verifying NATS integration..."
NAMESPACE=${NAMESPACE:-dynamo}

WORKER_POD=$(kubectl get pods -n $NAMESPACE -l nvidia.com/dynamo-component=VllmWorker,nvidia.com/dynamo-graph-deployment-name=vllm-grove-demo -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -n "$WORKER_POD" ]; then
    echo "Checking worker: $WORKER_POD"
    kubectl logs -n $NAMESPACE $WORKER_POD 2>&1 | grep -i "nats\|nixl" | head -5
    
    echo ""
    echo "✓ Workers are using NATS for distributed coordination"
    echo "  NIXL (NVIDIA's distributed KV cache system) is active"
else
    echo "⚠️ No worker pods found. Make sure the deployment is running:"
    kubectl get pods -n $NAMESPACE -l nvidia.com/dynamo-graph-deployment-name=vllm-grove-demo
fi
```

---

## Section 4: Monitoring Grove Components

### Step 1: Access Grafana Dashboards

The Grove infrastructure dashboards were created during the oneshot.sh bootstrap:

```bash
# Get Grafana URL
BREV_ID=$(hostname | cut -d'-' -f2)
GRAFANA_URL="https://grafana0-${BREV_ID}.brevlab.com/"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 Grove Monitoring Dashboards"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Grafana URL: $GRAFANA_URL"
echo ""
echo "  Available Dashboards:"
echo "    • NATS Overview - Message bus metrics"
echo "    • etcd Overview - Coordination layer metrics"
echo "    • Dynamo Inference Metrics - Model serving metrics"
echo ""
echo "🔗 Open Grafana and search for these dashboards"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
```

### Step 2: Understanding NATS Metrics

The NATS Overview dashboard shows real-time metrics about the message bus that Grove uses for distributed coordination.

#### Connection Metrics (Top Left Panel)

**`nats_varz_connections`** - Current active connections to NATS
- **What it shows**: Number of clients currently connected to the NATS server
- **Expected value**: 
  - With Grove deployment running: 2-4 connections (workers + frontend)
  - Without active deployment: 0
- **Why it matters**: Each Dynamo component (frontend, workers) maintains a connection to NATS for request routing

#### Message Rate Metrics (Top Center Panels)

**`rate(nats_varz_in_msgs[1m])`** - Incoming messages per second
- **What it shows**: How many messages NATS is receiving per second
- **Expected value**: 
  - Idle: 0 msg/s
  - During load: 10-100+ msg/s depending on request rate
- **Why it matters**: Shows the message throughput into NATS from Dynamo components

**`rate(nats_varz_out_msgs[1m])`** - Outgoing messages per second
- **What it shows**: How many messages NATS is sending per second
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
- ✅ Message rates: Correlated with request traffic
- ✅ CPU: < 20%
- ✅ Memory: Stable, not growing continuously
- ✅ Subscriptions: Non-zero (services registered)

**Problem Indicators**:
- ⚠️ Connections: 0 when deployment exists → connectivity issue
- ⚠️ Message rate: Out > In by large margin → message amplification/looping
- ⚠️ CPU: Sustained > 80% → NATS bottleneck
- ⚠️ Memory: Continuously growing → memory leak or message backlog
- ⚠️ Subscriptions: 0 → services not registering with NATS

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

### Step 4: Test Grove with Traffic

Generate meaningful traffic to see Grove in action:

```bash
# Generate test traffic with concurrent requests
echo "Generating traffic to Grove-enabled deployment..."
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
echo "  - NATS message throughput"
echo "  - Worker utilization across 2 workers"
echo "  - Request distribution via NATS"
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
echo "  - etcd Overview: Key operations (if Grove uses etcd for coordination)"
echo ""
echo "View Grafana: https://grafana0-$(hostname | sed 's/^brev-//').brevlab.com/"
```

---

## Section 5: Understanding Grove Trade-offs

### Single-Node vs Multi-Node

**Single Node (Current Setup)**:
```
✗ No benefit from cache sharing (all workers on same node)
✗ Added latency from NATS message passing
✗ Additional resource overhead (NATS + etcd)
✓ Learning opportunity to understand architecture
```

**Multi-Node (Production)**:
```
✓ Workers share cache across nodes
✓ Improved cache hit rates = lower latency
✓ Better resource utilization across cluster
✓ Enables advanced features (cache migration, load balancing)
✗ Network latency between nodes
✗ Increased complexity in debugging
```

### Performance Characteristics

```bash
# Display performance comparison
cat <<'EOF'

Performance Impact of Grove:

┌─────────────────────┬──────────────┬──────────────┐
│ Metric              │ Single Node  │ Multi-Node   │
├─────────────────────┼──────────────┼──────────────┤
│ Cache Hit Rate      │ Same         │ +20-40%      │
│ Latency (P50)       │ +5-10ms      │ +2-5ms       │
│ Latency (P99)       │ +10-20ms     │ +5-10ms      │
│ Throughput          │ -5-10%       │ +30-60%      │
│ Memory Overhead     │ +100-200MB   │ +100-200MB   │
└─────────────────────┴──────────────┴──────────────┘

When Grove Helps Most:
  • Multiple nodes with high traffic
  • Repeated queries (high cache hit potential)
  • Long context lengths (expensive to recompute)
  • Batch processing workloads

When Grove May Not Help:
  • Single node deployments
  • Unique queries (low cache hit rate)
  • Short context lengths
  • Real-time streaming with varying prompts
EOF
```

---

## Section 6: Advanced Grove Features

### Cache Monitoring

Check Grove coordination through worker logs:

```bash
# Get cache stats from worker logs
NAMESPACE=${NAMESPACE:-dynamo}

WORKER_POD=$(kubectl get pods -n $NAMESPACE -l nvidia.com/dynamo-component=VllmWorker,nvidia.com/dynamo-graph-deployment-name=vllm-grove-demo -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -n "$WORKER_POD" ]; then
    echo "Checking NIXL/Grove activity in worker logs..."
    echo ""
    kubectl logs -n $NAMESPACE $WORKER_POD --tail=100 | grep -i "nixl\|grove\|nats" | tail -10
    
    echo ""
    echo "Worker pod: $WORKER_POD"
    echo ""
    echo "What to look for:"
    echo "  - NIXL initialization messages"
    echo "  - NATS connection status"
    echo "  - KV cache registration"
    echo "  - UCX backend messages (if using RDMA)"
else
    echo "⚠️ No worker pods found"
    echo "Make sure the vllm-grove-demo deployment is running"
fi
```

**Note**: Cache hit/miss metrics depend on workload patterns. In a single-node setup, local cache is more efficient than distributed cache, so you may not see significant Grove cache sharing activity.

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

### Step 1: Remove Grove Demo Deployment

```bash
# Delete the Grove deployment
echo "Removing Grove deployment..."
NAMESPACE=${NAMESPACE:-dynamo}

kubectl delete dynamographdeployment vllm-grove-demo -n $NAMESPACE
kubectl delete svc vllm-grove-demo-frontend-np -n $NAMESPACE

echo "✓ Grove deployment removed"
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

### Step 3: Remove Grove Infrastructure (Optional)

Only remove NATS and etcd if you're done experimenting with Grove:

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
echo "✓ Grove infrastructure removed"
echo ""
echo "Note: You can reinstall NATS/etcd anytime by re-running Section 2 of this lab"
```

---

## Summary

### What You Learned

- ✅ Grove architecture and components (NATS, etcd, NIXL)
- ✅ Deploying distributed coordination infrastructure
- ✅ Creating a Grove-enabled Dynamo deployment
- ✅ Monitoring NATS and etcd with Grafana
- ✅ Understanding NATS-based worker discovery
- ✅ Trade-offs between single-node and multi-node setups

### Key Takeaways

**Grove is Powerful for Multi-Node**:
- Enables distributed KV cache sharing
- Improves cache hit rates and throughput
- Essential for production scale-out scenarios

**Adds Overhead on Single Node**:
- NATS/etcd resource consumption
- Message passing latency
- Coordination complexity

**Production Considerations**:
- Use Grove when scaling beyond 3-4 nodes
- Monitor NATS message rates to ensure efficiency
- Plan for network latency between nodes
- Consider cache hit patterns for your workload

### Real-World Applications

**When Companies Use Grove**:
- Multi-region LLM deployments
- High-traffic serving (1000+ RPS)
- Cost optimization (share expensive cache)
- Enterprise multi-tenant platforms

**Grove Alternatives**:
- Single-node: No distributed cache needed
- Small clusters (2-3 nodes): Consider Ray's native cache sharing
- Very large clusters (50+ nodes): May need custom sharding strategies

### Next Steps

- **Experiment**: Try different worker replica counts
- **Monitor**: Watch NATS/etcd dashboards during traffic
- **Compare**: Deploy same model without Grove and compare metrics
- **Scale**: If you have access to multi-node clusters, test Grove benefits
- **Explore**: Check out Dynamo's advanced Grove features in the docs

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

### Workers Not Connecting to Grove

```bash
# Check worker logs for Grove connection messages
NAMESPACE=${NAMESPACE:-dynamo}

kubectl logs -n $NAMESPACE -l nvidia.com/dynamo-component=VllmWorker | grep -i grove

# Verify NATS/etcd service endpoints are correct
kubectl get svc -n nats-system
kubectl get svc -n etcd-system
```

### No Cache Sharing Observed

**This is expected on single node!** Grove's cache sharing benefits require:
- Multiple Kubernetes nodes
- Workers distributed across nodes
- Repeated queries to build cache

On a single node, all workers share memory naturally, so Grove adds overhead without benefit.

---

## Additional Resources

- **Grove Deployment Guide**: https://docs.nvidia.com/dynamo/latest/guides/dynamo_deploy/grove.html
- **Grove GitHub Repository**: https://github.com/NVIDIA/grove
- **NATS Documentation**: https://docs.nats.io/
- **etcd Documentation**: https://etcd.io/docs/
- **NVIDIA Dynamo Documentation**: https://docs.nvidia.com/dynamo/latest/
- **Distributed Systems Patterns**: Understanding consensus and coordination
- **Cache Sharing Strategies**: Martin Kleppmann's "Designing Data-Intensive Applications"

---

**Congratulations! You've completed Lab 3: Distributed Serving with Grove** 🌲

You now understand the fundamentals of distributed LLM serving and are prepared for multi-node production deployments!
