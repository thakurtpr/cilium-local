# Cilium + Envoy + WASM Filter Test Setup

A self-contained local test environment for validating a WASM-based Envoy HTTP filter running with Cilium on a kind Kubernetes cluster.

## Overview

This setup provides:
- **Cilium CNI** with Envoy proxy support for L7 traffic management
- **Envoy HTTP filter chain** with a WASM filter loaded from a public URL
- **Test backend application** with explicit GET and POST routes
- **Environment-aware configuration** using Kustomize overlays

## Architecture

```
┌─────────────┐
│   Request   │
└──────┬──────┘
       │
       v
┌─────────────────────────────────────┐
│  Cilium Network Policy (L7)         │
│  - Intercepts HTTP traffic          │
└──────┬──────────────────────────────┘
       │
       v
┌─────────────────────────────────────┐
│  Envoy Proxy (CiliumEnvoyConfig)    │
│  ┌───────────────────────────────┐  │
│  │  HTTP Filter Chain            │  │
│  │  1. WASM Filter  ←─────────┐  │  │
│  │     (Auth/Processing)      │  │  │
│  │  2. Router Filter          │  │  │
│  └───────────────────────────────┘  │
│          │                           │
│          │ Loads WASM from:          │
│          │ Cloudinary URL ──────────┘│
└──────────┬──────────────────────────┘
           │
           v
    ┌──────────────┐
    │   Backend    │
    │   Service    │
    │  (Echo Pod)  │
    └──────────────┘
```

## Directory Structure

```
cilium-local-test/
├── README.md                          # This file
├── base/                              # Base Kubernetes manifests
│   ├── namespace.yaml                 # cilium-test namespace
│   ├── config.yaml                    # Environment configuration ConfigMap
│   ├── backend-app.yaml               # Test backend deployment & service
│   ├── envoy-config.yaml              # CiliumEnvoyConfig with WASM filter
│   ├── network-policy.yaml            # CiliumNetworkPolicy for L7 routing
│   ├── cilium-values.yaml             # Cilium Helm values
│   └── kustomization.yaml             # Base kustomization
├── overlays/                          # Environment-specific overlays
│   ├── local/                         # Local environment (2 replicas)
│   │   └── kustomization.yaml
│   ├── dev/                           # Dev environment (3 replicas)
│   │   └── kustomization.yaml
│   ├── stage/                         # Stage environment (4 replicas)
│   │   └── kustomization.yaml
│   └── prod/                          # Prod environment (6 replicas)
│       └── kustomization.yaml
```

## Prerequisites

Before starting, ensure you have:

1. **kind cluster** (already created with 1 control-plane + 2 workers)
2. **kubectl** - Kubernetes CLI
3. **helm** - Kubernetes package manager (v3.x)
4. **kustomize** - Configuration management (or use `kubectl -k`)

## Installation Steps

### Step 1: Install Cilium with Envoy Support

```bash
# Add Cilium Helm repository
helm repo add cilium https://helm.cilium.io/
helm repo update

# Install Cilium with Envoy enabled
helm install cilium cilium/cilium \
  --namespace kube-system \
  --values cilium-local-test/base/cilium-values.yaml \
  --wait

# Verify Cilium installation
kubectl -n kube-system get pods -l k8s-app=cilium
kubectl -n kube-system get pods -l k8s-app=cilium-envoy

# Check Cilium status
kubectl exec -n kube-system ds/cilium -- cilium status
```

### Step 2: Deploy the Test Stack

Choose your environment (local/dev/stage/prod) and apply the manifests:

#### For Local Environment:
```bash
kubectl apply -k cilium-local-test/overlays/local/

# Verify deployment
kubectl -n cilium-test get all
kubectl -n cilium-test get ciliumenvoyconfig
kubectl -n cilium-test get ciliumnetworkpolicy
```

#### For Other Environments:
```bash
# Dev environment
kubectl apply -k cilium-local-test/overlays/dev/

# Stage environment
kubectl apply -k cilium-local-test/overlays/stage/

# Prod environment
kubectl apply -k cilium-local-test/overlays/prod/
```

