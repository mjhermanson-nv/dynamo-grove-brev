# Dynamo on Brev

Interactive Jupyter notebooks for learning and deploying NVIDIA Dynamo on Kubernetes. These guides walk you through deploying high-performance LLM inference workloads with monitoring and observability.

## 📚 Guides

### 01 - Dynamo Deployment Guide
**File**: `01-dynamo-deployment-guide.ipynb`

Learn how to deploy and manage LLM inference workloads using Dynamo on Kubernetes:
- Set up your Kubernetes environment
- Configure NGC and HuggingFace credentials
- Install Dynamo platform and CRDs
- Deploy disaggregated serving architectures (separate prefill/decode workers)
- Perform rolling updates and horizontal scaling
- Run benchmarks with AI-Perf

**Duration**: ~90 minutes

### 02 - Monitoring and Observability
**File**: `02-monitoring-and-observability.ipynb`

Set up monitoring and observability for your Dynamo deployments:
- Access cluster-wide Grafana and Prometheus
- Configure PodMonitors for metrics collection
- Import and view Dynamo inference dashboards
- Analyze key metrics (TTFT, inter-token latency, throughput)
- Create custom Prometheus queries and alerts

**Duration**: ~20 minutes

### 03 - Distributed Serving with Grove
**File**: `03-grove-distributed-serving.ipynb`

Learn distributed serving concepts with Grove:
- Understand Grove architecture (NATS, etcd, NIXL)
- Deploy distributed coordination infrastructure
- Create Grove-enabled Dynamo deployments
- Monitor NATS and etcd with Grafana dashboards
- Generate traffic and observe distributed metrics
- Understand single-node vs multi-node trade-offs
- Learn when to use Grove in production

**Duration**: ~45 minutes  
**Note**: Teaches distributed systems concepts using a single-node setup for learning

## 🚀 Quick Start

### Prerequisites

- A Kubernetes cluster with GPU support (tested on Brev with 2x L40s GPUs)
- Access to NVIDIA NGC (for Dynamo Helm charts and container images)
- Access to HuggingFace (for model downloads)

### Option 1: Bootstrap from Scratch

Use the included bootstrap script to set up everything:

```bash
# Clone the repository
git clone https://github.com/mjhermanson-nv/dynamo-grove-brev.git
cd dynamo-grove-brev

# Run the bootstrap (installs microk8s, kubectl, helm, k9s, GPU operator, storage, monitoring)
sudo ./oneshot.sh
```

The bootstrap script installs:
- Kubernetes (microk8s)
- Essential CLI tools (kubectl, helm, k9s)
- NVIDIA GPU operator
- Storage provisioning (local-path)
- Prometheus & Grafana (cluster-wide monitoring)

### Option 2: Use an Existing Cluster

If you already have a Kubernetes cluster with GPU support, you can jump straight into the workshops:

```bash
# Start with the first notebook
jupyter lab 01-dynamo-deployment-guide.ipynb
```

## 📖 Workshop Structure

Each workshop is provided in two formats:
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
├── 03-grove-distributed-serving.md/.ipynb    # Guide 3: Grove (optional)
├── oneshot.sh                                # Bootstrap script
├── resources/                                # Supporting files
│   ├── run-benchmark.sh                      # AI-Perf benchmark wrapper
│   ├── dynamo-inference-dashboard.json       # Grafana dashboard (Dynamo metrics)
│   ├── nats-overview-dashboard.json          # Grafana dashboard (NATS metrics)
│   ├── disagg_router.yaml                    # Example deployment config
│   ├── sync-notebooks.sh                     # Markdown to notebook sync
│   ├── NOTEBOOK-WORKFLOW.md                  # Development workflow
│   └── QUICK-REFERENCE.md                    # Quick command reference
└── examples/                                 # Additional examples
```

## 🎯 What You'll Learn

### Guide 1 Skills
- Kubernetes fundamentals for ML workloads
- Dynamo architecture and components
- Disaggregated serving patterns
- Deployment strategies (rolling updates, scaling)
- Performance benchmarking with AI-Perf

### Guide 2 Skills
- Prometheus metrics collection and querying
- Grafana dashboard creation and analysis
- Key LLM inference metrics (TTFT, ITL, throughput)
- Performance monitoring and alerting
- Troubleshooting inference workloads

### Guide 3 Skills (Optional)
- Distributed systems architecture (NATS, etcd, message bus patterns)
- NATS message bus and etcd coordination
- NIXL distributed KV cache system
- Grove-enabled deployment configuration
- Real-time metrics analysis with Prometheus/Grafana
- Multi-node serving strategies
- Production scaling considerations

## 🏗️ Architecture Patterns

### Aggregated Serving
- Single worker handles both prefill and decode
- Simple setup, good for development
- Lower resource requirements

### Disaggregated Serving
- Separate prefill and decode workers
- Maximum throughput and resource efficiency
- Scales prefill and decode independently
- Covered in Workshop 1

### Monitoring Stack
- Cluster-wide Prometheus for metrics collection
- Grafana for visualization and dashboards
- PodMonitors for automatic discovery
- Covered in Workshop 2

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
- **AI-Perf**: https://github.com/triton-inference-server/perf_analyzer

## 💡 Tips

- **Start with Workshop 1**: It sets up the foundation for Workshop 2
- **Run benchmarks in terminals**: Heavy workloads can crash notebook kernels
- **Use markdown for editing**: Better version control and easier collaboration
- **Keep notebooks clean**: Restart kernel and clear outputs before committing
- **Check logs**: Use `kubectl logs` to troubleshoot deployment issues

## 🤝 Contributing

Contributions are welcome! To maintain consistency:

1. Edit the `.md` files (not `.ipynb`)
2. Run `./resources/sync-notebooks.sh` to update notebooks
3. Test your changes in Jupyter
4. Submit a pull request

See `resources/NOTEBOOK-WORKFLOW.md` for development guidelines.

## 📄 License

This workshop is provided as-is for learning and deploying Dynamo on Kubernetes.

---

**Happy learning! 🚀**
