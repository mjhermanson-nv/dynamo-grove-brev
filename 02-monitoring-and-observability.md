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

# Lab 1 Extension: Monitoring Dynamo with Prometheus and Grafana

## Overview

In this extension to Lab 1, you will:
- Access the cluster-wide Grafana and Prometheus installation
- Configure metrics collection from your Dynamo deployment
- Create and view the Dynamo inference dashboard in Grafana
- Add Planner observability dashboard to monitor request routing
- Explore unified tracing with OpenTelemetry for debugging
- Understand key performance metrics

**Prerequisites**: Complete Lab 1 (Introduction and Kubernetes-Based Deployment)

**Note**: Prometheus and Grafana were installed cluster-wide during the initial setup. You'll verify they're running and configure them to monitor your Dynamo deployment.

## Duration: ~30 minutes

---

## Section 1: Verify Cluster Monitoring Stack

### Objectives
- Verify cluster-wide Grafana and Prometheus are running
- Get access information for Grafana dashboard
- Understand how cluster-wide monitoring works

### Important: Cluster-Wide Monitoring

The Kubernetes cluster has a **cluster-wide monitoring stack** already deployed during initial setup:
- Prometheus collects metrics from all namespaces
- Grafana provides visualization dashboards
- Services are exposed via NodePort for easy access

### Architecture
```
Cluster (monitoring namespace):
  ├── Prometheus (cluster-wide metrics collection)
  ├── Grafana (cluster-wide dashboards)
  └── Prometheus Operator (manages monitoring resources)

Your Namespace (dynamo):
  ├── Dynamo Deployment (Frontend + Workers)
  └── PodMonitors (tell Prometheus what to scrape)
```

### Step 1: Set Environment Variables

Set up the environment variables (same as Lab 1):

```bash
# Set environment variables (use defaults if not already set)
export RELEASE_VERSION=${RELEASE_VERSION:-0.8.0}
export NAMESPACE=${NAMESPACE:-dynamo}
export CACHE_PATH=${CACHE_PATH:-/data/huggingface-cache}

# Get node IP
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

# Get Grafana URL (extract ID from hostname: brev-xxxxx -> grafana0-xxxxx)
BREV_ID=$(hostname | cut -d'-' -f2)
GRAFANA_URL="https://grafana0-${BREV_ID}.brevlab.com/"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 Lab 1 Extension: Monitoring Environment Configuration"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Release Version:  $RELEASE_VERSION"
echo "  Namespace:        $NAMESPACE"
echo "  Cache Path:       $CACHE_PATH"
echo "  Node IP:          $NODE_IP"
echo ""
echo "📌 Service URLs:"
echo "  Frontend API:     http://$NODE_IP:30100"
echo "  Grafana:          $GRAFANA_URL"
echo ""
echo "💡 Grafana is configured with anonymous access (no login required)"
echo ""
echo "✓ Environment configured for monitoring"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
```

### Step 2: Verify Lab 1 Deployment is Running

**IMPORTANT:** Lab 2 requires the deployment from Lab 1 to be running. Let's verify it:

```bash
export NAMESPACE=${NAMESPACE:-dynamo}

echo "Checking Lab 1 deployment..."
echo ""
kubectl get dynamographdeployment -n $NAMESPACE
echo ""
kubectl get pods -n $NAMESPACE | grep vllm
echo ""

# Check if deployment exists
if kubectl get dynamographdeployment vllm-disagg-router -n $NAMESPACE &>/dev/null; then
    echo "✓ Lab 1 deployment found"
    
    # Check if pods are ready
    READY_PODS=$(kubectl get pods -n $NAMESPACE | grep vllm | grep "1/1" | wc -l)
    if [ "$READY_PODS" -ge 2 ]; then
        echo "✓ Deployment is healthy and ready to monitor"
    else
        echo "⚠️  Some pods are not ready yet. Wait for them to reach 1/1 Running status."
        echo "   Re-run this cell to check status again."
    fi
else
    echo "❌ Lab 1 deployment not found!"
    echo ""
    echo "Please complete Lab 1 first:"
    echo "  1. Go back to Lab 1"
    echo "  2. Complete Section 3: Deploy Distributed Model"
    echo "  3. Wait for pods to be ready (1/1 Running)"
    echo "  4. Return to this lab"
fi
```