### Step 3: Verify Deployment

```bash
# Check all resources
kubectl -n cilium-test get all

# Check CiliumEnvoyConfig
kubectl -n cilium-test get ciliumenvoyconfig wasm-http-filter -o yaml

# Check CiliumNetworkPolicy
kubectl -n cilium-test get ciliumnetworkpolicy test-backend-l7-policy -o yaml

# Check ConfigMap
kubectl -n cilium-test get configmap test-environment-config -o yaml

# Check pod status
kubectl -n cilium-test get pods
kubectl -n cilium-test logs -l app=test-backend
```

## Testing the Setup

### Test 1: Verify Installation

First, verify all components are running:

```bash
# Run basic verification tests
./test.sh
```

This checks:
- Namespace exists
- Backend pods are ready
- Service has endpoints
- CiliumEnvoyConfig is deployed
- CiliumNetworkPolicy is deployed
- Cilium and Envoy pods are running

### Test 2: WASM Filter Authentication Tests (Recommended)

The `oxy_money_auth_filter` WASM filter implements two-factor authentication:
- Requires **both** `pass-key` header AND `Authorization: Bearer <JWT>` header
- Returns `401 Unauthorized` if either is missing

**Run the automated authentication test suite:**

```bash
# Run comprehensive auth tests
./test-auth.sh
```

This tests all scenarios:
1. ✗ No headers → 401
2. ✗ Only pass-key → 401
3. ✗ Only JWT → 401
4. ✓ Both pass-key + JWT → 200

**Expected Output:**
```
Test 2/5: Request WITHOUT pass-key header
Expected: 401 Unauthorized (WASM filter should reject)
Response Code: 401
✓ PASS: WASM filter correctly rejected request without pass-key (401)

Test 3/5: Request WITH pass-key but WITHOUT JWT
Expected: 401 Unauthorized (WASM filter should reject)
Response Code: 401
✓ PASS: WASM filter correctly rejected request with pass-key but no JWT (401)

Test 4/5: Request WITH both pass-key AND JWT
Expected: 200 OK (should reach backend)
Response Code: 200
✓ PASS: WASM filter correctly allowed authenticated request (200)
```

**Manual Testing:**

```bash
# Start interactive test pod
kubectl run -n cilium-test test-client \
  --image=curlimages/curl:latest \
  --rm -it --restart=Never \
  -- sh

# Inside the pod:

# Test 1: No auth (should get 401)
curl -v http://test-backend.cilium-test.svc.cluster.local:8080/health

# Test 2: Only pass-key (should get 401)
curl -v -H "pass-key: test-pass-key-12345" \
  http://test-backend.cilium-test.svc.cluster.local:8080/health

# Test 3: Both headers (should get 200)
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

**📖 For detailed authentication testing guide, see [AUTHENTICATION-TESTING.md](AUTHENTICATION-TESTING.md)**

### Test 3: Direct Service Test (Bypass Filter)

Test backend directly (may bypass WASM filter):

```bash
# Port-forward to the backend service
kubectl -n cilium-test port-forward svc/test-backend 8080:8080

# In another terminal, test the endpoints
curl http://localhost:8080/health
curl -X POST http://localhost:8080/echo -d '{"test": "data"}'
```

**⚠️ Note**: Port-forwarding may bypass the WASM filter. Use cluster-internal testing for accurate results.

### Test 4: Verify WASM Filter Execution

Check Envoy logs to see the WASM filter in action:

```bash
# View Envoy logs
kubectl -n kube-system logs -l k8s-app=cilium-envoy --tail=100

# Look for WASM-related log entries
kubectl -n kube-system logs -l k8s-app=cilium-envoy --tail=100 | grep -i wasm

# Look for auth filter logs
kubectl -n kube-system logs -l k8s-app=cilium-envoy --tail=100 | grep -i oxy_money

