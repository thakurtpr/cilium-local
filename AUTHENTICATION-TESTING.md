# WASM Filter Authentication Testing Guide

Complete guide for testing the `oxy_money_auth_filter` authentication behavior.

## Filter Behavior Overview

The WASM filter (`oxy_money_auth_filter`) implements a two-factor authentication mechanism:

| Scenario | pass-key Header | JWT Token | Expected Result |
|----------|----------------|-----------|-----------------|
| 1        | ❌ Missing      | ❌ Missing | 🔴 401 Unauthorized |
| 2        | ✅ Present      | ❌ Missing | 🔴 401 Unauthorized |
| 3        | ❌ Missing      | ✅ Present | 🔴 401 Unauthorized |
| 4        | ✅ Present      | ✅ Present | 🟢 200 OK (reaches backend) |

## Quick Test

Run the automated test suite:

```bash
cd cilium-local-test
./test-auth.sh
```

This will test all authentication scenarios and report pass/fail for each.

## Test Credentials

Default test credentials are defined in `test-credentials.env`:

```bash
# View credentials
cat test-credentials.env

# Customize credentials
vi test-credentials.env

# Use credentials in test script
source test-credentials.env
./test-auth.sh
```

### Default Test Values

- **Pass-Key**: `test-pass-key-12345`
- **JWT Token**: `eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...` (expires in year 2286)

**⚠️ Important**: Replace these with your actual credentials before testing!

## Manual Testing

### Option 1: Interactive Testing (Recommended)

Start an interactive curl pod inside the cluster:

```bash
kubectl run -n cilium-test test-client \
  --image=curlimages/curl:latest \
  --rm -it --restart=Never \
  -- sh
```

Inside the pod, run these tests:

#### Test 1: No Authentication Headers

```bash
curl -v http://test-backend.cilium-test.svc.cluster.local:8080/health
```

**Expected**: `401 Unauthorized`

**What happens**: WASM filter rejects the request immediately

#### Test 2: Only pass-key Header

```bash
curl -v \
  -H "pass-key: test-pass-key-12345" \
  http://test-backend.cilium-test.svc.cluster.local:8080/health
```

**Expected**: `401 Unauthorized`

**What happens**: WASM filter validates pass-key but rejects due to missing JWT

#### Test 3: Only JWT Header

```bash
curl -v \
  -H "Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IlRlc3QgVXNlciIsImlhdCI6MTUxNjIzOTAyMiwiZXhwIjo5OTk5OTk5OTk5fQ.4Adcj0PYg1dJ8RXB1xKLrgbWxPHP7w9C8q5HN_8u4u8" \
  http://test-backend.cilium-test.svc.cluster.local:8080/health
```

**Expected**: `401 Unauthorized`

**What happens**: WASM filter validates JWT but rejects due to missing pass-key

#### Test 4: Both pass-key and JWT (Success Case)

```bash
curl -v \
  -H "pass-key: test-pass-key-12345" \
  -H "Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IlRlc3QgVXNlciIsImlhdCI6MTUxNjIzOTAyMiwiZXhwIjo5OTk5OTk5OTk5fQ.4Adcj0PYg1dJ8RXB1xKLrgbWxPHP7w9C8q5HN_8u4u8" \
  http://test-backend.cilium-test.svc.cluster.local:8080/health
```

**Expected**: `200 OK`

**What happens**: WASM filter validates both credentials and forwards request to backend

#### Test 5: POST Request with Authentication

```bash
curl -v -X POST \
  -H "pass-key: test-pass-key-12345" \
  -H "Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IlRlc3QgVXNlciIsImlhdCI6MTUxNjIzOTAyMiwiZXhwIjo5OTk5OTk5OTk5fQ.4Adcj0PYg1dJ8RXB1xKLrgbWxPHP7w9C8q5HN_8u4u8" \
  -H "Content-Type: application/json" \
  -d '{"message":"test data"}' \
  http://test-backend.cilium-test.svc.cluster.local:8080/echo
```

**Expected**: `200 OK` with echoed response

### Option 2: One-Liner Tests

Run single-command tests (pod is auto-deleted after execution):

