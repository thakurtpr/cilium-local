#!/bin/bash
# Build WASM on remote Linux server (avoids Windows file locking issues)

set -e

echo "================================================"
echo "🏗️  Build WASM on Remote Server"
echo "================================================"

SERVER="thakur@172.21.81.178"
WASM_SRC="D:/iSU/thakur_2.0/gateway/oxy-money-gw/wasm-filters"

echo ""
echo "[1/5] Copying source code to server..."
rsync -av --delete \
  --exclude 'target' \
  --exclude '.git' \
  "$WASM_SRC/" $SERVER:/tmp/wasm-filters/

echo ""
echo "[2/5] Installing Rust on server (if not present)..."
ssh $SERVER << 'EOFINSTALL'
if ! command -v cargo &> /dev/null; then
    echo "Installing Rust..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    source $HOME/.cargo/env
fi
rustup target add wasm32-unknown-unknown
EOFINSTALL

echo ""
echo "[3/5] Building WASM on server..."
ssh $SERVER << 'EOFBUILD'
cd /tmp/wasm-filters
source $HOME/.cargo/env
cargo build --target wasm32-unknown-unknown --release
ls -lh target/wasm32-unknown-unknown/release/*.wasm
EOFBUILD

echo ""
echo "[4/5] Copying built WASM back to Windows..."
scp $SERVER:/tmp/wasm-filters/target/wasm32-unknown-unknown/release/oxy_money_auth_filter.wasm \
  ./oxy_money_auth_new.wasm

echo ""
echo "[5/5] Deploying to Kind nodes..."
ssh $SERVER << 'EOFDEPLOY'
cd /tmp/wasm-filters
WASM_FILE="target/wasm32-unknown-unknown/release/oxy_money_auth_filter.wasm"

echo "Copying to Kind nodes..."
for node in cilium-demo-control-plane cilium-demo-worker cilium-demo-worker2; do
    echo "  → $node"
    docker exec $node mkdir -p /var/lib/cilium/wasm
    docker cp "$WASM_FILE" $node:/var/lib/cilium/wasm/oxy_money_auth.wasm
done

echo "Restarting Envoy pods..."
kubectl delete pods -n kube-system -l k8s-app=cilium-envoy
sleep 10
kubectl wait --for=condition=ready pod -n kube-system -l k8s-app=cilium-envoy --timeout=90s

echo "Checking WASM loading..."
kubectl logs -n kube-system -l k8s-app=cilium-envoy --tail=50 | grep -E "Auth filter configured|Public key" | tail -5
EOFDEPLOY

echo ""
echo "✅ Build and deployment complete!"
echo ""
echo "Test with:"
echo "  ssh $SERVER"
echo "  ENVOY_IP=\$(kubectl get pod -n kube-system -l k8s-app=cilium-envoy -o jsonpath='{.items[0].status.podIP}')"
echo "  kubectl exec test-client -- curl -H 'pass_key: test_api_key_456' -H 'Authorization: Bearer \$(cat /tmp/jwt_user2.txt)' http://\$ENVOY_IP:10000/api/protected"
