# Complete Testing Workflow

Step-by-step guide to install, configure, and test the Cilium + WASM filter setup.

## Prerequisites Check

Before starting, ensure you have:

```bash
# Check kind cluster is running
kind get clusters

# Check kubectl works
kubectl cluster-info

# Check helm is installed
helm version

# Verify cluster nodes
kubectl get nodes
```

Expected: 1 control-plane + 2 worker nodes

## Step 1: Install Cilium with Envoy

```bash
cd cilium-local-test

# Install Cilium using the automated script
./install.sh local
```

This will:
1. Add Cilium Helm repository
2. Install Cilium with Envoy enabled
3. Wait for Cilium pods to be ready
4. Deploy the test stack (backend + WASM config + network policy)
5. Wait for backend pods to be ready

**Verification:**

```bash
# Check Cilium is running
kubectl -n kube-system get pods -l k8s-app=cilium

# Check Cilium Envoy is running
kubectl -n kube-system get pods -l k8s-app=cilium-envoy

# Check Cilium status
kubectl exec -n kube-system ds/cilium -- cilium status

# Expected output should show:
# - KubeProxyReplacement: True
# - Envoy: OK
```

## Step 2: Verify Test Stack Deployment

```bash
# Check namespace
kubectl get namespace cilium-test

# Check all resources
kubectl -n cilium-test get all

# Check CiliumEnvoyConfig
kubectl -n cilium-test get ciliumenvoyconfig

# Check CiliumNetworkPolicy
kubectl -n cilium-test get ciliumnetworkpolicy

# Check ConfigMaps
kubectl -n cilium-test get configmap
```

**Expected Resources:**
- Deployment: `test-backend` (2 replicas)
- Service: `test-backend` (ClusterIP)
- CiliumEnvoyConfig: `wasm-http-filter`
- CiliumNetworkPolicy: `test-backend-l7-policy`
- ConfigMap: `test-environment-config`, `test-credentials`

## Step 3: Run Basic Verification Tests

```bash
./test.sh
```

This checks:
- ✓ Namespace exists
- ✓ Backend pods are ready
- ✓ Service has endpoints
- ✓ CiliumEnvoyConfig exists
- ✓ CiliumNetworkPolicy exists
- ✓ Cilium pods running
- ✓ Cilium Envoy pods running
- ✓ Backend connectivity

**All tests should pass** before proceeding.

## Step 4: Verify WASM Filter is Loaded

```bash
# Check Envoy logs for WASM loading
kubectl -n kube-system logs -l k8s-app=cilium-envoy --tail=100 | grep -i wasm

# Look for lines like:
# "wasm: loading..."
# "wasm: fetching module from https://res.cloudinary.com/..."
# "wasm: module loaded successfully"
```

**If WASM not loading:**

```bash
# Check CiliumEnvoyConfig details
kubectl -n cilium-test get ciliumenvoyconfig wasm-http-filter -o yaml

# Verify WASM URL is accessible from cluster
kubectl run curl-test --image=curlimages/curl:latest --rm -it --restart=Never -- \
  curl -I https://res.cloudinary.com/dohipaqvk/raw/upload/v1764100796/oxy_money_auth_filter_yos7rp.wasm

# Expected: HTTP 200 OK
```

## Step 5: Test WASM Filter Authentication

### 5.1 Automated Tests

```bash
./test-auth.sh
```

**Expected Results:**

| Test | Scenario | Expected HTTP Code | Status |
|------|----------|-------------------|--------|
| 1 | Baseline (no explicit auth) | 200 or 401 | PASS |
| 2 | No pass-key header | 401 | ✓ PASS |
| 3 | Pass-key but no JWT | 401 | ✓ PASS |
| 4 | Both pass-key + JWT | 200 | ✓ PASS |
| 5 | POST with full auth | 200 | ✓ PASS |