```bash
# Test 1: No auth
kubectl run test-no-auth --image=curlimages/curl:latest --rm -it --restart=Never -n cilium-test -- \
  curl -s -w "\nHTTP: %{http_code}\n" http://test-backend.cilium-test.svc.cluster.local:8080/health

# Test 2: Pass-key only
kubectl run test-passkey --image=curlimages/curl:latest --rm -it --restart=Never -n cilium-test -- \
  curl -s -w "\nHTTP: %{http_code}\n" -H "pass-key: test-pass-key-12345" \
  http://test-backend.cilium-test.svc.cluster.local:8080/health

# Test 3: Full auth (should succeed)
kubectl run test-full-auth --image=curlimages/curl:latest --rm -it --restart=Never -n cilium-test -- \
  curl -s -w "\nHTTP: %{http_code}\n" \
  -H "pass-key: test-pass-key-12345" \
  -H "Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IlRlc3QgVXNlciIsImlhdCI6MTUxNjIzOTAyMiwiZXhwIjo5OTk5OTk5OTk5fQ.4Adcj0PYg1dJ8RXB1xKLrgbWxPHP7w9C8q5HN_8u4u8" \
  http://test-backend.cilium-test.svc.cluster.local:8080/health
```

### Option 3: Port-Forward Testing

**⚠️ Warning**: Port-forwarding may bypass the WASM filter depending on your Cilium configuration. Use cluster-internal testing for accurate results.

```bash
# Terminal 1: Port-forward
kubectl -n cilium-test port-forward svc/test-backend 8080:8080

# Terminal 2: Test
curl -v http://localhost:8080/health
curl -v -H "pass-key: test-pass-key-12345" http://localhost:8080/health
curl -v -H "pass-key: test-pass-key-12345" \
     -H "Authorization: Bearer eyJh..." \
     http://localhost:8080/health
```

## Using Test Credentials ConfigMap

The test credentials are available as a ConfigMap in the cluster:

```bash
# View credentials
kubectl -n cilium-test get configmap test-credentials -o yaml

# Use in a pod
kubectl run test-with-config \
  --image=curlimages/curl:latest \
  --rm -it --restart=Never \
  -n cilium-test \
  --env="PASS_KEY=$(kubectl -n cilium-test get configmap test-credentials -o jsonpath='{.data.PASS_KEY}')" \
  --env="VALID_JWT=$(kubectl -n cilium-test get configmap test-credentials -o jsonpath='{.data.VALID_JWT}')" \
  -- sh -c 'curl -v -H "pass-key: $PASS_KEY" -H "Authorization: Bearer $VALID_JWT" http://test-backend.cilium-test.svc.cluster.local:8080/health'
```

## Verifying WASM Filter Execution

### Check WASM Filter Logs

```bash
# View Envoy logs
kubectl -n kube-system logs -l k8s-app=cilium-envoy --tail=100

# Filter for WASM-related logs
kubectl -n kube-system logs -l k8s-app=cilium-envoy --tail=100 | grep -i wasm

# Look for auth filter logs
kubectl -n kube-system logs -l k8s-app=cilium-envoy --tail=100 | grep -i "oxy_money"

# Watch logs in real-time while testing
kubectl -n kube-system logs -l k8s-app=cilium-envoy -f | grep -E "wasm|401|auth"
```

### Check Filter Configuration

```bash
# View CiliumEnvoyConfig
kubectl -n cilium-test get ciliumenvoyconfig wasm-http-filter -o yaml

# Check if WASM URL is configured
kubectl -n cilium-test get ciliumenvoyconfig wasm-http-filter \
  -o jsonpath='{.spec.resources[0].filter_chains[0].filters[0].typed_config.http_filters[0].typed_config.config.vm_config.code.remote.http_uri.uri}'
```

Expected output:
```
https://res.cloudinary.com/dohipaqvk/raw/upload/v1764100796/oxy_money_auth_filter_yos7rp.wasm
```

## Expected Response Headers

When the WASM filter processes requests, it may add custom headers:

### Rejected Request (401)
```
HTTP/1.1 401 Unauthorized
x-wasm-filter: oxy_money_auth_filter
x-auth-failure-reason: missing_pass_key | missing_jwt | invalid_credentials
```

### Accepted Request (200)
```
HTTP/1.1 200 OK
x-wasm-filter: oxy_money_auth_filter
x-auth-success: true
```

**Note**: Exact headers depend on your WASM filter implementation.

## Troubleshooting

### Test Returns 200 Without Authentication

**Problem**: Requests succeed without proper auth headers

**Possible causes**:
1. WASM filter not loaded
2. Network policy not applying L7 rules
3. Request bypassing Envoy proxy

**Solutions**:

