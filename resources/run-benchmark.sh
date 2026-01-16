#!/bin/bash
# run-benchmark.sh - Run aiperf benchmarks against Dynamo deployment
#
# Usage:
#   ./run-benchmark.sh baseline      # Low concurrency (1, 100 requests)
#   ./run-benchmark.sh high          # High concurrency (4, 200 requests)
#   ./run-benchmark.sh rate          # Request rate (10 rps, 200 requests)

set -e

# Get node IP
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

if [ -z "$NODE_IP" ]; then
    echo "Error: Could not get node IP"
    exit 1
fi

FRONTEND_URL="http://$NODE_IP:30100"
MODEL="Qwen/Qwen2.5-1.5B-Instruct"

# Check if aiperf is installed
if ! command -v aiperf &> /dev/null; then
    echo "Error: aiperf is not installed"
    echo "Install it with: pip install aiperf"
    exit 1
fi

case "${1:-baseline}" in
    baseline)
        echo "=========================================="
        echo "Running BASELINE benchmark"
        echo "Concurrency: 1, Requests: 100"
        echo "URL: $FRONTEND_URL"
        echo "=========================================="
        echo ""
        
        aiperf profile \
            --log-level warning \
            --model "$MODEL" \
            --url "$FRONTEND_URL" \
            --endpoint-type chat \
            --streaming \
            --concurrency 1 \
            --request-count 100
        ;;
        
    high)
        echo "=========================================="
        echo "Running HIGH CONCURRENCY benchmark"
        echo "Concurrency: 4, Requests: 200"
        echo "URL: $FRONTEND_URL"
        echo "=========================================="
        echo ""
        
        aiperf profile \
            --log-level warning \
            --model "$MODEL" \
            --url "$FRONTEND_URL" \
            --endpoint-type chat \
            --streaming \
            --concurrency 4 \
            --request-count 200
        ;;
        
    rate)
        echo "=========================================="
        echo "Running REQUEST RATE benchmark"
        echo "Rate: 10 rps, Requests: 200"
        echo "URL: $FRONTEND_URL"
        echo "=========================================="
        echo ""
        
        aiperf profile \
            --log-level warning \
            --model "$MODEL" \
            --url "$FRONTEND_URL" \
            --endpoint-type chat \
            --streaming \
            --request-rate 10 \
            --request-count 200
        ;;
        
    *)
        echo "Usage: $0 {baseline|high|rate}"
        echo ""
        echo "  baseline  - Low concurrency benchmark (1 concurrent, 100 requests)"
        echo "  high      - High concurrency benchmark (4 concurrent, 200 requests)"
        echo "  rate      - Request rate benchmark (10 rps, 200 requests)"
        exit 1
        ;;
esac

echo ""
echo "✓ Benchmark complete"
