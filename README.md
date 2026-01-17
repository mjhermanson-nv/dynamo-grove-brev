# Dynamo on Brev

Interactive Jupyter notebooks for learning and deploying NVIDIA Dynamo on Kubernetes. These guides walk you through deploying high-performance LLM inference workloads with monitoring and observability.

## 📚 Guides

### 01 - Dynamo Deployment Guide
**File**: `01-dynamo-deployment-guide.ipynb`

Deploy and manage LLM inference workloads using Dynamo on Kubernetes:
- Set up NGC and HuggingFace credentials
- Install Dynamo platform with cluster-wide operator
- Deploy disaggregated serving architecture (separate prefill/decode workers)
- Test deployment with OpenAI-compatible API
- Benchmark performance with AI-Perf

**Duration**: ~90 minutes

### 02 - Monitoring and Observability
**File**: `02-monitoring-and-observability.ipynb`

Monitor your Dynamo deployments with Prometheus and Grafana:
- Verify cluster-wide Grafana and Prometheus installation
- Configure PodMonitors for Dynamo metrics collection
- Deploy and view Dynamo inference dashboard
- Generate load and analyze performance metrics
- Understand key metrics: TTFT, inter-token latency, throughput
- Create custom Prometheus alerts

**Duration**: ~20 minutes

### 03 - Distributed Serving with Grove
**File**: `03-grove-distributed-serving.ipynb`

Learn distributed serving concepts with Grove:
- Understand Grove architecture and multi-frontend load balancing
- Deploy distributed coordination infrastructure (NATS, etcd)
- Create Grove-enabled Dynamo deployments with NATS discovery
- Monitor NATS and etcd with Grafana dashboards
- Generate traffic and analyze distributed metrics
- Understand single-node vs multi-node trade-offs
- Learn when to use Grove in production

**Duration**: ~45 minutes  
**Note**: Teaches distributed systems concepts using a single-node setup for learning

## 🚀 Quick Start

### Prerequisites

- A Kubernetes cluster with GPU support (tested on Brev with 2x L40s GPUs)
- Access to NVIDIA NGC (for Dynamo Helm charts and container images)
- Access to HuggingFace (for model downloads)

### Bootstrap from Scratch

Use the included bootstrap script to set up everything:

```bash
# Clone the repository
git clone https://github.com/mjhermanson-nv/dynamo-grove-brev.git
cd dynamo-grove-brev

# Run the bootstrap (installs microk8s, kubectl, helm, k9s, GPU operator, storage, monitoring)
sudo ./oneshot.sh

# Start Jupyter Lab
jupyter lab
```

The bootstrap script installs:
- Kubernetes (microk8s)
- Essential CLI tools (kubectl, helm, k9s)
- NVIDIA GPU operator
- Storage provisioning (local-path)
- Prometheus & Grafana (cluster-wide monitoring)

Once complete, open `01-dynamo-deployment-guide.ipynb` to begin.

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

## 🎯 What You'll Learn

### Guide 1 Skills
- Kubernetes fundamentals for ML workloads
- NGC authentication and container image access
- Dynamo platform installation and CRDs
- Disaggregated serving architecture (prefill/decode separation)
- OpenAI-compatible API testing
- Performance benchmarking with AI-Perf

### Guide 2 Skills
- Prometheus metrics collection with PodMonitors
- Grafana dashboard deployment and configuration
- Key LLM inference metrics: TTFT, ITL, throughput
- Performance monitoring and analysis
- Prometheus alerting rules
- Load generation and metric visualization

### Guide 3 Skills
- Distributed systems architecture patterns
- NATS message bus and pub/sub patterns
- etcd coordination and service discovery
- Multi-frontend load balancing strategies
- NIXL distributed KV cache system
- Grove-enabled deployment configuration
- Real-time distributed metrics analysis
- Multi-node serving strategies and trade-offs

## 🏗️ Architecture Patterns

### Disaggregated Serving (Guide 1)
- Separate prefill and decode workers
- Maximum throughput and resource efficiency
- Scales prefill and decode independently
- Deployed using DynamoGraphDeployment CRD

### Monitoring Stack (Guide 2)
- Cluster-wide Prometheus for metrics collection
- Grafana for visualization and dashboards
- PodMonitors for automatic service discovery
- Pre-configured dashboards for Dynamo inference metrics

### Distributed Serving (Guide 3)
- NATS message bus for request routing and cache sharing
- etcd for service discovery and coordination
- Multi-frontend load balancing with Kubernetes Services
- NIXL distributed KV cache across workers
- Optimized for multi-node deployments

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