```bash
# Check if WASM filter is loaded
kubectl -n kube-system logs -l k8s-app=cilium-envoy | grep -i "wasm.*loaded"

# Verify CiliumEnvoyConfig is applied
kubectl -n cilium-test get ciliumenvoyconfig

# Check network policy
kubectl -n cilium-test get ciliumnetworkpolicy test-backend-l7-policy -o yaml

# Verify Envoy is processing traffic
kubectl -n kube-system logs -l k8s-app=cilium-envoy -f
```

### Test Returns 503 Service Unavailable

**Problem**: Cannot reach backend

**Solutions**:

```bash
# Check backend pods
kubectl -n cilium-test get pods -l app=test-backend

# Check service endpoints
kubectl -n cilium-test get endpoints test-backend

# Check pod logs
kubectl -n cilium-test logs -l app=test-backend
```

### WASM Filter Not Loading

**Problem**: WASM module download fails

**Solutions**:

```bash
# Check if WASM URL is accessible from cluster
kubectl run curl-test --image=curlimages/curl:latest --rm -it --restart=Never -- \
  curl -I https://res.cloudinary.com/dohipaqvk/raw/upload/v1764100796/oxy_money_auth_filter_yos7rp.wasm

# Check Envoy logs for download errors
kubectl -n kube-system logs -l k8s-app=cilium-envoy | grep -i "wasm.*error\|wasm.*fail"

# Verify cluster can make HTTPS connections
kubectl -n cilium-test get ciliumenvoyconfig wasm-http-filter \
  -o jsonpath='{.spec.resources[2]}' | grep -A5 transport_socket
```

### JWT Validation Fails

**Problem**: Valid JWT is rejected

**Possible causes**:
1. JWT expired
2. JWT signed with wrong secret
3. JWT missing required claims

**Debug steps**:

```bash
# Decode JWT (header and payload only)
echo "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IlRlc3QgVXNlciIsImlhdCI6MTUxNjIzOTAyMiwiZXhwIjo5OTk5OTk5OTk5fQ" | \
  cut -d. -f2 | base64 -d | jq .

# Check expiration
# Ensure 'exp' claim is in the future (Unix timestamp)

# Generate a new JWT with correct secret
# See test-credentials.env for instructions
```

## Advanced Testing

### Load Testing with Authentication

```bash
# Install hey (HTTP load testing tool)
kubectl run load-test --image=williamyeh/hey:latest --rm -it --restart=Never -n cilium-test -- \
  /hey -n 100 -c 10 \
  -H "pass-key: test-pass-key-12345" \
  -H "Authorization: Bearer eyJh..." \
  http://test-backend.cilium-test.svc.cluster.local:8080/health
```

### Testing with Invalid JWT

```bash
# Test with malformed JWT
kubectl run test-bad-jwt --image=curlimages/curl:latest --rm -it --restart=Never -n cilium-test -- \
  curl -v -H "pass-key: test-pass-key-12345" -H "Authorization: Bearer invalid.jwt.token" \
  http://test-backend.cilium-test.svc.cluster.local:8080/health

# Expected: 401 Unauthorized
```

### Testing Header Case Sensitivity

```bash
# Test if headers are case-sensitive
curl -v -H "Pass-Key: test" -H "authorization: Bearer xxx" ...
curl -v -H "PASS-KEY: test" -H "AUTHORIZATION: Bearer xxx" ...
```

## Integration with CI/CD

Add to your CI/CD pipeline:

```yaml
# Example: GitHub Actions
- name: Test WASM Filter Authentication
  run: |
    cd cilium-local-test
    ./test-auth.sh

# Example: GitLab CI
test-auth:
  script:
    - cd cilium-local-test
    - ./test-auth.sh
  only:
    - main
```

## Monitoring and Observability

### Hubble for Traffic Visualization

```bash
# Port-forward Hubble UI
kubectl port-forward -n kube-system svc/hubble-ui 12000:80

# Open: http://localhost:12000
# Select namespace: cilium-test
# Watch HTTP traffic and auth rejections
```

### Metrics

```bash
# Envoy metrics
kubectl exec -n kube-system daemonset/cilium-envoy -- curl -s localhost:9090/stats | grep wasm

# Cilium metrics
kubectl exec -n kube-system daemonset/cilium -- cilium metrics list | grep -i policy
```

## Summary

✅ **Automated Testing**: Run `./test-auth.sh`
✅ **Manual Testing**: Interactive pod with curl commands
✅ **Expected Behavior**:
  - No pass-key → 401
  - Pass-key only → 401
  - JWT only → 401
  - Both → 200

For more information, see [README.md](README.md) and [QUICKSTART.md](QUICKSTART.md).
