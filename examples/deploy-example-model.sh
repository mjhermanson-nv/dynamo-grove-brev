#!/bin/bash
set -e

# Example: Deploy a non-gated model with Dynamo using TensorRT-LLM backend
# This script demonstrates deploying Qwen2.5-0.5B (small, fast, no auth required)
# TensorRT-LLM provides optimized inference performance but requires engine compilation

export NAMESPACE=dynamo-system
export MODEL_NAME="qwen2.5-0.5b-example"
export FRONTEND_SERVICE="${MODEL_NAME}-frontend"

echo "🚀 Dynamo Model Deployment Tutorial"
echo "===================================="
echo ""
echo "This script will deploy Qwen2.5-0.5B using TensorRT-LLM backend"
echo "Model: Qwen/Qwen2.5-0.5B-Instruct (non-gated, no token needed)"
echo "Backend: TensorRT-LLM (optimized inference performance)"
echo ""

# Check prerequisites
if ! command -v kubectl >/dev/null 2>&1; then
    echo "❌ kubectl not found. Please ensure Kubernetes is set up."
    exit 1
fi

if ! kubectl get namespace ${NAMESPACE} >/dev/null 2>&1; then
    echo "❌ Namespace ${NAMESPACE} not found."
    echo "   Please run ./install-dynamo.sh first to install Dynamo."
    exit 1
fi

# Check if Dynamo is ready
if ! kubectl get crd dynamographdeployments.nvidia.com >/dev/null 2>&1; then
    echo "❌ Dynamo CRDs not found. Please install Dynamo first: ./install-dynamo.sh"
    exit 1
fi

# Check for NGC image pull secret (should have been created by install-dynamo.sh)
echo "Step 1: Checking NGC image pull secret..."
if ! kubectl get secret ngc-registry-secret -n ${NAMESPACE} >/dev/null 2>&1; then
    echo "❌ NGC image pull secret not found!"
    echo ""
    echo "The secret should have been created by install-dynamo.sh."
    echo "Please run ./install-dynamo.sh first, or create it manually:"
    echo ""
    echo "  kubectl create secret docker-registry ngc-registry-secret \\"
    echo "    --docker-server=nvcr.io \\"
    echo "    --docker-username=\$oauthtoken \\"
    echo "    --docker-password=<your-ngc-api-key> \\"
    echo "    --docker-email=<your-email> \\"
    echo "    -n ${NAMESPACE}"
    echo ""
    echo "  kubectl patch serviceaccount default -n ${NAMESPACE} \\"
    echo "    -p '{\"imagePullSecrets\":[{\"name\":\"ngc-registry-secret\"}]}'"
    echo ""
    exit 1
else
    echo "✓ NGC image pull secret found (created by install-dynamo.sh)"
fi

echo ""
echo "Step 2: Creating DynamoGraphDeployment..."
echo ""

# Create the deployment YAML
# Note: imagePullSecrets are handled via service account patch above
cat <<EOF | kubectl apply -f -
apiVersion: nvidia.com/v1alpha1
kind: DynamoGraphDeployment
metadata:
  name: ${MODEL_NAME}
  namespace: ${NAMESPACE}
spec:
  services:
    Frontend:
      dynamoNamespace: ${MODEL_NAME}
      componentType: frontend
      replicas: 1
      extraPodSpec:
        mainContainer:
          image: nvcr.io/nvidia/dynamo/dynamo-runtime:latest
          resources:
            requests:
              memory: "2Gi"
            limits:
              memory: "4Gi"
    
    TrtllmDecodeWorker:
      dynamoNamespace: ${MODEL_NAME}
      componentType: worker
      replicas: 1
      resources:
        requests:
          gpu: "1"
          memory: "8Gi"
        limits:
          gpu: "1"
          memory: "16Gi"
      extraPodSpec:
        mainContainer:
          image: nvcr.io/nvidia/dynamo/dynamo-runtime:latest
          command: ["python3", "-m", "dynamo.trtllm"]
          args:
            - --model-path
            - Qwen/Qwen2.5-0.5B-Instruct
            - --served-model-name
            - Qwen/Qwen2.5-0.5B-Instruct
            - --trust-remote-code
          env:
            - name: CUDA_VISIBLE_DEVICES
              value: "0"
