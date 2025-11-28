#!/bin/bash
set -e

echo "=================================="
echo "WASM Local File Deployment Script"
echo "=================================="

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

WASM_FILE=/tmp/wasm_filter.wasm
WASM_SHA256=ec7f73313ecf399b58e146a4eee6c298b3fb8e2bb5930bcd2d4ade0482ae902a

# Step 1: Verify WASM file exists locally
echo -e "${YELLOW}[1/6] Verifying WASM file...${NC}"
if [ ! -f "$WASM_FILE" ]; then
    echo -e "${RED}ERROR: WASM file not found at $WASM_FILE${NC}"
    exit 1
fi

LOCAL_SHA=$(sha256sum $WASM_FILE | awk '{print $1}')
if [ "$LOCAL_SHA" != "$WASM_SHA256" ]; then
    echo -e "${RED}ERROR: WASM SHA256 mismatch${NC}"
    echo "Expected: $WASM_SHA256"
    echo "Got: $LOCAL_SHA"
    exit 1
fi
echo -e "${GREEN}✓ WASM file verified (SHA256 match)${NC}"

# Step 2: Copy WASM to all Kind nodes
echo -e "${YELLOW}[2/6] Copying WASM to Kind nodes...${NC}"
NODES=("cilium-demo-control-plane" "cilium-demo-worker" "cilium-demo-worker2")

for NODE in "${NODES[@]}"; do
    echo "  → Copying to $NODE"
    # Create directory and copy file
    docker exec $NODE mkdir -p /var/lib/cilium/wasm
    cat $WASM_FILE | docker exec -i $NODE sh -c 'cat > /var/lib/cilium/wasm/oxy_money_auth.wasm'
    docker exec $NODE chmod 644 /var/lib/cilium/wasm/oxy_money_auth.wasm
    
    # Verify
    REMOTE_SHA=$(docker exec $NODE sha256sum /var/lib/cilium/wasm/oxy_money_auth.wasm | awk '{print $1}')
    if [ "$REMOTE_SHA" != "$WASM_SHA256" ]; then
        echo -e "${RED}ERROR: SHA256 mismatch on $NODE${NC}"
        exit 1
    fi
    echo -e "${GREEN}    ✓ $NODE verified${NC}"
done

# Step 3: Patch Cilium Envoy DaemonSet to mount WASM
echo -e "${YELLOW}[3/6] Patching cilium-envoy DaemonSet...${NC}"

# Check if already patched
if kubectl get ds -n kube-system cilium-envoy -o yaml | grep -q '/var/lib/cilium/wasm'; then
    echo -e "${GREEN}✓ DaemonSet already has WASM volume mount${NC}"
else
    echo "  → Adding volume mount to cilium-envoy..."
    kubectl patch daemonset cilium-envoy -n kube-system --type='json' -p='[
      {
        "op": "add",
        "path": "/spec/template/spec/volumes/-",
        "value": {
          "name": "wasm-files",
          "hostPath": {
            "path": "/var/lib/cilium/wasm",
            "type": "DirectoryOrCreate"
          }
        }
      },
      {
        "op": "add",
        "path": "/spec/template/spec/containers/0/volumeMounts/-",
        "value": {
          "name": "wasm-files",
          "mountPath": "/var/lib/cilium/wasm",
          "readOnly": true
        }
      }
    ]'
    
    echo "  → Waiting for cilium-envoy pods to restart..."
    kubectl rollout status daemonset/cilium-envoy -n kube-system --timeout=120s
    sleep 5
    echo -e "${GREEN}✓ DaemonSet patched and rolled out${NC}"
fi

# Step 4: Verify WASM file is accessible in Envoy pods
echo -e "${YELLOW}[4/6] Verifying WASM file in Envoy pods...${NC}"
ENVOY_POD=$(kubectl get pods -n kube-system -l k8s-app=cilium-envoy -o name | head -1)
if [ -z "$ENVOY_POD" ]; then
    echo -e "${RED}ERROR: No cilium-envoy pods found${NC}"
    exit 1
fi

