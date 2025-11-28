# Issues Faced and Solutions - WASM Filter Deployment

## Complete Timeline of Issues and Resolutions

### Issue 1: Remote WASM Fetch Failure
**Problem**: Envoy couldn't fetch WASM module from Cloudinary URL
```
Error: Retry limit exceeded for fetching data from remote data source
```

**Root Cause**: Network/connectivity issues from Envoy pods to external URLs

**Solution**: 
- Switched to **local file loading**
- Copied WASM file to all Kind nodes at `/var/lib/cilium/wasm/oxy_money_auth.wasm`
- Used hostPath volume mount in Cilium Envoy DaemonSet
- Updated CEC to use `local.filename` instead of `remote.http_uri`

**Files Modified**:
- `/tmp/deploy_wasm_local.sh` - Script to copy WASM to nodes
- Cilium Envoy DaemonSet - Added volume mount

---

### Issue 2: Missing SHA256 Hash
**Problem**: 
```
RemoteDataSourceValidationError.Sha256: value length must be at least 1 characters
```

**Root Cause**: WASM remote config required SHA256 hash for validation

**Solution**: Added correct SHA256 hash to CEC configuration
```yaml
sha256: "ec7f73313ecf399b58e146a4eee6c298b3fb8e2bb5930bcd2d4ade0482ae902a"
```

---

### Issue 3: Cilium Auto-Cluster Creation Failed
**Problem**: CiliumEnvoyConfig `services` or `backendServices` fields didn't create backend cluster
```
Error: route: unknown cluster 'cilium-test/test-backend'
Error: route: unknown cluster 'cilium-test/test-backend:8080'
```

**Root Cause**: Cilium v1.18.4 has bugs in automatic cluster creation from `services` field

**Solution**: **Manual cluster definition**
- Created independent listener with manual cluster definition
- Used ClusterIP directly instead of DNS names
- Bypassed Cilium's broken auto-creation mechanism

---

### Issue 4: DNS Resolution in Envoy
**Problem**: Envoy couldn't resolve K8s service names
```
no healthy upstream
```

**Root Cause**: STRICT_DNS type failing for internal K8s service names

**Solution**: Used ClusterIP directly
```yaml
address: 10.96.242.44  # Instead of test-backend.cilium-test.svc.cluster.local
port_value: 8080
```

---

### Issue 5: Cross-Namespace Service Selection
**Problem**: Service in `cilium-test` couldn't select Envoy pods in `kube-system`

**Root Cause**: Kubernetes services can only select pods in same namespace

**Solution**: Access Envoy directly via pod IP or create service in `kube-system`

---

### Issue 6: Windows Line Endings in Scripts
**Problem**: 
```
syntax error: unexpected end of file
```

**Root Cause**: CRLF line endings from Windows

**Solution**: Convert to Unix line endings
```bash
sed -i 's/\r$//' script.sh
```

---

## Final Working Solution

### Architecture
```
Client
  ↓
Envoy Pod (172.18.0.4:10000)
  ↓
WASM Filter (oxy_money_auth) ← LOADED FROM LOCAL FILE
  ↓ (validates auth)
  ├─ No auth? → HTTP 401
  └─ Valid auth? → Forward ↓
                    Backend Cluster (10.96.242.44:8080)
```

### Key Configuration
**CiliumEnvoyConfig**: `kube-system/wasm-filter-independent`
```yaml
spec:
  resources:
  - "@type": type.googleapis.com/envoy.config.listener.v3.Listener
    name: wasm_proxy_listener
    address:
      socket_address:
        address: 0.0.0.0
        port_value: 10000
    filter_chains:
    - filters:
      - name: envoy.filters.network.http_connection_manager
        typed_config:
          http_filters:
          - name: envoy.filters.http.wasm
            typed_config:
              config:
                code:
                  local:
                    filename: "/var/lib/cilium/wasm/oxy_money_auth.wasm"
  - "@type": type.googleapis.com/envoy.config.cluster.v3.Cluster
    name: test_backend_cluster
    type: STRICT_DNS
    load_assignment:
      endpoints:
      - lb_endpoints:
        - endpoint:
            address:
              socket_address:
                address: 10.96.242.44  # ClusterIP
                port_value: 8080
```

### Deployment Steps
1. Copy WASM to all Kind nodes
2. Patch Cilium Envoy DaemonSet with volume mount
3. Create independent CEC with local file loading
4. Test via Envoy pod IP on port 10000

### Verification
```bash
# Get Envoy IP
ENVOY_IP=$(kubectl get pod -n kube-system cilium-envoy-4sw55 -o jsonpath='{.status.podIP}')

# Test - should get 401
kubectl exec test-client -- curl -I http://$ENVOY_IP:10000/api/protected

# Monitor WASM
kubectl logs -n kube-system -l k8s-app=cilium-envoy -f | grep oxy_money
```

---

## Lessons Learned

1. **Local file mounting > Remote HTTP fetch** for WASM in K8s
2. **Manual cluster definitions > Cilium auto-creation** (in v1.18.4)
3. **ClusterIP > DNS names** for reliability in Envoy
4. **Independent listeners** avoid conflicts with framework limitations
5. **Always check line endings** when copying scripts from Windows
