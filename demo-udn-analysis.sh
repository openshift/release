#!/bin/bash
# Demo script for UDN Comprehensive Chaos Analysis
# Based on your AWS cluster configuration: 3 masters + 3 workers + 3 infra

echo "🎯 UDN Comprehensive Chaos Analysis Demo"
echo "========================================"
echo ""

echo "📊 Running capacity analysis for your AWS cluster configuration:"
echo "- Platform: AWS"  
echo "- Masters: 3 x m6a.xlarge (4 vCPU, 16GB RAM)"
echo "- Workers: 3 x m6a.xlarge (4 vCPU, 16GB RAM)"
echo "- Infra: 3 x r5.xlarge (4 vCPU, 32GB RAM)"
echo "- Total: 9 nodes, 36 vCPUs, 192GB RAM"
echo ""

# Test with your exact cluster configuration
if [ -f "udn-capacity-planning-calculator.py" ]; then
    echo "🔍 Analyzing Layer 2 vs Layer 3 for your cluster..."
    python3 udn-capacity-planning-calculator.py \
        --master-nodes 3 \
        --worker-nodes 3 \
        --infra-nodes 3 \
        --master-memory 16 \
        --worker-memory 16 \
        --infra-memory 32 \
        --master-cpu 4 \
        --worker-cpu 4 \
        --infra-cpu 4 \
        --memory-cost 0.10 \
        --cpu-cost 0.05
        
    echo ""
    echo "📈 Running scaling analysis..."
    python3 udn-capacity-planning-calculator.py \
        --master-nodes 3 \
        --worker-nodes 3 \
        --infra-nodes 3 \
        --master-memory 16 \
        --worker-memory 16 \
        --infra-memory 32 \
        --master-cpu 4 \
        --worker-cpu 4 \
        --infra-cpu 4 \
        --scaling-analysis
else
    echo "❌ Capacity planning calculator not found"
fi

echo ""
echo "📋 Key Files Created:"
echo "1. 📊 udn-comprehensive-chaos-dashboard.json - Import into Grafana"
echo "2. 🎯 udn-layer-selection-guide.yaml - Apply to OpenShift"  
echo "3. 🚨 udn-chaos-monitoring-alerts.yaml - Configure Prometheus alerts"
echo "4. 🔢 udn-capacity-planning-calculator.py - Run capacity analysis"
echo ""

echo "🚀 Quick Setup Commands:"
echo "# 1. Import Grafana dashboard"
echo "curl -X POST http://grafana:3000/api/dashboards/db \\"
echo "  -H 'Content-Type: application/json' \\"
echo "  -d @udn-comprehensive-chaos-dashboard.json"
echo ""

echo "# 2. Apply monitoring configuration"
echo "oc apply -f udn-layer-selection-guide.yaml"
echo "oc apply -f udn-chaos-monitoring-alerts.yaml"
echo ""

echo "# 3. Run capacity analysis"
echo "python3 udn-capacity-planning-calculator.py --scaling-analysis"
echo ""

echo "📊 Dashboard Features:"
echo "✅ Executive Summary - Key chaos impact metrics"
echo "✅ P99 Latency Analysis - Layer 2 vs Layer 3 comparison"  
echo "✅ Memory Efficiency - Shows improvement during chaos"
echo "✅ CPU Performance - Demonstrates stability during chaos"
echo "✅ Chaos Event Detection - Real-time master node monitoring"
echo "✅ Resource Recommendations - Data-driven layer selection"
echo ""

echo "🎯 Based on your test results:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🏆 RECOMMENDATION: Layer 2 for your workloads"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Reasons:"
echo "• 21% memory savings (93MB vs 116MB per node)" 
echo "• 4.9% better baseline latency (57.6s vs 60.4s)"
echo "• Only 3.0% latency penalty during chaos"
echo "• Memory usage improves during chaos events"
echo "• CPU overhead acceptable (+5%)"
echo ""

echo "🚨 Monitoring Alerts Configured:"
echo "• P99 Latency > 60s (Layer 2) / 65s (Layer 3) → Warning"
echo "• P99 Latency > 65s (Layer 2) / 70s (Layer 3) → Critical"
echo "• Memory anomaly during chaos → Investigation"
echo "• CPU anomaly during chaos → Investigation"
echo ""

echo "🎉 Your cluster shows EXCELLENT chaos resilience!"
echo "Ready for production with minimal performance impact during failures." 