### Step 3: Verify Monitoring Stack is Running

Check that Prometheus and Grafana pods are running:

```bash
# Check monitoring stack pods
echo "Checking cluster monitoring stack..."
echo ""
kubectl get pods -n monitoring | grep -E "(NAME|prometheus-|grafana-)"

echo ""
echo "✓ If you see Running pods, the monitoring stack is ready"
echo ""
echo "🔗 Access Grafana at: $GRAFANA_URL"
echo "   (Anonymous access enabled - no login required)"
```

---

## Section 2: Configure Metrics Collection

### Objectives
- Understand PodMonitor resources
- Configure automatic metrics discovery
- Verify metrics are being scraped by cluster Prometheus

### How Dynamo Exposes Metrics

Dynamo components expose metrics through:
- **Frontend**: Exposes `/metrics` on its HTTP port (8000)
  - Request rates, latencies, token metrics
- **Workers**: Exposes `/metrics` on system port
  - Worker-specific metrics, queue stats

**Note**: The cluster-wide Prometheus automatically discovers PodMonitors in all namespaces, so once we create them, metrics will be collected automatically.

### Step 1: Verify Dynamo Deployment Has Metrics Labels

The Dynamo operator automatically adds metrics labels to pods:

```bash
export NAMESPACE=${NAMESPACE:-dynamo}

# Check if your Dynamo pods have metrics labels
echo "Checking Dynamo pod labels:"
kubectl get pods -n $NAMESPACE -l "nvidia.com/metrics-enabled=true" --show-labels

echo ""
echo "Look for labels: nvidia.com/metrics-enabled=true"
```

### Step 2: Verify PodMonitors for Prometheus

PodMonitors tell Prometheus which pods to scrape for metrics. The Dynamo operator creates them automatically, but they need a label for cluster Prometheus to discover them.

```bash
export NAMESPACE=${NAMESPACE:-dynamo}

echo "Checking PodMonitors..."
kubectl get podmonitor -n $NAMESPACE
echo ""

# Check if PodMonitors exist
PODMONITOR_COUNT=$(kubectl get podmonitor -n $NAMESPACE 2>/dev/null | grep -c dynamo || echo "0")

if [ "$PODMONITOR_COUNT" -gt 0 ]; then
    # Show configuration for one PodMonitor
    echo "PodMonitor configuration (example: dynamo-frontend):"
    kubectl get podmonitor dynamo-frontend -n $NAMESPACE -o jsonpath='{.spec}' | python3 -m json.tool
    echo ""
    
    # Ensure they have the required label for Prometheus discovery
    echo "Labeling for Prometheus discovery..."
    kubectl label podmonitor dynamo-frontend -n $NAMESPACE release=kube-prometheus-stack --overwrite 2>/dev/null || true
    kubectl label podmonitor dynamo-planner -n $NAMESPACE release=kube-prometheus-stack --overwrite 2>/dev/null || true
    kubectl label podmonitor dynamo-worker -n $NAMESPACE release=kube-prometheus-stack --overwrite 2>/dev/null || true
    
    echo ""
    echo "✓ PodMonitors ready - Prometheus will scrape metrics within 1-2 minutes"
else
    echo "⚠️  PodMonitors not found - deployment may still be starting"
    echo "   Wait 30 seconds and re-run this cell"
fi
```

### Step 3: Test Metrics Endpoint 

Let's verify metrics are accessible:


```bash
export NAMESPACE=${NAMESPACE:-dynamo}

# Get the frontend pod name
FRONTEND_POD=$(kubectl get pods -n $NAMESPACE | grep frontend | head -1 | awk '{print $1}')

if [ -n "$FRONTEND_POD" ]; then
    echo "Testing metrics endpoint from frontend pod: $FRONTEND_POD"
    echo ""
    kubectl exec -n $NAMESPACE $FRONTEND_POD -- curl -s localhost:8000/metrics | head -20
    echo ""
    echo "✓ Metrics endpoint is accessible"
else
    echo "⚠️  Frontend pod not found. Make sure your deployment from Lab 1 is running."
fi
```

