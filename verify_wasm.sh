#!/bin/bash

echo "========================================"
echo "WASM Filter Verification Script"
echo "========================================"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

FAILED=0

# Test 1: Check WASM files on nodes
echo -e "\n${BLUE}[Test 1] WASM files on Kind nodes${NC}"
NODES=("cilium-demo-control-plane" "cilium-demo-worker" "cilium-demo-worker2")
for NODE in "${NODES[@]}"; do
    if docker exec $NODE test -f /var/lib/cilium/wasm/oxy_money_auth.wasm; then
        echo -e "${GREEN}✓${NC} $NODE: WASM file present"
    else
        echo -e "${RED}✗${NC} $NODE: WASM file NOT found"
        FAILED=1
    fi
done

# Test 2: Check WASM in Envoy pods
echo -e "\n${BLUE}[Test 2] WASM files in Envoy pods${NC}"
ENVOY_PODS=$(kubectl get pods -n kube-system -l k8s-app=cilium-envoy -o name)
for POD in $ENVOY_PODS; do
    POD_NAME=$(echo $POD | cut -d'/' -f2)
    if kubectl exec -n kube-system $POD -- test -f /var/lib/cilium/wasm/oxy_money_auth.wasm 2>/dev/null; then
        echo -e "${GREEN}✓${NC} $POD_NAME: WASM accessible"
    else
        echo -e "${RED}✗${NC} $POD_NAME: WASM NOT accessible"
        FAILED=1
    fi
done

# Test 3: Check CiliumEnvoyConfig status
echo -e "\n${BLUE}[Test 3] CiliumEnvoyConfig status${NC}"
if kubectl get cec -n cilium-test wasm-http-filter &>/dev/null; then
    echo -e "${GREEN}✓${NC} CiliumEnvoyConfig exists"
    
    # Check if it's being processed
    AGE=$(kubectl get cec -n cilium-test wasm-http-filter -o jsonpath='{.metadata.creationTimestamp}')
    echo "  Created: $AGE"
else
    echo -e "${RED}✗${NC} CiliumEnvoyConfig NOT found"
    FAILED=1
fi

# Test 4: Check Envoy listener status
echo -e "\n${BLUE}[Test 4] Envoy listener configuration${NC}"
ENVOY_POD=$(kubectl get pods -n kube-system -l k8s-app=cilium-envoy -o name | head -1)

# Check for listener acceptance
if kubectl logs -n kube-system $ENVOY_POD --tail=200 | grep -q 'lds: add/update listener.*envoy-listener'; then
    echo -e "${GREEN}✓${NC} Listener 'envoy-listener' accepted by Envoy"
else
    echo -e "${YELLOW}⚠${NC} Listener status unclear (may still be loading)"
fi

# Check for WASM loading
if kubectl logs -n kube-system $ENVOY_POD --tail=200 | grep -qi 'wasm.*loaded\|wasm.*initialized'; then
    echo -e "${GREEN}✓${NC} WASM module appears to be loaded"
elif kubectl logs -n kube-system $ENVOY_POD --tail=200 | grep -qi 'wasm.*fail\|wasm.*error'; then
    echo -e "${RED}✗${NC} WASM loading errors detected"
    FAILED=1
else
    echo -e "${YELLOW}⚠${NC} WASM loading status unclear"
fi

# Test 5: Check for NACK errors
echo -e "\n${BLUE}[Test 5] Checking for configuration errors${NC}"
if kubectl logs -n kube-system -l k8s-app=cilium-envoy --tail=100 | grep -q 'NACK.*envoy-listener'; then
    echo -e "${RED}✗${NC} Configuration rejected (NACK) - check logs"
    echo "Recent errors:"
    kubectl logs -n kube-system -l k8s-app=cilium-envoy --tail=100 | grep 'NACK\|error.*wasm' | tail -3
    FAILED=1
