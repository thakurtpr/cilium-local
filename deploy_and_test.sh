#!/bin/bash
set -e

echo "=========================================="
echo "🚀 Deploy WASM and Test"
echo "=========================================="

# Load JWT
JWT_USER2=$(cat jwt_user2.txt)
JWT_ADMIN=$(cat jwt_admin.txt)

echo "[1/5] Copying WASM to all Kind nodes..."
for node in cilium-demo-control-plane cilium-demo-worker cilium-demo-worker2; do
    echo "  → $node"
    docker exec $node mkdir -p /var/lib/cilium/wasm
    docker cp oxy_money_auth.wasm $node:/var/lib/cilium/wasm/oxy_money_auth.wasm
done
echo "✅ WASM copied"

echo ""
echo "[2/5] Verifying WASM on nodes..."
for node in cilium-demo-control-plane cilium-demo-worker cilium-demo-worker2; do
    docker exec $node ls -lh /var/lib/cilium/wasm/oxy_money_auth.wasm
done

echo ""
echo "[3/5] Restarting Cilium Envoy pods..."
kubectl delete pods -n kube-system -l k8s-app=cilium-envoy
sleep 12

echo "Waiting for pods to be ready..."
kubectl wait --for=condition=ready pod -n kube-system -l k8s-app=cilium-envoy --timeout=90s

echo ""
echo "[4/5] Verifying WASM loading..."
sleep 5
kubectl logs -n kube-system -l k8s-app=cilium-envoy --tail=100 | grep -E "Auth filter configured|oxy_money" | tail -5

echo ""
echo "[5/5] Testing Authentication..."
ENVOY_IP=$(kubectl get pod -n kube-system -l k8s-app=cilium-envoy -o jsonpath='{.items[0].status.podIP}')
echo "Envoy IP: $ENVOY_IP"

echo ""
echo "Test 1: Public endpoint (no auth) - should get 200"
echo "---------------------------------------------------"
kubectl exec test-client -- curl -s -o /dev/null -w "HTTP Status: %{http_code}\n" http://$ENVOY_IP:10000/health

echo ""
echo "Test 2: Protected endpoint (no auth) - should get 401"
echo "------------------------------------------------------"
kubectl exec test-client -- curl -s -o /dev/null -w "HTTP Status: %{http_code}\n" http://$ENVOY_IP:10000/api/protected

echo ""
echo "Test 3: Pass-key only (no JWT) - should get 401"
echo "------------------------------------------------"
kubectl exec test-client -- curl -s -o /dev/null -w "HTTP Status: %{http_code}\n" \
  -H "pass_key: test_api_key_456" \
  http://$ENVOY_IP:10000/api/protected

echo ""
echo "Test 4: Pass-key + JWT - should get 200! 🎯"
echo "-------------------------------------------"
kubectl exec test-client -- curl -v \
  -H "pass_key: test_api_key_456" \
  -H "Authorization: Bearer $JWT_USER2" \
  http://$ENVOY_IP:10000/api/protected 2>&1 | head -30

echo ""
echo "=========================================="
echo "Checking WASM logs..."
echo "=========================================="
kubectl logs -n kube-system -l k8s-app=cilium-envoy --tail=50 | grep -E "oxy_money|Request:|validation" | tail -15

echo ""
echo "✅ Tests complete!"
