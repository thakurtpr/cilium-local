#!/bin/bash
set -e

echo "================================================================"
echo "🚀 COMPLETE WASM BUILD, DEPLOY & TEST"
echo "================================================================"
echo ""
echo "This script will:"
echo "1. Generate RSA keys for JWT"
echo "2. Build WASM module with your pass-keys"
echo "3. Deploy to all Kind nodes"
echo "4. Generate test JWT tokens"
echo "5. Test and verify HTTP 200"
echo ""
read -p "Continue? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WASM_DIR="$SCRIPT_DIR/../gateway/oxy-money-gw/wasm-filters"
KEYS_DIR="$SCRIPT_DIR/jwt-keys"

# Step 1: Generate RSA Keys
echo ""
echo "================================================================"
echo "📍 [1/6] Generating RSA Keys"
echo "================================================================"
mkdir -p "$KEYS_DIR"

if [ ! -f "$KEYS_DIR/jwt-private.pem" ]; then
    echo "Generating new RSA key pair..."
    openssl genrsa -out "$KEYS_DIR/jwt-private.pem" 2048 2>/dev/null
    openssl rsa -in "$KEYS_DIR/jwt-private.pem" -pubout -out "$KEYS_DIR/jwt-public.pem" 2>/dev/null
    echo "✅ Keys generated"
else
    echo "✅ Keys already exist"
fi

echo "Private key: $KEYS_DIR/jwt-private.pem"
echo "Public key: $KEYS_DIR/jwt-public.pem"

# Step 2: Build WASM
echo ""
echo "================================================================"
echo "📍 [2/6] Building WASM Module"
echo "================================================================"

if [ ! -d "$WASM_DIR" ]; then
    echo "❌ WASM directory not found: $WASM_DIR"
    exit 1
fi

cd "$WASM_DIR"

echo "Checking Rust installation..."
if ! command -v cargo &> /dev/null; then
    echo "❌ Cargo not found. Install Rust from https://rustup.rs/"
    exit 1
fi

echo "Adding wasm32 target..."
rustup target add wasm32-unknown-unknown 2>/dev/null || true

echo "Building WASM (this may take a few minutes)..."
cargo build --target wasm32-unknown-unknown --release

WASM_FILE="$WASM_DIR/target/wasm32-unknown-unknown/release/oxy_money_auth_filter.wasm"

if [ ! -f "$WASM_FILE" ]; then
    echo "❌ Build failed. WASM file not found."
    exit 1
fi

echo "✅ WASM built successfully"
ls -lh "$WASM_FILE"

# Calculate SHA256
if command -v sha256sum &> /dev/null; then
    SHA256=$(sha256sum "$WASM_FILE" | awk '{print $1}')
elif command -v shasum &> /dev/null; then
    SHA256=$(shasum -a 256 "$WASM_FILE" | awk '{print $1}')
else
    SHA256="unknown"
fi
echo "SHA256: $SHA256"

# Copy to deployment location
cp "$WASM_FILE" "$SCRIPT_DIR/oxy_money_auth.wasm"
echo "✅ Copied to: $SCRIPT_DIR/oxy_money_auth.wasm"

# Step 3: Deploy to Kind Nodes via SSH
echo ""
echo "================================================================"
echo "📍 [3/6] Deploying WASM to Kind Nodes"
echo "================================================================"

# Copy WASM file to remote server
echo "Copying WASM to remote server..."
scp "$SCRIPT_DIR/oxy_money_auth.wasm" thakur@172.21.81.178:/tmp/oxy_money_auth.wasm

# Deploy to Kind nodes via SSH
ssh thakur@172.21.81.178 << 'EOFREMOTE'
echo "Deploying to Kind nodes..."
for node in cilium-demo-control-plane cilium-demo-worker cilium-demo-worker2; do
    echo "  → $node"
    docker exec $node mkdir -p /var/lib/cilium/wasm
    docker cp /tmp/oxy_money_auth.wasm $node:/var/lib/cilium/wasm/oxy_money_auth.wasm
    docker exec $node ls -lh /var/lib/cilium/wasm/oxy_money_auth.wasm
