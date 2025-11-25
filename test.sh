#!/bin/bash

# Quick test script for Cilium + WASM Filter setup
# Usage: ./test.sh

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Cilium + WASM Filter Test Suite${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Function to print test header
print_test() {
    echo -e "${YELLOW}Test: $1${NC}"
}

# Function to print success
print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

# Function to print failure
print_failure() {
    echo -e "${RED}✗ $1${NC}"
}

# Test counter
TESTS_PASSED=0
TESTS_FAILED=0

# Test 1: Check if namespace exists
print_test "1. Checking cilium-test namespace"
if kubectl get namespace cilium-test &>/dev/null; then
    print_success "Namespace exists"
    ((TESTS_PASSED++))
else
    print_failure "Namespace not found"
    ((TESTS_FAILED++))
fi
echo ""

# Test 2: Check backend pods
print_test "2. Checking backend pods"
READY_PODS=$(kubectl -n cilium-test get pods -l app=test-backend -o json | jq -r '.items[] | select(.status.phase=="Running") | .metadata.name' | wc -l)
TOTAL_PODS=$(kubectl -n cilium-test get pods -l app=test-backend --no-headers 2>/dev/null | wc -l)

if [ "$READY_PODS" -gt 0 ]; then
    print_success "Backend pods ready: $READY_PODS/$TOTAL_PODS"
    ((TESTS_PASSED++))
else
    print_failure "No backend pods ready"
    ((TESTS_FAILED++))
fi
echo ""

# Test 3: Check backend service
print_test "3. Checking backend service"
if kubectl -n cilium-test get service test-backend &>/dev/null; then
    ENDPOINTS=$(kubectl -n cilium-test get endpoints test-backend -o json | jq -r '.subsets[0].addresses | length' 2>/dev/null || echo 0)
    if [ "$ENDPOINTS" -gt 0 ]; then
        print_success "Service exists with $ENDPOINTS endpoints"
        ((TESTS_PASSED++))
    else
        print_failure "Service exists but has no endpoints"
        ((TESTS_FAILED++))
    fi
else
    print_failure "Service not found"
    ((TESTS_FAILED++))
fi
echo ""

# Test 4: Check CiliumEnvoyConfig
print_test "4. Checking CiliumEnvoyConfig"
if kubectl -n cilium-test get ciliumenvoyconfig wasm-http-filter &>/dev/null; then
    print_success "CiliumEnvoyConfig exists"
    ((TESTS_PASSED++))

    # Check if WASM URL is configured
    WASM_URL=$(kubectl -n cilium-test get ciliumenvoyconfig wasm-http-filter -o json | jq -r '.spec.resources[] | select(.["@type"]=="type.googleapis.com/envoy.config.listener.v3.Listener") | .filter_chains[0].filters[0].typed_config.http_filters[] | select(.name=="envoy.filters.http.wasm") | .typed_config.config.vm_config.code.remote.http_uri.uri' 2>/dev/null || echo "")

    if [ -n "$WASM_URL" ]; then
        print_success "WASM URL configured: $WASM_URL"
    else
        print_failure "WASM URL not found in config"
    fi
else
    print_failure "CiliumEnvoyConfig not found"
    ((TESTS_FAILED++))
fi
echo ""

# Test 5: Check CiliumNetworkPolicy
print_test "5. Checking CiliumNetworkPolicy"
if kubectl -n cilium-test get ciliumnetworkpolicy test-backend-l7-policy &>/dev/null; then
    print_success "CiliumNetworkPolicy exists"
    ((TESTS_PASSED++))
else
    print_failure "CiliumNetworkPolicy not found"
    ((TESTS_FAILED++))
fi
echo ""

# Test 6: Check Cilium pods
print_test "6. Checking Cilium installation"
CILIUM_PODS=$(kubectl -n kube-system get pods -l k8s-app=cilium --no-headers 2>/dev/null | grep Running | wc -l)
if [ "$CILIUM_PODS" -gt 0 ]; then
    print_success "Cilium running: $CILIUM_PODS pods"
    ((TESTS_PASSED++))
else
    print_failure "Cilium not running"
    ((TESTS_FAILED++))
fi
echo ""

# Test 7: Check Cilium Envoy pods
print_test "7. Checking Cilium Envoy"
ENVOY_PODS=$(kubectl -n kube-system get pods -l k8s-app=cilium-envoy --no-headers 2>/dev/null | grep Running | wc -l)
if [ "$ENVOY_PODS" -gt 0 ]; then
    print_success "Cilium Envoy running: $ENVOY_PODS pods"
    ((TESTS_PASSED++))
else
    print_failure "Cilium Envoy not running"
    ((TESTS_FAILED++))
fi
echo ""

# Test 8: Test backend connectivity (if curl is available)
print_test "8. Testing backend connectivity"
if command -v curl &>/dev/null; then
    # Create a test pod to run curl from inside the cluster
    echo -e "${YELLOW}Creating test pod...${NC}"

    # Run a quick curl test
    TEST_RESULT=$(kubectl run test-connectivity-$$-$RANDOM \
        --image=curlimages/curl:latest \
        --rm \
        --restart=Never \
        --namespace=cilium-test \
        --timeout=30s \
        --quiet \
        -- curl -s -o /dev/null -w "%{http_code}" \
        http://test-backend.cilium-test.svc.cluster.local:8080/health 2>/dev/null || echo "000")

    if [ "$TEST_RESULT" = "200" ] || [ "$TEST_RESULT" = "301" ] || [ "$TEST_RESULT" = "302" ]; then
        print_success "Backend responding (HTTP $TEST_RESULT)"
        ((TESTS_PASSED++))
    else
        print_failure "Backend not responding (HTTP $TEST_RESULT)"
        ((TESTS_FAILED++))
    fi
else
    print_success "Skipped (curl not available)"
    ((TESTS_PASSED++))
fi
echo ""

# Summary
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Test Summary${NC}"
echo -e "${BLUE}========================================${NC}"
echo -e "${GREEN}Passed: $TESTS_PASSED${NC}"
echo -e "${RED}Failed: $TESTS_FAILED${NC}"
echo ""

if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "${GREEN}All tests passed! ✓${NC}"
    echo ""
    echo -e "${YELLOW}Next steps:${NC}"
    echo -e "1. Test GET endpoint:"
    echo -e "   ${BLUE}kubectl run -n cilium-test test-client --image=curlimages/curl:latest --rm -it --restart=Never -- curl -v http://test-backend.cilium-test.svc.cluster.local:8080/health${NC}"
    echo ""
    echo -e "2. Test POST endpoint:"
    echo -e "   ${BLUE}kubectl run -n cilium-test test-client --image=curlimages/curl:latest --rm -it --restart=Never -- curl -v -X POST http://test-backend.cilium-test.svc.cluster.local:8080/echo -d '{\"test\":\"data\"}'${NC}"
    echo ""
    echo -e "3. Check WASM filter logs:"
    echo -e "   ${BLUE}kubectl -n kube-system logs -l k8s-app=cilium-envoy --tail=50 | grep -i wasm${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed. Please check the logs:${NC}"
    echo -e "${BLUE}kubectl -n cilium-test get pods${NC}"
    echo -e "${BLUE}kubectl -n cilium-test logs -l app=test-backend${NC}"
    echo -e "${BLUE}kubectl -n kube-system logs -l k8s-app=cilium${NC}"
    exit 1
fi