POD_SHA=$(kubectl exec -n kube-system $ENVOY_POD -- sha256sum /var/lib/cilium/wasm/oxy_money_auth.wasm 2>/dev/null | awk '{print $1}')
if [ "$POD_SHA" != "$WASM_SHA256" ]; then
    echo -e "${RED}ERROR: WASM file not accessible in Envoy pod or SHA mismatch${NC}"
    exit 1
fi
echo -e "${GREEN}✓ WASM file accessible in Envoy pods${NC}"

# Step 5: Create CiliumEnvoyConfig with local file loading
echo -e "${YELLOW}[5/6] Creating CiliumEnvoyConfig...${NC}"

cat > /tmp/cec-local-wasm.yaml << 'EOFCEC'
apiVersion: cilium.io/v2
kind: CiliumEnvoyConfig
metadata:
  name: wasm-http-filter
  namespace: cilium-test
spec:
  services:
  - name: test-backend
    namespace: cilium-test
    listener: envoy-listener
  resources:
  - "@type": type.googleapis.com/envoy.config.listener.v3.Listener
    name: envoy-listener
    filter_chains:
    - filters:
      - name: envoy.filters.network.http_connection_manager
        typed_config:
          "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
          stat_prefix: envoy_wasm_stats
          codec_type: AUTO
          route_config:
            name: local_route
            virtual_hosts:
            - name: backend_service
              domains: ["*"]
              routes:
              - match: {prefix: "/"}
                route:
                  cluster: manual-backend-cluster
                  timeout: 30s
          http_filters:
          - name: envoy.filters.http.wasm
            typed_config:
              "@type": type.googleapis.com/envoy.extensions.filters.http.wasm.v3.Wasm
              config:
                name: oxy_money_auth_filter
                root_id: oxy_auth_root
                vm_config:
                  vm_id: oxy_money_auth_vm
                  runtime: envoy.wasm.runtime.v8
                  code:
                    local:
                      filename: "/var/lib/cilium/wasm/oxy_money_auth.wasm"
                  allow_precompiled: true
                configuration:
                  "@type": type.googleapis.com/google.protobuf.StringValue
                  value: |
                    {
                      "environment": "local"
                    }
          - name: envoy.filters.http.router
            typed_config:
              "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router
  - "@type": type.googleapis.com/envoy.config.cluster.v3.Cluster
    name: manual-backend-cluster
    connect_timeout: 5s
    type: STRICT_DNS
    lb_policy: ROUND_ROBIN
    load_assignment:
      cluster_name: manual-backend-cluster
      endpoints:
      - lb_endpoints:
        - endpoint:
            address:
              socket_address:
                address: test-backend.cilium-test.svc.cluster.local
                port_value: 8080
    typed_extension_protocol_options:
      envoy.extensions.upstreams.http.v3.HttpProtocolOptions:
        "@type": type.googleapis.com/envoy.extensions.upstreams.http.v3.HttpProtocolOptions
        explicit_http_config:
          http_protocol_options: {}
EOFCEC

# Delete existing CEC if present
kubectl delete cec -n cilium-test wasm-http-filter 2>/dev/null || true
sleep 2

# Apply new CEC
kubectl apply -f /tmp/cec-local-wasm.yaml
echo -e "${GREEN}✓ CiliumEnvoyConfig created${NC}"

# Step 6: Wait and verify configuration
echo -e "${YELLOW}[6/6] Verifying WASM filter loading...${NC}"
sleep 10

# Check Envoy logs for WASM loading
echo "  → Checking Envoy logs..."
kubectl logs -n kube-system $ENVOY_POD --tail=100 | grep -i 'oxy_money_auth_filter\|wasm.*load' | tail -5 || true

# Check if listener was accepted
if kubectl logs -n kube-system -l k8s-app=cilium-envoy --tail=50 | grep -q 'lds: add/update listener.*envoy-listener'; then
    echo -e "${GREEN}✓ Listener configuration accepted${NC}"
else
    echo -e "${YELLOW}⚠ Could not confirm listener status (check logs)${NC}"
fi

echo ""
echo -e "${GREEN}================================${NC}"
echo -e "${GREEN}Deployment Complete!${NC}"
echo -e "${GREEN}================================${NC}"
echo ""
echo "Run verification commands:"
echo "  bash /tmp/verify_wasm.sh"