done
echo "✅ WASM copied to all nodes"

echo ""
echo "Restarting Cilium Envoy pods..."
kubectl delete pods -n kube-system -l k8s-app=cilium-envoy
sleep 10

echo "Waiting for pods to be ready..."
kubectl wait --for=condition=ready pod -n kube-system -l k8s-app=cilium-envoy --timeout=90s

echo "✅ Envoy pods restarted"
EOFREMOTE

echo "✅ Deployment complete"

# Step 4: Verify WASM Loading
echo ""
echo "================================================================"
echo "📍 [4/6] Verifying WASM Loading"
echo "================================================================"

ssh thakur@172.21.81.178 "kubectl logs -n kube-system -l k8s-app=cilium-envoy --tail=50 | grep -E 'Auth filter configured|oxy_money' | tail -5"

# Step 5: Generate Test JWTs
echo ""
echo "================================================================"
echo "📍 [5/6] Generating Test JWT Tokens"
echo "================================================================"

cd "$SCRIPT_DIR"
python3 generate_test_jwt.py

# Step 6: Test
echo ""
echo "================================================================"
echo "📍 [6/6] Testing Authentication"
echo "================================================================"

# Load JWT
if [ ! -f "$SCRIPT_DIR/jwt_user2.txt" ]; then
    echo "❌ JWT file not found"
    exit 1
fi

JWT_USER2=$(cat "$SCRIPT_DIR/jwt_user2.txt")

echo ""
echo "Test 1: Public endpoint (no auth)"
echo "-----------------------------------"
ssh thakur@172.21.81.178 << 'EOFTEST1'
ENVOY_IP=$(kubectl get pod -n kube-system -l k8s-app=cilium-envoy -o jsonpath='{.items[0].status.podIP}')
echo "Envoy IP: $ENVOY_IP"
kubectl exec test-client -- curl -s -o /dev/null -w "HTTP Status: %{http_code}\n" http://$ENVOY_IP:10000/health
EOFTEST1

echo ""
echo "Test 2: Protected endpoint (no auth) - should get 401"
echo "------------------------------------------------------"
ssh thakur@172.21.81.178 << 'EOFTEST2'
ENVOY_IP=$(kubectl get pod -n kube-system -l k8s-app=cilium-envoy -o jsonpath='{.items[0].status.podIP}')
kubectl exec test-client -- curl -s -o /dev/null -w "HTTP Status: %{http_code}\n" http://$ENVOY_IP:10000/api/protected
EOFTEST2

echo ""
echo "Test 3: With pass-key + JWT - should get 200! 🎯"
echo "--------------------------------------------------"
ssh thakur@172.21.81.178 "ENVOY_IP=\$(kubectl get pod -n kube-system -l k8s-app=cilium-envoy -o jsonpath='{.items[0].status.podIP}') && \
kubectl exec test-client -- curl -v \
  -H 'pass_key: test_api_key_456' \
  -H 'Authorization: Bearer $JWT_USER2' \
  http://\$ENVOY_IP:10000/api/protected 2>&1 | head -40"

echo ""
echo "================================================================"
echo "✅ COMPLETE!"
echo "================================================================"
echo ""
echo "Your pass-keys:"
echo "  - test_api_key_456 (user2)"
echo "  - test_api_key_789 (admin_user)"
echo "  - dEuX2RiyzqEpsun7QiKtsx8Gpdxxn9yvCDfBPaE8Gud2IZ2x (user1)"
echo ""
echo "JWTs saved in:"
echo "  - jwt_user2.txt"
echo "  - jwt_admin.txt"
echo "  - jwt_user1.txt"
echo ""
echo "Test command:"
echo "  ENVOY_IP=\$(kubectl get pod -n kube-system -l k8s-app=cilium-envoy -o jsonpath='{.items[0].status.podIP}')"
echo "  kubectl exec test-client -- curl -H 'pass_key: test_api_key_456' -H 'Authorization: Bearer \$(cat jwt_user2.txt)' http://\$ENVOY_IP:10000/api/protected"