**If any test fails, see [Troubleshooting](#troubleshooting) section below.**

### 5.2 Manual Interactive Tests

```bash
# Start test pod
kubectl run -n cilium-test test-client \
  --image=curlimages/curl:latest \
  --rm -it --restart=Never \
  -- sh
```

**Inside the test pod:**

```bash
# Set variables for convenience
SERVICE_URL="http://test-backend.cilium-test.svc.cluster.local:8080"
PASS_KEY="test-pass-key-12345"
JWT="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IlRlc3QgVXNlciIsImlhdCI6MTUxNjIzOTAyMiwiZXhwIjo5OTk5OTk5OTk5fQ.4Adcj0PYg1dJ8RXB1xKLrgbWxPHP7w9C8q5HN_8u4u8"

# Test 1: No authentication (should get 401)
echo "=== Test 1: No auth ==="
curl -v $SERVICE_URL/health
# Expected: 401 Unauthorized

# Test 2: Only pass-key (should get 401)
echo "=== Test 2: Pass-key only ==="
curl -v -H "pass-key: $PASS_KEY" $SERVICE_URL/health
# Expected: 401 Unauthorized

# Test 3: Only JWT (should get 401)
echo "=== Test 3: JWT only ==="
curl -v -H "Authorization: Bearer $JWT" $SERVICE_URL/health
# Expected: 401 Unauthorized

# Test 4: Both pass-key + JWT (should get 200)
echo "=== Test 4: Full auth ==="
curl -v -H "pass-key: $PASS_KEY" -H "Authorization: Bearer $JWT" $SERVICE_URL/health
# Expected: 200 OK

# Test 5: POST with full auth
echo "=== Test 5: POST with auth ==="
curl -v -X POST \
  -H "pass-key: $PASS_KEY" \
  -H "Authorization: Bearer $JWT" \
  -H "Content-Type: application/json" \
  -d '{"message":"test"}' \
  $SERVICE_URL/echo
# Expected: 200 OK
```

## Step 6: Monitor Traffic with Hubble

```bash
# Port-forward Hubble UI
kubectl port-forward -n kube-system svc/hubble-ui 12000:80

# Open browser: http://localhost:12000
```

In Hubble UI:
1. Select namespace: `cilium-test`
2. Run some curl tests from Step 5
3. Observe HTTP flows
4. Look for:
   - Requests with 401 (rejected by WASM filter)
   - Requests with 200 (allowed through)
   - L7 policy enforcement

## Step 7: Check Envoy Logs in Real-Time

```bash
# Terminal 1: Watch Envoy logs
kubectl -n kube-system logs -l k8s-app=cilium-envoy -f | grep -E "wasm|401|200|auth"

# Terminal 2: Run test requests
kubectl run -n cilium-test quick-test --image=curlimages/curl:latest --rm -it --restart=Never -- \
  curl -H "pass-key: test-pass-key-12345" \
  -H "Authorization: Bearer eyJh..." \
  http://test-backend.cilium-test.svc.cluster.local:8080/health
```

You should see log entries showing:
- Request received
- WASM filter processing
- Auth validation
- Response code (200 or 401)

## Troubleshooting

### Issue: Tests return 200 without authentication

**Diagnosis:**
```bash
# Check if WASM filter is loaded
kubectl -n kube-system logs -l k8s-app=cilium-envoy | grep -i "wasm.*loaded"

# Check CiliumEnvoyConfig is applied
kubectl -n cilium-test get ciliumenvoyconfig wasm-http-filter -o yaml

# Check if network policy is enforcing L7
kubectl -n cilium-test describe ciliumnetworkpolicy test-backend-l7-policy
```

**Possible Causes:**
1. WASM module not loaded
2. Network policy not applied
3. Envoy not intercepting traffic

**Fix:**
```bash
# Restart Cilium Envoy pods
kubectl -n kube-system rollout restart daemonset/cilium-envoy

# Wait for pods to be ready
kubectl -n kube-system rollout status daemonset/cilium-envoy

# Re-run tests
./test-auth.sh
```

### Issue: Tests return 503 Service Unavailable

**Diagnosis:**
```bash
# Check backend pods
kubectl -n cilium-test get pods -l app=test-backend

# Check service endpoints
kubectl -n cilium-test get endpoints test-backend

# Check pod logs
kubectl -n cilium-test logs -l app=test-backend
```

**Fix:**
```bash
# If pods are not ready, check events
kubectl -n cilium-test get events --sort-by='.lastTimestamp'

# Delete and recreate
kubectl -n cilium-test delete pod -l app=test-backend
kubectl -n cilium-test get pods -w
```

### Issue: WASM module download fails

**Diagnosis:**
```bash
# Check Envoy logs for download errors
kubectl -n kube-system logs -l k8s-app=cilium-envoy | grep -i "wasm.*error\|wasm.*fail"

# Test WASM URL from cluster
kubectl run curl-wasm --image=curlimages/curl:latest --rm -it --restart=Never -- \
  curl -I https://res.cloudinary.com/dohipaqvk/raw/upload/v1764100796/oxy_money_auth_filter_yos7rp.wasm
```

**Possible Causes:**
1. Network policy blocking egress
2. DNS resolution issue
3. TLS certificate issue

**Fix:**
```bash
# Check DNS resolution
kubectl run nslookup-test --image=busybox:1.28 --rm -it --restart=Never -- \
  nslookup res.cloudinary.com

# Verify TLS cluster config
kubectl -n cilium-test get ciliumenvoyconfig wasm-http-filter \
  -o jsonpath='{.spec.resources[2].transport_socket}' | jq .
```

### Issue: Port-forward bypasses WASM filter

**Expected Behavior**: Port-forwarding may bypass Cilium/Envoy depending on configuration.

**Solution**: Always test from **inside the cluster** using:
```bash
kubectl run -n cilium-test test-client --image=curlimages/curl:latest --rm -it --restart=Never -- sh
```

## Step 8: Customize Credentials (Optional)

```bash
# Edit test credentials
vi test-credentials.env

# Update ConfigMap with new credentials
kubectl -n cilium-test edit configmap test-credentials

# Or recreate ConfigMap
kubectl -n cilium-test delete configmap test-credentials
kubectl -n cilium-test create configmap test-credentials \
  --from-literal=PASS_KEY=your-new-key \
  --from-literal=VALID_JWT=your-new-jwt
```

## Step 9: Test Different Environments

```bash
# Switch to dev environment (3 replicas)
kubectl delete -k overlays/local/
kubectl apply -k overlays/dev/

# Verify
kubectl -n cilium-test get pods -l app=test-backend
# Should show 3 pods

# Run tests again
./test-auth.sh
```

## Cleanup

```bash
# Remove test stack (keep Cilium)
./uninstall.sh --keep-cilium

# Or remove everything including Cilium
./uninstall.sh
```

## Success Criteria Checklist

- [ ] Cilium installed and running
- [ ] Cilium Envoy pods running
- [ ] Test backend pods ready (2/2)
- [ ] CiliumEnvoyConfig deployed
- [ ] CiliumNetworkPolicy deployed
- [ ] WASM filter loaded (check logs)
- [ ] Test without auth → 401
- [ ] Test with pass-key only → 401
- [ ] Test with JWT only → 401
- [ ] Test with both → 200
- [ ] POST request with auth → 200
- [ ] Hubble shows traffic flow
- [ ] Envoy logs show WASM filter execution

## Complete Test Command Summary

```bash
# Full workflow
cd cilium-local-test
./install.sh local              # Install everything
./test.sh                       # Basic verification
./test-auth.sh                  # Authentication tests
kubectl port-forward -n kube-system svc/hubble-ui 12000:80  # Hubble UI
./uninstall.sh --keep-cilium    # Cleanup
```

## Additional Resources

- [README.md](README.md) - Complete documentation
- [QUICKSTART.md](QUICKSTART.md) - Quick start guide
- [AUTHENTICATION-TESTING.md](AUTHENTICATION-TESTING.md) - Detailed auth testing
- [Cilium Docs](https://docs.cilium.io/)
- [Envoy WASM Docs](https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/wasm_filter)

---

**🎉 You're all set!** Your Cilium + Envoy + WASM filter environment is ready for testing.