### Step 4: Send Test Traffic to Generate Metrics

Let's generate some traffic to populate metrics by sending requests to the Dynamo frontend:

```bash
# Get node IP
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

echo "Sending test requests to http://$NODE_IP:30100..."
echo ""

# Send a few test requests
for i in {1..5}; do
    echo "Request $i/5..."
    curl -s http://$NODE_IP:30100/v1/chat/completions \
      -H "Content-Type: application/json" \
      -d '{
        "model": "Qwen/Qwen2.5-1.5B-Instruct",
        "messages": [{"role": "user", "content": "Hello! Tell me a short joke."}],
        "stream": false,
        "max_tokens": 30
      }' > /dev/null
done

echo ""
echo "✓ Sent 5 test requests to generate metrics"
echo "  Metrics should now be visible in Prometheus and Grafana"
```

---

## Section 3: Import Dynamo Inference Dashboard

### Objectives
- Import the Dynamo Inference dashboard to Grafana
- Understand what metrics are displayed

### Dashboard Overview

The cluster's Grafana has a "Dynamo Operator" dashboard pre-installed, but it shows **operator metrics** (reconciliation loops, workqueues). For **inference metrics** (request rates, latency, tokens), we need to import a custom dashboard.

The Dynamo Inference dashboard provides visibility into:
- **Request Metrics**: Request rates, throughput, and counts
- **Latency Metrics**: Time to first token (TTFT), inter-token latency
- **Performance**: Request duration, inflight requests
- **Model Metrics**: Input/output sequence lengths, token counts

### Import the Inference Dashboard

Deploy the dashboard as a ConfigMap that Grafana will automatically load:

```bash
export NAMESPACE=${NAMESPACE:-dynamo}
export GRAFANA_URL=${GRAFANA_URL:-"http://$(hostname -I | awk '{print $1}'):30080"}

# Create ConfigMap with dashboard JSON in monitoring namespace (where Grafana looks)
echo "Deploying Dynamo Inference Dashboard to monitoring namespace..."

cat > /tmp/dynamo-inference-dashboard-configmap.yaml << EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-dynamo-inference
  namespace: monitoring
  labels:
    grafana_dashboard: "1"
data:
  dynamo-inference.json: |
EOF

# Add dashboard JSON with proper indentation
sed 's/^/    /' resources/dynamo-inference-dashboard.json >> /tmp/dynamo-inference-dashboard-configmap.yaml

# Apply ConfigMap
kubectl apply -f /tmp/dynamo-inference-dashboard-configmap.yaml

echo ""
echo "✓ Dashboard ConfigMap deployed to monitoring namespace"
echo "  Cluster-wide Grafana sidecar will auto-discover it within ~30 seconds"
echo "  Access at: $GRAFANA_URL (look for 'Dynamo Inference Metrics' dashboard)"
echo ""
echo "Note: The ConfigMap is created in the monitoring namespace where"
echo "      the cluster-wide Grafana sidecar searches for dashboards."
```

---

## Section 4: Access Grafana and View Metrics

### Objectives
- Access Grafana UI via Brev tunnel
- Import the Dynamo dashboard
- Query metrics in Prometheus
- View Dynamo metrics in Grafana

### Step 1: View Dynamo Inference Dashboard

Once you've imported the dashboard (from Section 3):

1. **Click on "Dashboards"** in the left sidebar
2. **Search for "Dynamo Inference"** or look in the "General" folder
3. **Open the dashboard**

The dashboard displays:
- **Request Rate**: Requests per second by model
- **Time to First Token (TTFT)**: p50, p95, p99 percentiles
- **Inter-Token Latency**: Token generation speed
- **Request Duration**: Total time per request
- **Token Metrics**: Input/output sequence lengths
- **Inflight Requests**: Currently processing requests

