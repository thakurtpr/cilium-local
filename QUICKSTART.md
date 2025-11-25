# Quick Start Guide

Get up and running with the Cilium + WASM filter test setup in under 5 minutes.

## Prerequisites

- kind cluster (1 control-plane + 2 workers) - ✓ Already created
- kubectl installed
- helm v3.x installed

## 1. Install Everything

```bash
cd cilium-local-test
./install.sh local
```

This will:
- ✓ Install Cilium with Envoy support
- ✓ Deploy the test backend application
- ✓ Configure Envoy with the WASM filter
- ✓ Set up network policies

## 2. Verify Installation

```bash
./test.sh
```

Expected output: All tests passed ✓

## 3. Test the WASM Filter Authentication

The `oxy_money_auth_filter` requires **BOTH** headers for authentication:
- `pass-key: test-pass-key-12345`
- `Authorization: Bearer <JWT>`

### Automated Test Suite (Recommended)

```bash
./test-auth.sh
```

Expected results:
- ✗ No headers → 401
- ✗ Only pass-key → 401
- ✗ Only JWT → 401
- ✓ Both headers → 200

### Manual Testing

```bash
# Start an interactive test pod
kubectl run -n cilium-test test-client \
  --image=curlimages/curl:latest \
  --rm -it --restart=Never \
  -- sh

# Inside the pod:

# Test 1: No auth (should fail with 401)
curl -v http://test-backend.cilium-test.svc.cluster.local:8080/health

# Test 2: Only pass-key (should fail with 401)
curl -v -H "pass-key: test-pass-key-12345" \
  http://test-backend.cilium-test.svc.cluster.local:8080/health

# Test 3: Both headers (should succeed with 200)
curl -v \
  -H "pass-key: test-pass-key-12345" \
  -H "Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IlRlc3QgVXNlciIsImlhdCI6MTUxNjIzOTAyMiwiZXhwIjo5OTk5OTk5OTk5fQ.4Adcj0PYg1dJ8RXB1xKLrgbWxPHP7w9C8q5HN_8u4u8" \
  http://test-backend.cilium-test.svc.cluster.local:8080/health

# Test 4: POST with auth
curl -v -X POST \
  -H "pass-key: test-pass-key-12345" \
  -H "Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IlRlc3QgVXNlciIsImlhdCI6MTUxNjIzOTAyMiwiZXhwIjo5OTk5OTk5OTk5fQ.4Adcj0PYg1dJ8RXB1xKLrgbWxPHP7w9C8q5HN_8u4u8" \
  -H "Content-Type: application/json" \
  -d '{"message":"test"}' \
  http://test-backend.cilium-test.svc.cluster.local:8080/echo
```

### Quick One-Liners

```bash
# Test without auth (should get 401)
kubectl run test-no-auth --image=curlimages/curl:latest --rm -it --restart=Never -n cilium-test -- \
  curl -s -w "\nHTTP: %{http_code}\n" http://test-backend.cilium-test.svc.cluster.local:8080/health

# Test with full auth (should get 200)
kubectl run test-full-auth --image=curlimages/curl:latest --rm -it --restart=Never -n cilium-test -- \
  curl -s -w "\nHTTP: %{http_code}\n" \
  -H "pass-key: test-pass-key-12345" \
  -H "Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IlRlc3QgVXNlciIsImlhdCI6MTUxNjIzOTAyMiwiZXhwIjo5OTk5OTk5OTk5fQ.4Adcj0PYg1dJ8RXB1xKLrgbWxPHP7w9C8q5HN_8u4u8" \
  http://test-backend.cilium-test.svc.cluster.local:8080/health
```

## 4. Verify WASM Filter is Running

```bash
# Check Envoy logs for WASM filter
kubectl -n kube-system logs -l k8s-app=cilium-envoy --tail=50 | grep -i wasm

# Should see logs about:
# - Loading WASM module from Cloudinary URL
# - WASM VM initialization
# - Filter execution
```

## 5. View Traffic in Hubble UI

```bash
# Port-forward Hubble UI
kubectl port-forward -n kube-system svc/hubble-ui 12000:80

# Open in browser: http://localhost:12000
# Select namespace: cilium-test
# Watch HTTP traffic flow through Envoy
```

## Common Issues

### Backend pods not ready?
```bash
kubectl -n cilium-test get pods
kubectl -n cilium-test logs -l app=test-backend
```

### WASM filter not loading?
```bash
kubectl -n kube-system logs -l k8s-app=cilium-envoy | grep -i wasm
# Check for download errors or initialization failures
```

### Cilium not working?
```bash
kubectl -n kube-system get pods -l k8s-app=cilium
kubectl exec -n kube-system ds/cilium -- cilium status
```

## Cleanup

```bash
# Remove test stack (keep Cilium)
./uninstall.sh --keep-cilium

# Remove everything including Cilium
./uninstall.sh
```

## What's Happening?

```
Client Request
      ↓
Cilium Network Policy (L7 HTTP)
      ↓
Envoy HTTP Filter Chain
  ├─ WASM Filter (your auth filter) ← Loaded from Cloudinary
  └─ Router Filter
      ↓
Backend Service (test-backend)
```

The WASM filter executes on **every HTTP request** before it reaches the backend.

## Next Steps

1. **Modify WASM filter behavior**: Update the filter URL in `overlays/local/kustomization.yaml`
2. **Add custom routes**: Edit `base/envoy-config.yaml`
3. **Change environment**: Run `./install.sh dev` or `./install.sh stage`
4. **Monitor traffic**: Use Hubble UI to visualize request flow
5. **Debug issues**: Check logs with `kubectl logs -n kube-system -l k8s-app=cilium-envoy`

## Key Files

- `base/envoy-config.yaml` - Envoy + WASM configuration
- `base/network-policy.yaml` - L7 HTTP policy
- `base/backend-app.yaml` - Test backend
- `overlays/*/kustomization.yaml` - Environment config

---

For detailed documentation, see [README.md](README.md)