else
    echo -e "${GREEN}✓${NC} No NACK errors for envoy-listener"
fi

# Test 6: Traffic test (without WASM expectations first)
echo -e "\n${BLUE}[Test 6] Traffic interception test${NC}"

# Create test pod if not exists
if ! kubectl get pod -n default test-client &>/dev/null; then
    echo "Creating test client pod..."
    kubectl run test-client --image=curlimages/curl:latest --restart=Never --command -- sleep 3600
    kubectl wait --for=condition=Ready pod/test-client -n default --timeout=30s
fi

echo "Testing connection to backend..."
RESPONSE=$(kubectl exec -n default test-client -- curl -s -m 5 -o /dev/null -w "%{http_code}" http://test-backend.cilium-test.svc.cluster.local:8080/health 2>/dev/null || echo "TIMEOUT")

if [ "$RESPONSE" = "TIMEOUT" ]; then
    echo -e "${RED}✗${NC} Connection timeout (CEC may be blocking traffic)"
    echo "  This could mean:"
    echo "  - WASM filter is loaded and rejecting requests (expected if auth is required)"
    echo "  - Network connectivity issue"
    FAILED=1
elif [ "$RESPONSE" = "200" ]; then
    echo -e "${YELLOW}⚠${NC} Got HTTP 200 (WASM filter may not be active yet)"
    echo "  Traffic is flowing but filter might not be intercepting"
elif [ "$RESPONSE" = "401" ] || [ "$RESPONSE" = "403" ]; then
    echo -e "${GREEN}✓${NC} Got HTTP $RESPONSE (WASM filter is likely active!)"
    echo "  This indicates the auth filter is working"
else
    echo -e "${YELLOW}⚠${NC} Got HTTP $RESPONSE (unexpected)"
fi

# Test 7: Check Envoy stats
echo -e "\n${BLUE}[Test 7] Envoy WASM statistics${NC}"
echo "Attempting to check Envoy admin interface..."

# Try to get stats via port-forward (non-blocking)
timeout 5 kubectl port-forward -n kube-system $ENVOY_POD 9901:9901 &>/dev/null &
PF_PID=$!
sleep 2

if curl -s http://localhost:9901/stats 2>/dev/null | grep -q 'wasm'; then
    echo -e "${GREEN}✓${NC} WASM stats found in Envoy"
    curl -s http://localhost:9901/stats 2>/dev/null | grep 'wasm' | head -5
else
    echo -e "${YELLOW}⚠${NC} Could not retrieve WASM stats (may require different access method)"
fi

kill $PF_PID 2>/dev/null || true

# Summary
echo -e "\n========================================"
if [ $FAILED -eq 0 ]; then
    echo -e "${GREEN}VERIFICATION PASSED${NC}"
    echo "All checks completed successfully"
else
    echo -e "${YELLOW}VERIFICATION COMPLETED WITH WARNINGS${NC}"
    echo "Some tests failed - review output above"
fi
echo "========================================"

# Debug commands
echo -e "\n${BLUE}Debug Commands:${NC}"
echo "1. View Envoy logs:"
echo "   kubectl logs -n kube-system $ENVOY_POD --tail=100"
echo ""
echo "2. View Cilium agent logs:"
echo "   kubectl logs -n kube-system -l k8s-app=cilium --tail=50 | grep envoy"
echo ""
echo "3. Describe CiliumEnvoyConfig:"
echo "   kubectl describe cec -n cilium-test wasm-http-filter"
echo ""
echo "4. Test with authentication header (if WASM requires it):"
echo "   kubectl exec test-client -- curl -H 'Authorization: Bearer TOKEN' http://test-backend.cilium-test.svc.cluster.local:8080/health"
echo ""
echo "5. Check Envoy config dump:"
echo "   kubectl exec -n kube-system $ENVOY_POD -- curl -s localhost:9901/config_dump | grep -A50 wasm"

exit $FAILED
