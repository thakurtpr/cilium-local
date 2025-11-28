#!/bin/bash
set -e

echo "======================================"
echo "🔧 FIXING BACKEND ROUTING - FINAL FIX"
echo "======================================"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}🎯 Root Cause Identified:${NC}"
echo "When using 'services' field, Cilium expects cluster named:"
echo "  'cilium-test/test-backend'"
echo "But we're routing to:"
echo "  'manual-backend-cluster'"
echo ""
echo -e "${YELLOW}Solution: Use backendServices to let Cilium auto-create the cluster${NC}"
echo ""

# Create new CEC with backendServices
cat > /tmp/cec-final-fix.yaml << 'EOFCEC'
apiVersion: cilium.io/v2
kind: CiliumEnvoyConfig
metadata:
  name: wasm-http-filter
  namespace: cilium-test
spec:
  # Use backendServices instead of services
  # This tells Cilium to create the backend cluster automatically
  backendServices:
  - name: test-backend
    namespace: cilium-test
    number: ["8080"]
  
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
          # Use RDS for dynamic routes
          rds:
            route_config_name: cilium-test/test-backend
            config_source:
              api_config_source:
                api_type: GRPC
                grpc_services:
                - envoy_grpc:
                    cluster_name: xds-grpc-cilium
                set_node_on_first_message_only: true
              resource_api_version: V3
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
EOFCEC

echo -e "${YELLOW}[1/3] Deleting old CEC...${NC}"
kubectl delete cec -n cilium-test wasm-http-filter 2>/dev/null || true
sleep 3

echo -e "${YELLOW}[2/3] Applying new CEC with backendServices...${NC}"
kubectl apply -f /tmp/cec-final-fix.yaml
echo -e "${GREEN}✓ CEC applied${NC}"

echo -e "${YELLOW}[3/3] Waiting for configuration to propagate...${NC}"
sleep 10

# Check status
echo ""
echo -e "${BLUE}Checking Cilium agent logs...${NC}"
kubectl logs -n kube-system -l k8s-app=cilium --tail=20 | grep -i "wasm-http-filter\|test-backend" | tail -5 || echo "No recent errors"

echo ""
echo -e "${BLUE}Checking Envoy logs...${NC}"
kubectl logs -n kube-system -l k8s-app=cilium-envoy --tail=50 | grep -iE "lds.*envoy-listener|wasm.*configured" | tail -3

echo ""
echo -e "${GREEN}=====================================${NC}"
echo -e "${GREEN}Configuration applied!${NC}"
echo -e "${GREEN}=====================================${NC}"
echo ""
echo "Test command:"
echo "  kubectl exec test-client -- curl -v http://test-backend.cilium-test.svc.cluster.local:8080/health"
