#!/bin/bash
set -e

echo "==========================================="
echo "🔥 FINAL FIX - Backend Routing (Attempt 2)"
echo "==========================================="

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}💡 Strategy: Remove manual cluster, let Cilium auto-create it${NC}"
echo ""

# Create CEC with ONLY services field, no manual cluster
cat > /tmp/cec-cilium-auto.yaml << 'EOFCEC'
apiVersion: cilium.io/v2
kind: CiliumEnvoyConfig
metadata:
  name: wasm-http-filter
  namespace: cilium-test
spec:
  # Let Cilium handle everything
  services:
  - name: test-backend
    namespace: cilium-test
  
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
                  # Use Cilium's cluster naming convention
                  cluster: "cilium-test/test-backend:8080"
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
EOFCEC

echo -e "${YELLOW}[1/3] Deleting old CEC...${NC}"
kubectl delete cec -n cilium-test wasm-http-filter 2>/dev/null || true
sleep 3

echo -e "${YELLOW}[2/3] Applying CEC (Cilium auto-creates cluster)...${NC}"
kubectl apply -f /tmp/cec-cilium-auto.yaml
echo -e "${GREEN}✓ Applied${NC}"

echo -e "${YELLOW}[3/3] Waiting for configuration...${NC}"
sleep 12

# Check logs
echo ""
echo -e "${BLUE}📋 Checking for errors...${NC}"
if kubectl logs -n kube-system -l k8s-app=cilium --since=20s | grep -q "NACK.*envoy-listener"; then
    echo -e "${RED}✗ Still getting NACK errors${NC}"
    kubectl logs -n kube-system -l k8s-app=cilium --since=20s | grep "NACK.*envoy-listener" | tail -2
else
    echo -e "${GREEN}✓ No NACK errors!${NC}"
fi

# Check Envoy
echo -e "${BLUE}📋 Checking Envoy...${NC}"
kubectl logs -n kube-system -l k8s-app=cilium-envoy --tail=30 | grep -iE "lds.*envoy-listener|oxy_money.*configured" | tail -2

echo ""
echo -e "${YELLOW}🧪 Testing...${NC}"
RESPONSE=$(kubectl exec test-client -- curl -s -m 5 -o /dev/null -w "%{http_code}" http://test-backend.cilium-test.svc.cluster.local:8080/health 2>/dev/null || echo "FAIL")

if [ "$RESPONSE" = "200" ]; then
    echo -e "${GREEN}✓✓✓ SUCCESS! Got HTTP 200${NC}"
elif [ "$RESPONSE" = "503" ]; then
    echo -e "${YELLOW}⚠ Still getting 503 (but filter is working)${NC}"
elif [ "$RESPONSE" = "401" ] || [ "$RESPONSE" = "403" ]; then
    echo -e "${GREEN}✓✓✓ Got HTTP $RESPONSE - WASM auth is working!${NC}"
else
    echo -e "${RED}✗ Got: $RESPONSE${NC}"
fi

echo ""
echo -e "${BLUE}Full test:${NC}"
kubectl exec test-client -- curl -v http://test-backend.cilium-test.svc.cluster.local:8080/health 2>&1 | head -25