**Note**: The Grafana also has a "Dynamo Operator" dashboard showing operator metrics (reconciliation loops, workqueues), but the inference dashboard shows model serving metrics.

### Step 2: Generate Load to See Metrics

To see interesting metrics in the dashboard, generate some load using the benchmark script from Lab 1.

**Run this in a terminal (not in the notebook):**

```
cd ~/dynamo-grove-brev/lab1
./run-benchmark.sh baseline
```

Or send a few test requests:

```bash
# Get node IP
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

# Send test requests
for i in {1..10}; do
    echo "Request $i/10..."
    curl -s http://$NODE_IP:30100/v1/chat/completions \
      -H "Content-Type: application/json" \
      -d '{
        "model": "Qwen/Qwen2.5-1.5B-Instruct",
        "messages": [{"role": "user", "content": "Hello!"}],
        "stream": false,
        "max_tokens": 30
      }' > /dev/null
done

echo ""
echo "✓ Sent 10 test requests - check Grafana dashboard for updated metrics!"
```

---

## Section 5: Unified Tracing with OpenTelemetry (New in v0.8.0)

### Objectives
- Understand distributed tracing in Dynamo
- Enable OpenTelemetry tracing
- Visualize end-to-end request flows

### What is Unified Tracing?

Dynamo v0.8.0 introduces **OpenTelemetry-based distributed tracing** that tracks requests across:
- Frontend API layer
- Planner routing decisions
- Prefill worker execution
- KV cache transfers
- Decode worker execution

This gives you **end-to-end visibility** into where time is spent in complex requests.

### Enable Tracing (Optional)

**Note:** This requires a tracing backend like Jaeger or Tempo. For this lab, we'll show the configuration.


```bash
# Example: Enable OpenTelemetry tracing in Dynamo deployment
# Add these annotations to your DynamoGraphDeployment:

cat <<EOF
spec:
  frontend:
    annotations:
      opentelemetry.io/enabled: "true"
      opentelemetry.io/exporter: "otlp"
      opentelemetry.io/endpoint: "http://jaeger-collector:4317"
  workers:
    annotations:
      opentelemetry.io/enabled: "true"
EOF

echo "Note: Tracing requires a backend like Jaeger or Tempo"
echo "For production deployments, integrate with your observability stack"
```

### What Tracing Shows You

With tracing enabled, you can see:

1. **Request Flow Timeline:**
   - Frontend receives request: 0ms
   - Planner makes routing decision: 2ms
   - Prefill worker starts: 5ms
   - KV cache transfer: 150ms
   - Decode worker generates: 300ms
   - Response returned: 800ms

2. **Bottleneck Identification:**
   - Slow prefill? → Model loading issue
   - Slow KV transfer? → Network/NIXL issue
   - Slow decode? → Batch size or GPU utilization

3. **Cache Effectiveness:**
   - Trace shows "KV cache hit" span = prompt was cached
   - No cache hit = full prefill required

**Production Tip:** Combine tracing with metrics for powerful debugging. Use metrics for aggregate patterns, traces for individual request debugging.

---

## Section 6: Understanding Key Metrics

### Frontend Metrics

The Dynamo frontend exposes these key metrics:

| Metric | Description | Use Case |
|--------|-------------|----------|
| `dynamo_frontend_requests_total` | Total number of requests | Track request volume |
| `dynamo_frontend_time_to_first_token_seconds` | Time until first token appears | User experience, responsiveness |
| `dynamo_frontend_inter_token_latency_seconds` | Time between consecutive tokens | Generation speed, smoothness |
| `dynamo_frontend_request_duration_seconds` | Total request duration | Overall latency |
| `dynamo_frontend_input_tokens_total` | Input tokens processed | Input size distribution |
| `dynamo_frontend_output_tokens_total` | Output tokens generated | Output size, throughput |

### Worker Metrics

Workers expose additional metrics:

| Metric | Description | Use Case |
|--------|-------------|----------|
| `dynamo_worker_queue_size` | Requests waiting in queue | Identify backpressure |
| `dynamo_worker_active_requests` | Currently processing requests | Worker utilization |
| `dynamo_worker_kv_cache_usage` | KV cache memory usage | Memory optimization |

