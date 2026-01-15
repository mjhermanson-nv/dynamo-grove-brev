#!/bin/bash
set -e

# Detect Brev user (handles ubuntu, nvidia, shadeform, etc.)
detect_brev_user() {
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        echo "$SUDO_USER"
        return
    fi
    for user_home in /home/*; do
        username=$(basename "$user_home")
        [ "$username" = "launchpad" ] && continue
        if ls "$user_home"/.lifecycle-script-ls-*.log 2>/dev/null | grep -q . || \
           [ -f "$user_home/.verb-setup.log" ] || \
           { [ -L "$user_home/.cache" ] && [ "$(readlink "$user_home/.cache")" = "/ephemeral/cache" ]; }; then
            echo "$username"
            return
        fi
    done
    [ -d "/home/nvidia" ] && echo "nvidia" && return
    [ -d "/home/ubuntu" ] && echo "ubuntu" && return
    echo "ubuntu"
}

if [ "$(id -u)" -eq 0 ] || [ "${USER:-}" = "root" ]; then
    DETECTED_USER=$(detect_brev_user)
    export USER="$DETECTED_USER"
    export HOME="/home/$DETECTED_USER"
fi

echo "☸️  Setting up Kubernetes with Dynamo + Grove..."
echo "User: $USER"

# Install microk8s
echo "Installing microk8s..."
sudo snap install microk8s --classic

# Add user to group
sudo usermod -a -G microk8s $USER

# Create .kube directory if it doesn't exist and fix permissions
mkdir -p ~/.kube
if [ "$(id -u)" -eq 0 ]; then
    chown -R $USER:$USER ~/.kube
fi

# Wait for microk8s to be ready
echo "Waiting for microk8s..."
sudo microk8s status --wait-ready

# Enable essential addons
echo "Enabling addons..."
sudo microk8s enable dns
sudo microk8s enable nvidia  # NVIDIA GPU operator (Brev has NVIDIA drivers)

# Export kubeconfig so kubectl works without group membership
echo "Configuring kubectl access..."
sudo microk8s config > ~/.kube/config
chmod 600 ~/.kube/config

# Fix ownership if running as root
if [ "$(id -u)" -eq 0 ]; then
    chown $USER:$USER ~/.kube/config
fi

# Add KUBECONFIG to shell configs if not already there
for shell_config in ~/.bashrc ~/.zshrc; do
    if [ -f "$shell_config" ] && ! grep -q "KUBECONFIG.*kube/config" "$shell_config"; then
        echo "" >> "$shell_config"
        echo "# Kubernetes config" >> "$shell_config"
        echo "export KUBECONFIG=\$HOME/.kube/config" >> "$shell_config"

        # Fix ownership if running as root
        if [ "$(id -u)" -eq 0 ]; then
            chown $USER:$USER "$shell_config"
        fi
    fi
done

# Export for current session
export KUBECONFIG=$HOME/.kube/config

# Remove any existing snap alias (it requires group membership)
sudo snap unalias kubectl 2>/dev/null || true

# Install standalone kubectl (works without group membership!)
echo "Installing standalone kubectl..."
KUBECTL_VERSION=$(curl -fsSL https://dl.k8s.io/release/stable.txt | head -n 1 | tr -d '\r\n')
if [ -z "$KUBECTL_VERSION" ] || ! echo "$KUBECTL_VERSION" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "Unexpected kubectl version: $KUBECTL_VERSION" >&2
    exit 1
fi
curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" -o /tmp/kubectl
chmod +x /tmp/kubectl
sudo mv /tmp/kubectl /usr/local/bin/kubectl
echo "✓ kubectl installed to /usr/local/bin/kubectl"

# Install standalone helm (works without group membership!)
echo "Installing standalone helm..."
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
echo "✓ helm installed to /usr/local/bin/helm"

# Install k9s for terminal UI
echo "Installing k9s..."
cd /tmp
wget -q https://github.com/derailed/k9s/releases/latest/download/k9s_Linux_amd64.tar.gz -O /tmp/k9s_Linux_amd64.tar.gz
tar -xzf /tmp/k9s_Linux_amd64.tar.gz -C /tmp
sudo chmod +x /tmp/k9s
sudo mv /tmp/k9s /usr/local/bin/
rm -f /tmp/k9s_Linux_amd64.tar.gz /tmp/LICENSE /tmp/README.md 2>/dev/null || true
cd - > /dev/null

# Install local-path-provisioner for PersistentVolumeClaims
echo "Installing local-path storage provisioner..."
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.24/deploy/local-path-storage.yaml

# Wait for provisioner to be ready
echo "Waiting for storage provisioner..."
kubectl wait --for=condition=available --timeout=60s deployment/local-path-provisioner -n local-path-storage

# Set as default storage class
kubectl patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
echo "✓ Storage provisioner installed and set as default"

# Install monitoring stack (Prometheus + Grafana)
echo ""
echo "Installing monitoring stack (Prometheus + Grafana)..."

kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

echo "Adding Helm repos for monitoring..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

if command -v openssl >/dev/null 2>&1; then
    GRAFANA_ADMIN_PASSWORD=$(openssl rand -base64 18 | tr -d '=+/')
else
    GRAFANA_ADMIN_PASSWORD="admin-$(date +%s)"
fi

cat <<EOF >/tmp/kube-prometheus-stack-values.yaml
grafana:
  enabled: true
  adminPassword: "${GRAFANA_ADMIN_PASSWORD}"
  service:
    type: NodePort
    nodePort: 30080
  sidecar:
    dashboards:
      enabled: true
      label: grafana_dashboard
      searchNamespace: monitoring
  additionalDataSources:
    - name: Prometheus
      type: prometheus
      uid: prometheus
      url: http://kube-prometheus-stack-prometheus.monitoring.svc:9090
      access: proxy
      isDefault: true
EOF

echo "Installing kube-prometheus-stack..."
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
    -n monitoring \
    -f /tmp/kube-prometheus-stack-values.yaml \
    --wait

echo "Provisioning Grafana dashboards..."
kubectl apply -n monitoring -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-cluster-overview
  labels:
    grafana_dashboard: "1"
data:
  cluster-overview.json: |
    {
      "annotations": {
        "list": [
          {
            "builtIn": 1,
            "datasource": "-- Grafana --",
            "enable": true,
            "hide": true,
            "iconColor": "rgba(0, 211, 255, 1)",
            "name": "Annotations & Alerts",
            "type": "dashboard"
          }
        ]
      },
      "panels": [
        {
          "type": "stat",
          "title": "Nodes",
          "datasource": { "type": "prometheus", "uid": "prometheus" },
          "targets": [{ "expr": "count(kube_node_info)", "refId": "A" }],
          "gridPos": { "h": 4, "w": 6, "x": 0, "y": 0 }
        },
        {
          "type": "stat",
          "title": "Pods",
          "datasource": { "type": "prometheus", "uid": "prometheus" },
          "targets": [{ "expr": "count(kube_pod_info)", "refId": "A" }],
          "gridPos": { "h": 4, "w": 6, "x": 6, "y": 0 }
        },
        {
          "type": "stat",
          "title": "CPU Usage (cores)",
          "datasource": { "type": "prometheus", "uid": "prometheus" },
          "targets": [
            {
              "expr": "sum(rate(container_cpu_usage_seconds_total{job=\"kubelet\",image!=\"\"}[5m]))",
              "refId": "A"
            }
          ],
          "gridPos": { "h": 4, "w": 6, "x": 12, "y": 0 }
        },
        {
          "type": "stat",
          "title": "Memory Usage (bytes)",
          "datasource": { "type": "prometheus", "uid": "prometheus" },
          "targets": [
            {
              "expr": "sum(container_memory_working_set_bytes{job=\"kubelet\",image!=\"\"})",
              "refId": "A"
            }
          ],
          "gridPos": { "h": 4, "w": 6, "x": 18, "y": 0 }
        },
        {
          "type": "timeseries",
          "title": "CPU Usage by Node",
          "datasource": { "type": "prometheus", "uid": "prometheus" },
          "targets": [
            { "expr": "sum(rate(node_cpu_seconds_total{mode!=\"idle\"}[5m])) by (instance)", "refId": "A" }
          ],
          "gridPos": { "h": 8, "w": 24, "x": 0, "y": 4 }
        }
      ],
      "schemaVersion": 36,
      "title": "Kubernetes Cluster Overview",
      "version": 1,
      "refresh": "30s",
      "timezone": "browser"
    }
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-nats
  labels:
    grafana_dashboard: "1"
data:
  nats.json: |
    {
      "annotations": { "list": [] },
      "panels": [
        {
          "type": "stat",
          "title": "Connections",
          "datasource": { "type": "prometheus", "uid": "prometheus" },
          "targets": [{ "expr": "nats_varz_connections", "refId": "A" }],
          "gridPos": { "h": 4, "w": 6, "x": 0, "y": 0 }
        },
        {
          "type": "stat",
          "title": "In Msgs",
          "datasource": { "type": "prometheus", "uid": "prometheus" },
          "targets": [{ "expr": "nats_varz_in_msgs", "refId": "A" }],
          "gridPos": { "h": 4, "w": 6, "x": 6, "y": 0 }
        },
        {
          "type": "stat",
          "title": "Out Msgs",
          "datasource": { "type": "prometheus", "uid": "prometheus" },
          "targets": [{ "expr": "nats_varz_out_msgs", "refId": "A" }],
          "gridPos": { "h": 4, "w": 6, "x": 12, "y": 0 }
        },
        {
          "type": "stat",
          "title": "CPU (%)",
          "datasource": { "type": "prometheus", "uid": "prometheus" },
          "targets": [{ "expr": "nats_server_cpu", "refId": "A" }],
          "gridPos": { "h": 4, "w": 6, "x": 18, "y": 0 }
        },
        {
          "type": "timeseries",
          "title": "Message Rate",
          "datasource": { "type": "prometheus", "uid": "prometheus" },
          "targets": [
            { "expr": "rate(nats_varz_in_msgs[5m])", "refId": "A" },
            { "expr": "rate(nats_varz_out_msgs[5m])", "refId": "B" }
          ],
          "gridPos": { "h": 8, "w": 24, "x": 0, "y": 4 }
        }
      ],
      "schemaVersion": 36,
      "title": "NATS Overview",
      "version": 1,
      "refresh": "30s",
      "timezone": "browser"
    }
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-etcd
  labels:
    grafana_dashboard: "1"
data:
  etcd.json: |
    {
      "annotations": { "list": [] },
      "panels": [
        {
          "type": "stat",
          "title": "Has Leader",
          "datasource": { "type": "prometheus", "uid": "prometheus" },
          "targets": [{ "expr": "max(etcd_server_has_leader)", "refId": "A" }],
          "gridPos": { "h": 4, "w": 6, "x": 0, "y": 0 }
        },
        {
          "type": "stat",
          "title": "DB Size (bytes)",
          "datasource": { "type": "prometheus", "uid": "prometheus" },
          "targets": [{ "expr": "max(etcd_mvcc_db_total_size_in_bytes)", "refId": "A" }],
          "gridPos": { "h": 4, "w": 6, "x": 6, "y": 0 }
        },
        {
          "type": "timeseries",
          "title": "Proposals Committed",
          "datasource": { "type": "prometheus", "uid": "prometheus" },
          "targets": [
            { "expr": "rate(etcd_server_proposals_committed_total[5m])", "refId": "A" }
          ],
          "gridPos": { "h": 8, "w": 24, "x": 0, "y": 4 }
        }
      ],
      "schemaVersion": 36,
      "title": "etcd Overview",
      "version": 1,
      "refresh": "30s",
      "timezone": "browser"
    }
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-dynamo-operator
  labels:
    grafana_dashboard: "1"
data:
  dynamo-operator.json: |
    {
      "annotations": { "list": [] },
      "panels": [
        {
          "type": "text",
          "title": "Notes",
          "options": {
            "content": "This dashboard uses controller-runtime metrics. If you have custom Dynamo metrics, update the queries accordingly.",
            "mode": "markdown"
          },
          "gridPos": { "h": 4, "w": 24, "x": 0, "y": 0 }
        },
        {
          "type": "timeseries",
          "title": "Reconciles (total)",
          "datasource": { "type": "prometheus", "uid": "prometheus" },
          "targets": [
            { "expr": "sum(rate(controller_runtime_reconcile_total{job=~\".*dynamo.*\"}[5m]))", "refId": "A" }
          ],
          "gridPos": { "h": 8, "w": 24, "x": 0, "y": 4 }
        },
        {
          "type": "timeseries",
          "title": "Reconcile Errors",
          "datasource": { "type": "prometheus", "uid": "prometheus" },
          "targets": [
            { "expr": "sum(rate(controller_runtime_reconcile_errors_total{job=~\".*dynamo.*\"}[5m]))", "refId": "A" }
          ],
          "gridPos": { "h": 8, "w": 24, "x": 0, "y": 12 }
        },
        {
          "type": "timeseries",
          "title": "Workqueue Depth",
          "datasource": { "type": "prometheus", "uid": "prometheus" },
          "targets": [
            { "expr": "sum(workqueue_depth{name=~\".*dynamo.*\"})", "refId": "A" }
          ],
          "gridPos": { "h": 8, "w": 24, "x": 0, "y": 20 }
        }
      ],
      "schemaVersion": 36,
      "title": "Dynamo Operator",
      "version": 1,
      "refresh": "30s",
      "timezone": "browser"
    }
EOF

# Wait for Grafana to be ready
kubectl wait --for=condition=available --timeout=180s deployment/kube-prometheus-stack-grafana -n monitoring

# Final permission fix for any files created by microk8s
if [ "$(id -u)" -eq 0 ] && [ -d "$HOME/.kube" ]; then
    chown -R $USER:$USER "$HOME/.kube" 2>/dev/null || true
fi

# Verify (without sudo - should work now!)
echo ""
echo "Verifying installation..."
sudo microk8s status

# Show which binaries we're using
echo ""
echo "kubectl binary: $(which kubectl)"
echo "helm binary: $(which helm)"

# Test kubectl
export KUBECONFIG=$HOME/.kube/config
kubectl version --client
echo ""
echo "Testing cluster access..."
kubectl get nodes 2>/dev/null && echo "✓ kubectl can access cluster without group membership!" || echo "⚠️  kubectl will work after sourcing shell config"

# Test helm
echo ""
echo "Testing helm..."
helm version --short 2>/dev/null && echo "✓ helm is ready!" || echo "⚠️  helm will work after sourcing shell config"

# Verify storage class
echo ""
echo "Verifying storage class..."
kubectl get storageclass

echo ""
echo "✅ Kubernetes ready for Dynamo + Grove!"
echo ""
echo "Kubeconfig: ~/.kube/config"
echo ""
echo "Quick start (works immediately!):"
echo "  kubectl get nodes"
echo "  kubectl get pods -A"
echo "  kubectl get storageclass"
echo "  helm version"
echo "  k9s"
echo ""
echo "💡 How it works:"
echo "  - kubectl, helm, k9s are standalone binaries (/usr/local/bin/)"
echo "  - Use ~/.kube/config automatically"
echo "  - Storage provisioner ready for Dynamo/Grove PVCs"
echo "  - Grafana available via NodePort on 30080"
echo "  - No group membership needed!"
echo "  - No 'newgrp' or logout required!"
echo ""
echo "Grafana access:"
echo "  URL: http://<node-ip>:30080"
echo "  User: admin"
echo "  Password: $GRAFANA_ADMIN_PASSWORD"
echo "  Hint: get node IPs with 'kubectl get nodes -o wide'"
echo ""
echo "Next steps:"
echo "  1. Set up NGC authentication (required for Dynamo):"
echo "     helm registry login nvcr.io"
echo ""
echo "  2. Install Dynamo + Grove:"
echo "     ./install-dynamo.sh"
echo ""
echo "  3. Or follow the README.md for detailed instructions"
echo ""