# Watch logs in real-time while testing
kubectl -n kube-system logs -l k8s-app=cilium-envoy -f | grep -E "wasm|401|auth"
```

### Test 5: Network Policy Verification

```bash
# Check if L7 policy is being enforced
kubectl -n cilium-test get ciliumnetworkpolicy

# Describe the policy
kubectl -n cilium-test describe ciliumnetworkpolicy test-backend-l7-policy

# Inspect Cilium endpoints
kubectl exec -n kube-system ds/cilium -- cilium endpoint list
```

## Environment Configuration

All environment-specific configuration is managed through Kustomize overlays. To change environments:

### Quick Environment Switch

```bash
# Apply local environment
kubectl apply -k cilium-local-test/overlays/local/

# Switch to dev
kubectl delete -k cilium-local-test/overlays/local/
kubectl apply -k cilium-local-test/overlays/dev/

# Switch to stage
kubectl delete -k cilium-local-test/overlays/dev/
kubectl apply -k cilium-local-test/overlays/stage/
```

### Environment Differences

| Environment | Replicas | CPU Request | Memory Limit |
|-------------|----------|-------------|--------------|
| local       | 2        | 100m        | 128Mi        |
| dev         | 3        | 100m        | 128Mi        |
| stage       | 4        | 100m        | 128Mi        |
| prod        | 6        | 200m        | 256Mi        |

### Customizing Environment Values

Edit the overlay's `kustomization.yaml`:

```yaml
configMapGenerator:
- name: test-environment-config
  namespace: cilium-test
  behavior: merge
  literals:
  - ENVIRONMENT=my-custom-env
  - WASM_FILTER_URL=https://your-custom-url.com/filter.wasm
  - CUSTOM_SETTING=value
```

## WASM Filter Details

### Current Configuration

- **WASM Module URL**: `https://res.cloudinary.com/dohipaqvk/raw/upload/v1764100796/oxy_money_auth_filter_yos7rp.wasm`
- **Filter Name**: `oxy_money_auth_filter`
- **VM Runtime**: `envoy.wasm.runtime.v8`
- **Position in Chain**: Before `envoy.filters.http.router`

### How the WASM Filter Works

1. **Request Flow**:
   - Client sends HTTP request
   - Cilium intercepts traffic via Network Policy
   - Envoy processes request through HTTP filter chain
   - **WASM filter executes** (authentication/processing logic)
   - Router filter forwards to backend

2. **Filter Chain** (defined in `envoy-config.yaml`):
```yaml
http_filters:
  - name: envoy.filters.http.wasm  # ← WASM filter runs here
    # ... WASM configuration
  - name: envoy.filters.http.router  # ← Must be last
```

3. **Routes Configuration**:
   - `GET /health` - Explicitly routed to backend
   - `POST /echo` - Explicitly routed to backend
   - `/* (catch-all)` - All other paths

### Updating the WASM Filter

To use a different WASM module:

1. Update the ConfigMap in your overlay:
```yaml
configMapGenerator:
- name: test-environment-config
  literals:
  - WASM_FILTER_URL=https://your-new-url.com/filter.wasm
```

2. Update the CiliumEnvoyConfig directly:
```bash
kubectl -n cilium-test edit ciliumenvoyconfig wasm-http-filter
# Modify the http_uri.uri field
```

3. Restart Envoy pods to reload:
```bash
kubectl -n kube-system rollout restart daemonset/cilium-envoy
```

## Troubleshooting

### WASM Module Not Loading

```bash
# Check Envoy logs for WASM errors
kubectl -n kube-system logs -l k8s-app=cilium-envoy | grep -i wasm

# Common issues:
# - URL not accessible from cluster
# - WASM module format incompatible with Envoy version
# - SHA256 mismatch (if specified)

# Verify URL accessibility from cluster
kubectl run -n cilium-test curl-test \
  --image=curlimages/curl:latest \
  --rm -it --restart=Never \
  -- curl -I https://res.cloudinary.com/dohipaqvk/raw/upload/v1764100796/oxy_money_auth_filter_yos7rp.wasm
```

### Backend Not Receiving Traffic