### Exploring Metrics in Prometheus

### Exploring Advanced Queries

You can run advanced Prometheus queries directly in Grafana's Explore view:

1. **Open Grafana** at `$GRAFANA_URL`
2. **Click "Explore"** in the left sidebar (compass icon)
3. **Select "Prometheus"** as the data source
4. **Enter queries** in the query editor

Try these advanced queries:

**Total Requests:**
```
sum(dynamo_frontend_requests_total)
```

**Average Request Rate (last 5 minutes):**
```
avg(rate(dynamo_frontend_requests_total[5m]))
```

**95th Percentile TTFT over time:**
```
histogram_quantile(0.95, rate(dynamo_frontend_time_to_first_token_seconds_bucket[5m]))
```

**Tokens per second:**
```
rate(dynamo_frontend_output_sequence_tokens_sum[5m]) / rate(dynamo_frontend_output_sequence_tokens_count[5m])
```

---

## Section 7: Exercises and Exploration

### Exercise 1: Correlate Load with Latency

1. Run different concurrency levels with aiperf
2. Observe how TTFT and ITL change in Grafana
3. Find the optimal concurrency for your deployment

**Run these commands in a terminal (not in the notebook):**

```
# Test with low concurrency
cd ~/dynamo-brev/resources
./run-benchmark.sh baseline

# Check Grafana - note the TTFT values
# Then test with higher concurrency:

# Get NODE_IP
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

# Test with high concurrency
python3 -m aiperf profile \
  --model Qwen/Qwen2.5-1.5B-Instruct \
  --url http://$NODE_IP:30100 \
  --endpoint-type chat \
  --streaming \
  --concurrency 8 \
  --request-count 30

# Compare TTFT between low and high concurrency in Grafana
```

### Exercise 2: Create Custom Prometheus Queries

Try creating your own queries:

1. **Average TTFT over time:**
   ```
   avg(rate(dynamo_frontend_time_to_first_token_seconds_sum[1m]))
   ```

2. **Request success rate:**
   ```
   rate(dynamo_frontend_requests_total{status="success"}[1m])
   ```

3. **Tokens per second:**
   ```
   rate(dynamo_frontend_output_tokens_total[1m])
   ```

### Exercise 3: Set Up Alerts (Optional)

Create a PrometheusRule for high latency alerts. Here's an example configuration:

```yaml
# Example: high-latency-alert.yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: dynamo-alerts
  namespace: dynamo
  labels:
    release: kube-prometheus-stack
spec:
  groups:
  - name: dynamo
    interval: 30s
    rules:
    - alert: HighTimeToFirstToken
      expr: histogram_quantile(0.95, rate(dynamo_frontend_time_to_first_token_seconds_bucket[5m])) > 1.0
      for: 2m
      labels:
        severity: warning
      annotations:
        summary: "High Time to First Token"
        description: "95th percentile TTFT is above 1 second"
```

To create and apply this alert:

```bash
# Create the alert file
cat > /tmp/high-latency-alert.yaml << EOF
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: dynamo-alerts
  namespace: $NAMESPACE
  labels:
    release: kube-prometheus-stack
spec:
  groups:
  - name: dynamo
    interval: 30s
    rules:
    - alert: HighTimeToFirstToken
      expr: histogram_quantile(0.95, rate(dynamo_frontend_time_to_first_token_seconds_bucket[5m])) > 1.0
      for: 2m
      labels:
        severity: warning
      annotations:
        summary: "High Time to First Token"
        description: "95th percentile TTFT is above 1 second"
EOF

# Apply the alert
kubectl apply -f /tmp/high-latency-alert.yaml

echo ""
echo "✓ Alert rule created"
echo "  View alerts in Grafana: Alerting section"
```

### Exercise 4: Cleanup Your Monitoring Resources

When you're done exploring, you can remove the monitoring resources you created:

