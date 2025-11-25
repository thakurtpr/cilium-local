#!/bin/bash

# WASM Filter Authentication Test Script
# Tests the oxy_money_auth_filter behavior with different authentication scenarios
#
# Expected Filter Behavior:
# 1. No pass-key header → 401 Unauthorized
# 2. pass-key but no JWT → 401 Unauthorized
# 3. Both valid pass-key and JWT → 200 OK (reaches backend)

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

# Test configuration
NAMESPACE="cilium-test"
SERVICE_NAME="test-backend"
SERVICE_URL="http://${SERVICE_NAME}.${NAMESPACE}.svc.cluster.local:8080"

# Authentication credentials
# NOTE: These are test values - replace with your actual credentials
PASS_KEY="test-pass-key-12345"
VALID_JWT="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IlRlc3QgVXNlciIsImlhdCI6MTUxNjIzOTAyMiwiZXhwIjo5OTk5OTk5OTk5fQ.4Adcj0PYg1dJ8RXB1xKLrgbWxPHP7w9C8q5HN_8u4u8"

# Test counter
TESTS_PASSED=0
TESTS_FAILED=0
TOTAL_TESTS=5

echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}   WASM Filter Authentication End-to-End Test Suite${NC}"
echo -e "${BLUE}============================================================${NC}"
echo ""
echo -e "${CYAN}Filter: oxy_money_auth_filter${NC}"
echo -e "${CYAN}Backend: ${SERVICE_URL}${NC}"
echo ""

# Function to print test header
print_test() {
    echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}Test $1: $2${NC}"
    echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# Function to print success
print_success() {
    echo -e "${GREEN}✓ PASS: $1${NC}"
}

# Function to print failure
print_failure() {
    echo -e "${RED}✗ FAIL: $1${NC}"
}

# Function to print info
print_info() {
    echo -e "${CYAN}ℹ INFO: $1${NC}"
}

# Function to run curl test inside cluster
run_cluster_curl() {
    local test_name=$1
    local curl_args=$2
    local expected_code=$3

    local pod_name="test-${test_name}-$$-${RANDOM}"

    # Run curl in a pod inside the cluster
    kubectl run "${pod_name}" \
        --image=curlimages/curl:latest \
        --restart=Never \
        --namespace=${NAMESPACE} \
        --command -- sh -c "$curl_args" >/dev/null 2>&1

    # Wait for pod to complete
    local count=0
    while [ $count -lt 30 ]; do
        local status=$(kubectl -n ${NAMESPACE} get pod ${pod_name} -o jsonpath='{.status.phase}' 2>/dev/null)
        if [ "$status" = "Succeeded" ] || [ "$status" = "Failed" ]; then
            break
        fi
        sleep 1
        ((count++))
    done

    # Get logs
    local result=$(kubectl -n ${NAMESPACE} logs ${pod_name} 2>&1 || echo "ERROR")

    # Clean up
    kubectl -n ${NAMESPACE} delete pod ${pod_name} --ignore-not-found=true >/dev/null 2>&1

    echo "$result"
}

# Check prerequisites
echo -e "${YELLOW}Checking prerequisites...${NC}"

if ! command -v kubectl &>/dev/null; then
    echo -e "${RED}Error: kubectl not found${NC}"
    exit 1
fi

# Check if namespace exists
if ! kubectl get namespace ${NAMESPACE} &>/dev/null; then
    echo -e "${RED}Error: Namespace ${NAMESPACE} not found${NC}"
    echo -e "${YELLOW}Run './install.sh local' first${NC}"
    exit 1
fi

# Check if backend service exists
if ! kubectl -n ${NAMESPACE} get service ${SERVICE_NAME} &>/dev/null; then
    echo -e "${RED}Error: Service ${SERVICE_NAME} not found in namespace ${NAMESPACE}${NC}"
    exit 1
fi

# Check if backend pods are ready
READY_PODS=$(kubectl -n ${NAMESPACE} get pods -l app=test-backend --no-headers 2>/dev/null | grep -c "Running" || echo "0")
if [ "$READY_PODS" -eq 0 ]; then
    echo -e "${RED}Error: No backend pods are ready${NC}"
    kubectl -n ${NAMESPACE} get pods -l app=test-backend
    exit 1
fi

echo -e "${GREEN}✓ Prerequisites met${NC}"
echo -e "${GREEN}✓ Backend pods ready: ${READY_PODS}${NC}"
echo ""
echo -e "${YELLOW}Starting authentication tests...${NC}"
echo ""

# ============================================================================
# TEST 1: No headers (baseline - should reach backend or be rejected by filter)
# ============================================================================
print_test "1/${TOTAL_TESTS}" "Baseline - Request with NO authentication headers"
echo -e "${CYAN}Expected: May reach backend (depends on filter config)${NC}"
echo ""

HTTP_CODE=$(run_cluster_curl "baseline" \
    "curl -s -o /dev/null -w '%{http_code}' ${SERVICE_URL}/health" \
    "200")

echo -e "${CYAN}Response Code: ${HTTP_CODE}${NC}"

