# Dynamo on Brev

Interactive Jupyter notebooks for learning and deploying NVIDIA Dynamo on Kubernetes using [Brev](https://brev.dev). These guides walk you through deploying high-performance LLM inference workloads with monitoring and observability.

**Note**: These guides are designed for Brev environments with automatic Grafana tunneling and pre-configured networking. They may require modifications for other Kubernetes platforms.

## 📚 Guides

### 01 - Dynamo Deployment Guide
**File**: `01-dynamo-deployment-guide.ipynb`

Deploy a **disaggregated serving** model where inference workloads are split between specialized workers. One worker handles prompt processing (prefill) while another generates response tokens (decode). This architecture optimizes GPU utilization by dedicating resources to each task. You'll deploy a small language model (Qwen 1.5B) on 2 GPUs, test it using OpenAI-compatible APIs, and run performance benchmarks.

**Duration**: ~90 minutes

### 02 - Monitoring and Observability
**File**: `02-monitoring-and-observability.ipynb`

Add monitoring to your Dynamo deployment using the cluster's built-in Prometheus and Grafana. You'll configure automatic metrics collection from your deployment, import a pre-built dashboard showing key performance indicators, and learn to interpret critical metrics like time-to-first-token (TTFT) and inter-token latency (ITL). Generate load and watch real-time metrics to understand your deployment's behavior.

**Duration**: ~20 minutes

### 03 - KV-Aware Routing
**File**: `03-grove-distributed-serving.ipynb`

Learn **KV-aware routing**, an intelligent load balancing feature that tracks which workers have cached data and routes requests accordingly. Deploy 2 identical workers (data parallelism) where the router monitors cache state via NATS and directs requests with similar prefixes to workers with matching cached blocks. This dramatically reduces time-to-first-token for chatbots, document Q&A, and any workload with repeated prompt patterns. Deploy NATS for cache coordination, configure the frontend with `--router-mode kv`, and demonstrate 5-10x faster responses for cache hits.

**Duration**: ~60 minutes  
**Note**: Requires NATS deployment for cache event coordination. Different from Lab 1's disaggregated architecture.

## 🚀 Quick Start

This workshop is designed to run on Brev workspaces with pre-configured GPU infrastructure.

### Getting Started

1. Open this workspace in Brev
2. Start Jupyter Lab (if not already running)
3. Open `01-dynamo-deployment-guide.ipynb` to begin

**Note**: These guides use Brev-specific features like Grafana tunneling and pre-configured Kubernetes clusters.

## 📖 Guide Structure

Each guide is provided in two formats:
- **`.md`** - Markdown source (authoritative, use for editing)
- **`.ipynb`** - Jupyter notebook (generated from markdown)

The markdown format allows for better version control and easier editing. Use the sync script to update notebooks:

```bash
cd resources
./sync-notebooks.sh
```

## 📁 Repository Structure

```
dynamo-grove-brev/
├── 01-dynamo-deployment-guide.md/.ipynb      # Guide 1: Deployment
├── 02-monitoring-and-observability.md/.ipynb # Guide 2: Monitoring
├── 03-grove-distributed-serving.md/.ipynb    # Guide 3: Grove
├── oneshot.sh                                # Bootstrap script
├── resources/                                # Supporting files
│   ├── run-benchmark.sh                      # AI-Perf benchmark wrapper
│   ├── dynamo-inference-dashboard.json       # Grafana dashboard (Dynamo metrics)
│   ├── nats-overview-dashboard.json          # Grafana dashboard (NATS metrics)
│   ├── disagg_router.yaml                    # Example deployment config
│   ├── sync-notebooks.sh                     # Markdown to notebook sync
│   ├── NOTEBOOK-WORKFLOW.md                  # Development workflow
│   └── QUICK-REFERENCE.md                    # Quick command reference
└── README.md                                 # This file
```

## 🔧 Troubleshooting

### Jupyter Issues

```bash
# If notebooks don't open, ensure Jupyter is installed
pip install jupyterlab jupytext

# Launch Jupyter
jupyter lab
```

### Kubernetes Issues

```bash
# Verify cluster is running
kubectl get nodes
kubectl get pods -A

# Check GPU availability
kubectl get nodes -o json | jq '.items[].status.allocatable | ."nvidia.com/gpu"'
```

### NGC Authentication

```bash
# Login to NGC
helm registry login nvcr.io
# Username: $oauthtoken
# Password: <your-ngc-api-key>

# Create pull secret for pods
kubectl create secret docker-registry ngc-secret \
  --docker-server=nvcr.io \
  --docker-username='$oauthtoken' \
  --docker-password=<your-ngc-api-key> \
  --namespace dynamo
```

### Grafana Access

Grafana is exposed via NodePort on the cluster. The notebooks will show you how to access it at `https://grafana0-{hostname}.brevlab.com/` (or your cluster's equivalent).

## 📚 Resources

- **Dynamo Documentation**: https://docs.nvidia.com/dynamo/latest/
- **Dynamo GitHub**: https://github.com/ai-dynamo/dynamo
- **NGC Catalog**: https://catalog.ngc.nvidia.com/
- **AI-Perf**: https://github.com/ai-dynamo/aiperf

## 💡 Tips

- **Start with Guide 1**: Sets up the foundation for all subsequent guides
- **Run benchmarks in terminals**: Use `resources/run-benchmark.sh` to avoid crashing notebook kernels
- **Use markdown for editing**: Better version control and easier collaboration
- **Reload notebooks after sync**: Ensure you're running the latest version
- **Check logs with kubectl**: Essential for troubleshooting deployment issues
- **Monitor resource usage**: Keep an eye on GPU memory and CPU utilization

## 🤝 Contributing

Contributions are welcome! To maintain consistency:

1. Edit the `.md` files (not `.ipynb`)
2. Run `./resources/sync-notebooks.sh` to update notebooks
3. Test your changes in Jupyter
4. Submit a pull request

See `resources/NOTEBOOK-WORKFLOW.md` for development guidelines.

## 📄 License

These guides are provided as-is for learning and deploying Dynamo on Kubernetes.

---

**Happy learning! 🚀**