```bash
# Remove PodMonitors and Dashboard ConfigMap from your namespace
echo "Cleaning up monitoring resources from namespace: $NAMESPACE..."

kubectl delete podmonitor -n $NAMESPACE --all
kubectl delete configmap grafana-dashboard-dynamo-inference -n $NAMESPACE 2>/dev/null || true

echo ""
echo "✓ Monitoring resources removed from your namespace"
echo ""
echo "Note: The cluster-wide Prometheus and Grafana remain active."
echo "      Only your PodMonitors and dashboard ConfigMap were removed."
```

---

## Known Issues

For known issues related to Dynamo v0.8.0 observability features, see the [Known Issues section in the main repository](https://github.com/ai-dynamo/dynamo/blob/main/KNOWN_ISSUES.md).

---

## Summary

### What You Learned
- ✅ How to access cluster-wide Prometheus and Grafana
- ✅ Understanding Prometheus Operator and PodMonitors
- ✅ Configuring automatic metrics collection from Dynamo
- ✅ Creating and deploying Grafana dashboards via ConfigMaps
- ✅ Key Dynamo performance metrics
- ✅ Using Prometheus queries for analysis
- ✅ Correlating load with performance metrics

### Key Takeaways
- **Cluster-wide monitoring** enables shared observability infrastructure
- **PodMonitors** automatically discover and scrape Dynamo metrics
- **Prometheus** provides powerful query language for metric analysis
- **Grafana** offers rich visualizations for real-time monitoring
- **Key metrics** like TTFT and ITL are critical for LLM performance
- **Dashboard ConfigMaps** with `grafana_dashboard: "1"` label are auto-discovered by Grafana sidecar

### Next Steps
- In **Lab 2**, you'll explore disaggregated serving and monitor the separate prefill/decode workers
- Advanced monitoring: Set up alerting rules and long-term metric storage
- Integrate with your CI/CD: Automated performance regression testing

---

## Troubleshooting

### Prometheus Not Scraping Metrics


```bash
# Check Prometheus targets
echo "Checking if Prometheus is scraping Dynamo pods..."
echo ""
echo "You can also view targets in Grafana:"
echo "  1. Go to $GRAFANA_URL"
echo "  2. Navigate to Status > Targets (in Prometheus section)"
echo ""
echo "Look for Dynamo pods in the targets list"
echo "If pods are missing, check PodMonitor configuration:"
kubectl get podmonitor -n $NAMESPACE -o yaml
```

### Grafana Dashboard Not Appearing


```bash
# Check if dashboard ConfigMap has correct labels
kubectl get configmap -n $NAMESPACE grafana-dashboard-dynamo-inference -o yaml | grep -A 5 labels

echo ""
echo "The ConfigMap should have label: grafana_dashboard: '1'"
echo ""
echo "If the ConfigMap exists but dashboard doesn't appear:"
echo "  1. Wait 30-60 seconds for Grafana sidecar to scan"
echo "  2. Check Grafana logs for any import errors"
echo "  3. Verify cluster-wide Grafana has sidecar.dashboards.enabled=true"
```

### Can't Access Grafana


```bash
# Check Grafana pod status
kubectl get pods -n $NAMESPACE | grep grafana

# Check Grafana logs
GRAFANA_POD=$(kubectl get pods -n $NAMESPACE | grep grafana | awk '{print $1}')
kubectl logs -n $NAMESPACE $GRAFANA_POD --tail=30
```

### Port Forwards Not Working


```bash
# Kill all existing port-forwards and restart
pkill -f 'kubectl port-forward' || true

echo "✓ Killed existing port-forwards"
echo ""
echo "Re-run the port-forward commands from Section 4"
```

---

## Additional Resources

- 📖 [Dynamo Metrics Documentation](../../dynamo/docs/observability/metrics.md)
- 📊 [Prometheus Query Examples](https://prometheus.io/docs/prometheus/latest/querying/examples/)
- 🎨 [Grafana Dashboard Best Practices](https://grafana.com/docs/grafana/latest/dashboards/build-dashboards/best-practices/)
- 🔔 [Prometheus Alerting](https://prometheus.io/docs/alerting/latest/overview/)