```bash
# Check service endpoints
kubectl -n cilium-test get endpoints test-backend

# Check pod labels match service selector
kubectl -n cilium-test get pods -l app=test-backend --show-labels

# Check Network Policy
kubectl -n cilium-test describe ciliumnetworkpolicy test-backend-l7-policy
```

### CiliumEnvoyConfig Not Applied

```bash
# Check CEC status
kubectl -n cilium-test get ciliumenvoyconfig -o wide

# Check Cilium operator logs
kubectl -n kube-system logs -l name=cilium-operator

# Validate CEC spec
kubectl -n cilium-test get ciliumenvoyconfig wasm-http-filter -o yaml
```

### Envoy Not Running

```bash
# Check if Envoy DaemonSet exists
kubectl -n kube-system get daemonset cilium-envoy

# Check Envoy pod status
kubectl -n kube-system get pods -l k8s-app=cilium-envoy

# Check Cilium configuration
kubectl -n kube-system get configmap cilium-config -o yaml | grep -i envoy

# Reinstall Cilium with Envoy enabled
helm upgrade cilium cilium/cilium \
  --namespace kube-system \
  --values cilium-local-test/base/cilium-values.yaml \
  --reuse-values
```

## Cleanup

### Remove Test Stack Only

```bash
kubectl delete -k cilium-local-test/overlays/local/
```

### Remove Everything Including Cilium

```bash
# Delete test stack
kubectl delete -k cilium-local-test/overlays/local/

# Uninstall Cilium
helm uninstall cilium -n kube-system

# Delete namespace
kubectl delete namespace cilium-test

# Clean up CRDs (optional)
kubectl get crd | grep cilium | awk '{print $1}' | xargs kubectl delete crd
```

## Key Files Reference

### Envoy Configuration
- **Location**: `base/envoy-config.yaml`
- **Type**: `CiliumEnvoyConfig`
- **Purpose**: Defines HTTP filter chain with WASM filter
- **Key Sections**:
  - HTTP Connection Manager
  - Route configuration (GET /health, POST /echo)
  - WASM filter configuration
  - Backend cluster definition

### Network Policy
- **Location**: `base/network-policy.yaml`
- **Type**: `CiliumNetworkPolicy`
- **Purpose**: L7 HTTP policy enforcement
- **Features**:
  - Method-based routing (GET, POST)
  - Path-based routing
  - Triggers Envoy proxy for L7 inspection

### Backend Application
- **Location**: `base/backend-app.yaml`
- **Image**: `mendhak/http-https-echo:31`
- **Endpoints**:
  - `GET /health` - Health check
  - `POST /echo` - Echo request body
  - `GET /*` - Any path (echo server responds to all)

## Advanced Usage

### Enable Hubble for Traffic Visibility

```bash
# Hubble is already enabled in cilium-values.yaml
# Access Hubble UI
kubectl port-forward -n kube-system svc/hubble-ui 12000:80

# Open browser: http://localhost:12000

# Use Hubble CLI
kubectl exec -n kube-system ds/cilium -- hubble observe --namespace cilium-test
```

### Add Custom Routes

Edit `base/envoy-config.yaml`:

```yaml
routes:
  - match:
      path: "/my-custom-route"
      headers:
      - name: ":method"
        string_match:
          exact: "GET"
    route:
      cluster: test-backend-cluster
```

### Pass Configuration to WASM Filter

Edit the WASM filter configuration in `base/envoy-config.yaml`:

```yaml
configuration:
  "@type": type.googleapis.com/google.protobuf.StringValue
  value: |
    {
      "environment": "local",
      "custom_setting": "value",
      "api_key": "test-key"
    }
```

## References

- [Cilium Documentation](https://docs.cilium.io/)
- [Cilium Envoy Configuration](https://docs.cilium.io/en/stable/network/servicemesh/envoy-introduction/)
- [Envoy WASM Filter](https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/wasm_filter)
- [Kustomize](https://kustomize.io/)

## License

This test setup is provided as-is for testing and development purposes.
