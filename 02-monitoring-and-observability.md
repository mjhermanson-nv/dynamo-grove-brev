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
- Create and view the Dynamo dashboard in Grafana
- Explore metrics in Prometheus
- Understand key performance metrics

**Prerequisites**: Complete Lab 1 (Introduction and Kubernetes-Based Deployment)

**Note**: Prometheus and Grafana were installed cluster-wide during the initial setup. You'll verify they're running and configure them to monitor your Dynamo deployment.

## Duration: ~20 minutes

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
export RELEASE_VERSION=${RELEASE_VERSION:-0.7.1}
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

### Step 2: Verify Monitoring Stack is Running

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
# Check if your Dynamo pods have metrics labels
echo "Checking Dynamo pod labels:"
kubectl get pods -n $NAMESPACE -l nvidia.com/metrics-enabled=true --show-labels

echo ""
echo "Look for labels: nvidia.com/metrics-enabled=true"
```

### Step 2: Check if PodMonitors Were Created

The Dynamo operator should automatically create PodMonitor resources:

```bash
# List PodMonitors in your namespace
echo "PodMonitors in namespace $NAMESPACE:"
kubectl get podmonitor -n $NAMESPACE

echo ""
echo "You should see PodMonitors for frontend and worker components"
echo "These are automatically discovered by the cluster Prometheus"
```

### Step 3: Label PodMonitors for Prometheus Discovery

The cluster Prometheus requires PodMonitors to have a specific label. Let's add it:

```bash
# Add the required label to Dynamo PodMonitors
echo "Labeling PodMonitors for Prometheus discovery..."

kubectl label podmonitor -n $NAMESPACE dynamo-frontend release=kube-prometheus-stack --overwrite
kubectl label podmonitor -n $NAMESPACE dynamo-planner release=kube-prometheus-stack --overwrite
kubectl label podmonitor -n $NAMESPACE dynamo-worker release=kube-prometheus-stack --overwrite

echo ""
echo "✓ PodMonitors labeled - Prometheus will now discover and scrape metrics"
echo "  It may take 1-2 minutes for metrics to appear in Grafana"
```

### Step 4: Manually Test Metrics Endpoint

Let's verify metrics are accessible:


```bash
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

### Step 5: Send Test Traffic to Generate Metrics

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
# Create ConfigMap with dashboard JSON
echo "Deploying Dynamo Inference Dashboard..."

cat > /tmp/dynamo-inference-dashboard-configmap.yaml << 'EOF'
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
sed 's/^/    /' ~/dynamo-brev/resources/dynamo-inference-dashboard.json >> /tmp/dynamo-inference-dashboard-configmap.yaml

# Apply ConfigMap
kubectl apply -f /tmp/dynamo-inference-dashboard-configmap.yaml

echo ""
echo "✓ Dashboard ConfigMap deployed"
echo "  Grafana sidecar will auto-load it within ~30 seconds"
echo "  Access at: $GRAFANA_URL (look for 'Dynamo Inference Metrics' dashboard)"
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

### Step 2: Explore Prometheus Queries

You can also access Prometheus directly to query metrics. Click on "Explore" in Grafana's left sidebar, then try these queries:

**Example Prometheus Queries:**

1. **Total requests to frontend:**
   ```
   dynamo_frontend_requests_total
   ```

2. **Time to first token (95th percentile):**
   ```
   histogram_quantile(0.95, dynamo_frontend_time_to_first_token_seconds_bucket)
   ```

3. **Request rate (per second):**
   ```
   rate(dynamo_frontend_requests_total[1m])
   ```

4. **Inter-token latency:**
   ```
   dynamo_frontend_inter_token_latency_seconds
   ```

### Step 3: Generate Load to See Metrics

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

## Section 5: Understanding Key Metrics

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

## Section 6: Exercises and Exploration

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

### Exercise 4: Cleanup Monitoring Stack

When you're done exploring, you can remove the monitoring stack:


```bash
# Uninstall kube-prometheus-stack (optional - only if you're done)
# helm uninstall prometheus -n $NAMESPACE

# Or keep it for future use!
echo "Monitoring stack is still running in namespace: $NAMESPACE"
echo "To remove it later, run:"
echo "  helm uninstall prometheus -n $NAMESPACE"
```

---

## Summary

### What You Learned
- ✅ How to install namespace-scoped Prometheus and Grafana
- ✅ Understanding Prometheus Operator and PodMonitors
- ✅ Configuring automatic metrics collection from Dynamo
- ✅ Creating and viewing Grafana dashboards
- ✅ Key Dynamo performance metrics
- ✅ Using Prometheus queries for analysis
- ✅ Correlating load with performance metrics

### Key Takeaways
- **Namespace-scoped monitoring** enables safe multi-tenant clusters
- **PodMonitors** automatically discover and scrape Dynamo metrics
- **Prometheus** provides powerful query language for metric analysis
- **Grafana** offers rich visualizations for real-time monitoring
- **Key metrics** like TTFT and ITL are critical for LLM performance

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
kubectl get configmap -n $NAMESPACE grafana-dynamo-dashboard -o yaml | grep -A 5 labels

echo ""
echo "The ConfigMap should have label: grafana_dashboard: '1'"
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