EOF

echo "✓ Deployment created"
echo ""

echo "Step 3: Waiting for deployment to be ready..."
echo "This may take a few minutes (model download + startup)..."
echo ""

# Wait for frontend to be ready
echo "Waiting for frontend service..."
kubectl wait --for=condition=available --timeout=600s deployment/${MODEL_NAME}-frontend -n ${NAMESPACE} || {
    echo "⚠️  Frontend deployment timeout. Checking status..."
    kubectl get pods -n ${NAMESPACE} -l app=${MODEL_NAME}
}

# Wait for worker to be ready
echo "Waiting for worker pod..."
echo "Note: TensorRT-LLM may take longer to start (engine compilation)..."
kubectl wait --for=condition=ready --timeout=900s pod -l app=${MODEL_NAME}-worker -n ${NAMESPACE} || {
    echo "⚠️  Worker pod timeout. Checking status..."
    kubectl get pods -n ${NAMESPACE} -l app=${MODEL_NAME}-worker
    echo ""
    echo "TensorRT-LLM engine compilation can take 5-15 minutes depending on model size."
    echo "Check progress with:"
    echo "  kubectl logs -n ${NAMESPACE} -l app=${MODEL_NAME}-worker --tail=50 -f"
}

echo ""
echo "Step 4: Checking deployment status..."
echo ""

kubectl get dynamoGraphDeployment ${MODEL_NAME} -n ${NAMESPACE}
echo ""
kubectl get pods -n ${NAMESPACE} -l app=${MODEL_NAME}
echo ""

# Check if services are ready
if kubectl get svc ${FRONTEND_SERVICE} -n ${NAMESPACE} >/dev/null 2>&1; then
    echo "✓ Frontend service is ready"
else
    echo "⚠️  Frontend service not found yet"
fi

echo ""
echo "Step 5: Testing the deployment..."
echo ""

# Get the service
FRONTEND_PORT=$(kubectl get svc ${FRONTEND_SERVICE} -n ${NAMESPACE} -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || echo "8000")

echo "To test the deployment, run in another terminal:"
echo ""
echo "  # Port forward to the frontend"
echo "  kubectl port-forward svc/${FRONTEND_SERVICE} 8000:${FRONTEND_PORT} -n ${NAMESPACE}"
echo ""
echo "  # Then test the API (in another terminal):"
echo "  curl http://localhost:8000/v1/models"
echo ""
echo "  # Or test chat completion:"
echo "  curl http://localhost:8000/v1/chat/completions \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{"
echo "      \"model\": \"Qwen/Qwen2.5-0.5B-Instruct\","
echo "      \"messages\": [{\"role\": \"user\", \"content\": \"Hello!\"}],"
echo "      \"max_tokens\": 100"
echo "    }'"
echo ""

echo "Step 6: Monitoring..."
echo ""
echo "Useful commands:"
echo "  # Watch pods:"
echo "  kubectl get pods -n ${NAMESPACE} -l app=${MODEL_NAME} -w"
echo ""
echo "  # View frontend logs:"
echo "  kubectl logs -n ${NAMESPACE} -l app=${MODEL_NAME}-frontend --tail=50 -f"
echo ""
echo "  # View worker logs:"
echo "  kubectl logs -n ${NAMESPACE} -l app=${MODEL_NAME}-worker --tail=50 -f"
echo ""
echo "  # Check deployment status:"
echo "  kubectl describe dynamoGraphDeployment ${MODEL_NAME} -n ${NAMESPACE}"
echo ""

echo "Step 7: Cleanup (when done testing)..."
echo ""
echo "To delete this deployment:"
echo "  kubectl delete dynamoGraphDeployment ${MODEL_NAME} -n ${NAMESPACE}"
echo ""

echo "✅ Tutorial complete!"
echo ""
echo "📚 Next steps:"
echo "  - Try deploying with more GPUs (increase replicas)"
echo "  - Try disaggregated serving for higher throughput"
echo "  - Experiment with different models"
echo "  - TensorRT-LLM provides best performance but requires engine compilation"
echo "  - For faster startup, consider vLLM or SGLang backends"
echo "  - Check out examples at: https://github.com/ai-dynamo/dynamo/tree/main/examples/backends"
echo ""