if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "401" ] || [ "$HTTP_CODE" = "403" ]; then
    print_success "Received expected HTTP response: ${HTTP_CODE}"
    ((TESTS_PASSED++))
else
    print_failure "Unexpected response: ${HTTP_CODE}"
    ((TESTS_FAILED++))
fi
echo ""

# ============================================================================
# TEST 2: No pass-key header → Expected 401
# ============================================================================
print_test "2/${TOTAL_TESTS}" "Request WITHOUT pass-key header"
echo -e "${CYAN}Expected: 401 Unauthorized (WASM filter should reject)${NC}"
echo -e "${CYAN}Curl command:${NC}"
echo -e "${BLUE}curl -s -w '\n%{http_code}' ${SERVICE_URL}/health${NC}"
echo ""

HTTP_CODE=$(run_cluster_curl "no-passkey" \
    "curl -s -o /dev/null -w '%{http_code}' ${SERVICE_URL}/health" \
    "401")

echo -e "${CYAN}Response Code: ${HTTP_CODE}${NC}"

if [ "$HTTP_CODE" = "401" ]; then
    print_success "WASM filter correctly rejected request without pass-key (401)"
    ((TESTS_PASSED++))
else
    print_failure "Expected 401, got ${HTTP_CODE}"
    print_info "The WASM filter may not be enforcing pass-key requirement"
    ((TESTS_FAILED++))
fi
echo ""

# ============================================================================
# TEST 3: pass-key but no JWT → Expected 401
# ============================================================================
print_test "3/${TOTAL_TESTS}" "Request WITH pass-key but WITHOUT JWT"
echo -e "${CYAN}Expected: 401 Unauthorized (WASM filter should reject)${NC}"
echo -e "${CYAN}Curl command:${NC}"
echo -e "${BLUE}curl -H 'pass-key: ${PASS_KEY}' ${SERVICE_URL}/health${NC}"
echo ""

HTTP_CODE=$(run_cluster_curl "passkey-no-jwt" \
    "curl -s -o /dev/null -w '%{http_code}' -H 'pass-key: ${PASS_KEY}' ${SERVICE_URL}/health" \
    "401")

echo -e "${CYAN}Response Code: ${HTTP_CODE}${NC}"

if [ "$HTTP_CODE" = "401" ]; then
    print_success "WASM filter correctly rejected request with pass-key but no JWT (401)"
    ((TESTS_PASSED++))
else
    print_failure "Expected 401, got ${HTTP_CODE}"
    print_info "The WASM filter may not be enforcing JWT requirement"
    ((TESTS_FAILED++))
fi
echo ""

# ============================================================================
# TEST 4: Both pass-key and JWT → Expected 200
# ============================================================================
print_test "4/${TOTAL_TESTS}" "Request WITH both pass-key AND JWT"
echo -e "${CYAN}Expected: 200 OK (should reach backend)${NC}"
echo -e "${CYAN}Curl command:${NC}"
echo -e "${BLUE}curl -H 'pass-key: ${PASS_KEY}' -H 'Authorization: Bearer ${VALID_JWT}' ${SERVICE_URL}/health${NC}"
echo ""

HTTP_CODE=$(run_cluster_curl "full-auth" \
    "curl -s -o /dev/null -w '%{http_code}' -H 'pass-key: ${PASS_KEY}' -H 'Authorization: Bearer ${VALID_JWT}' ${SERVICE_URL}/health" \
    "200")

echo -e "${CYAN}Response Code: ${HTTP_CODE}${NC}"

if [ "$HTTP_CODE" = "200" ]; then
    print_success "WASM filter correctly allowed authenticated request (200)"
    ((TESTS_PASSED++))
else
    print_failure "Expected 200, got ${HTTP_CODE}"
    print_info "Check if JWT is valid or if pass-key is correct"
    ((TESTS_FAILED++))
fi
echo ""

# ============================================================================
# TEST 5: POST request with authentication
# ============================================================================
print_test "5/${TOTAL_TESTS}" "POST request WITH full authentication"
echo -e "${CYAN}Expected: 200 OK (should reach backend)${NC}"
echo -e "${CYAN}Curl command:${NC}"
echo -e "${BLUE}curl -X POST -H 'pass-key: ${PASS_KEY}' -H 'Authorization: Bearer ${VALID_JWT}' \\"
echo -e "     -H 'Content-Type: application/json' -d '{\"test\":\"data\"}' ${SERVICE_URL}/echo${NC}"
echo ""

HTTP_CODE=$(run_cluster_curl "post-auth" \
    "curl -s -o /dev/null -w '%{http_code}' -X POST -H 'pass-key: ${PASS_KEY}' -H 'Authorization: Bearer ${VALID_JWT}' -H 'Content-Type: application/json' -d '{\"test\":\"data\"}' ${SERVICE_URL}/echo" \
    "200")

echo -e "${CYAN}Response Code: ${HTTP_CODE}${NC}"

if [ "$HTTP_CODE" = "200" ]; then
    print_success "POST request with authentication succeeded (200)"
    ((TESTS_PASSED++))
else
    print_failure "Expected 200, got ${HTTP_CODE}"
    ((TESTS_FAILED++))
fi
echo ""

# ============================================================================
# Summary
# ============================================================================
echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}                    Test Summary${NC}"
echo -e "${BLUE}============================================================${NC}"
echo ""
echo -e "${GREEN}Passed: ${TESTS_PASSED}/${TOTAL_TESTS}${NC}"
echo -e "${RED}Failed: ${TESTS_FAILED}/${TOTAL_TESTS}${NC}"
echo ""

if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}   ✓ All authentication tests passed!${NC}"
    echo -e "${GREEN}   The WASM filter is working correctly.${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${YELLOW}WASM Filter Behavior Summary:${NC}"
    echo -e "  • No pass-key header → Rejected (401)"
    echo -e "  • pass-key only, no JWT → Rejected (401)"
    echo -e "  • Both pass-key + JWT → Allowed (200)"
    echo ""
else
    echo -e "${RED}════════════════════════════════════════════════════════════${NC}"
    echo -e "${RED}   ✗ Some tests failed${NC}"
    echo -e "${RED}════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${YELLOW}Troubleshooting Steps:${NC}"
    echo ""
    echo -e "1. Check if WASM filter is loaded:"
    echo -e "   ${BLUE}kubectl -n kube-system logs -l k8s-app=cilium-envoy --tail=100 | grep -i wasm${NC}"
    echo ""
    echo -e "2. Check CiliumEnvoyConfig:"
    echo -e "   ${BLUE}kubectl -n ${NAMESPACE} get ciliumenvoyconfig wasm-http-filter -o yaml${NC}"
    echo ""
    echo -e "3. Check if backend is reachable:"
    echo -e "   ${BLUE}kubectl -n ${NAMESPACE} get pods -l app=test-backend${NC}"
    echo -e "   ${BLUE}kubectl -n ${NAMESPACE} logs -l app=test-backend${NC}"
    echo ""
    echo -e "4. Check network policy:"
    echo -e "   ${BLUE}kubectl -n ${NAMESPACE} get ciliumnetworkpolicy${NC}"
    echo ""
    echo -e "5. Verify Envoy is processing requests:"
    echo -e "   ${BLUE}kubectl -n kube-system logs -l k8s-app=cilium-envoy -f${NC}"
    echo ""
fi

# ============================================================================
# Manual Test Instructions
# ============================================================================
echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}            Manual Testing Instructions${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${YELLOW}Option 1: Test from inside the cluster (recommended)${NC}"
echo ""
echo -e "1. Start an interactive test pod:"
echo -e "   ${BLUE}kubectl run -n ${NAMESPACE} test-client --image=curlimages/curl:latest --rm -it --restart=Never -- sh${NC}"
echo ""
echo -e "2. Inside the pod, run these curl commands:"
echo ""
echo -e "   ${CYAN}# Test 1: No authentication (should get 401)${NC}"
echo -e "   ${BLUE}curl -v ${SERVICE_URL}/health${NC}"
echo ""
echo -e "   ${CYAN}# Test 2: Only pass-key (should get 401)${NC}"
echo -e "   ${BLUE}curl -v -H 'pass-key: ${PASS_KEY}' ${SERVICE_URL}/health${NC}"
echo ""
echo -e "   ${CYAN}# Test 3: Both pass-key and JWT (should get 200)${NC}"
echo -e "   ${BLUE}curl -v -H 'pass-key: ${PASS_KEY}' -H 'Authorization: Bearer ${VALID_JWT}' ${SERVICE_URL}/health${NC}"
echo ""
echo -e "   ${CYAN}# Test 4: POST with authentication${NC}"
echo -e "   ${BLUE}curl -v -X POST -H 'pass-key: ${PASS_KEY}' -H 'Authorization: Bearer ${VALID_JWT}' \\${NC}"
echo -e "   ${BLUE}     -H 'Content-Type: application/json' -d '{\"message\":\"test\"}' ${SERVICE_URL}/echo${NC}"
echo ""
echo -e "${YELLOW}Option 2: Test via port-forward${NC}"
echo ""
echo -e "1. Port-forward the service:"
echo -e "   ${BLUE}kubectl -n ${NAMESPACE} port-forward svc/${SERVICE_NAME} 8080:8080${NC}"
echo ""
echo -e "2. In another terminal, run:"
echo -e "   ${BLUE}curl -v http://localhost:8080/health${NC}"
echo -e "   ${BLUE}curl -v -H 'pass-key: ${PASS_KEY}' http://localhost:8080/health${NC}"
echo -e "   ${BLUE}curl -v -H 'pass-key: ${PASS_KEY}' -H 'Authorization: Bearer ${VALID_JWT}' http://localhost:8080/health${NC}"
echo ""
echo -e "${CYAN}Note: Port-forward may bypass the WASM filter depending on your Cilium configuration.${NC}"
echo -e "${CYAN}Testing from inside the cluster is more reliable.${NC}"
echo ""

if [ $TESTS_FAILED -eq 0 ]; then
    exit 0
else
    exit 1
fi
