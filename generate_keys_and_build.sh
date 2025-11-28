#!/bin/bash
set -e

echo "=========================================="
echo "🔐 Generate Keys, Build & Deploy WASM"
echo "=========================================="

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
WASM_DIR="D:/iSU/thakur_2.0/gateway/oxy-money-gw/wasm-filters"
KEYS_DIR="$SCRIPT_DIR/jwt-keys"

# Step 1: Generate RSA Keys for JWT
echo "[1/6] Generating RSA key pair for JWT signing..."
mkdir -p "$KEYS_DIR"

# Generate private key (RS256)
openssl genrsa -out "$KEYS_DIR/jwt-private.pem" 2048
echo "✅ Private key generated: $KEYS_DIR/jwt-private.pem"

# Generate public key
openssl rsa -in "$KEYS_DIR/jwt-private.pem" -pubout -out "$KEYS_DIR/jwt-public.pem"
echo "✅ Public key generated: $KEYS_DIR/jwt-public.pem"

# Step 2: Build WASM module
echo ""
echo "[2/6] Building WASM module..."
cd "$WASM_DIR"

# Check if cargo is installed
if ! command -v cargo &> /dev/null; then
    echo "❌ Cargo not found. Please install Rust: https://rustup.rs/"
    exit 1
fi

# Build for wasm32
echo "Building with target wasm32-unknown-unknown..."
cargo build --target wasm32-unknown-unknown --release

WASM_FILE="$WASM_DIR/target/wasm32-unknown-unknown/release/oxy_money_auth_filter.wasm"

if [ ! -f "$WASM_FILE" ]; then
    echo "❌ WASM build failed. File not found: $WASM_FILE"
    exit 1
fi

echo "✅ WASM built successfully"
ls -lh "$WASM_FILE"

# Step 3: Calculate SHA256
echo ""
echo "[3/6] Calculating SHA256..."
if command -v sha256sum &> /dev/null; then
    SHA256=$(sha256sum "$WASM_FILE" | awk '{print $1}')
elif command -v shasum &> /dev/null; then
    SHA256=$(shasum -a 256 "$WASM_FILE" | awk '{print $1}')
else
    echo "⚠️  Could not calculate SHA256. Install sha256sum or shasum"
    SHA256="unknown"
fi
echo "SHA256: $SHA256"

# Step 4: Copy to local deployment location
echo ""
echo "[4/6] Copying WASM to deployment location..."
cp "$WASM_FILE" "$SCRIPT_DIR/oxy_money_auth.wasm"
echo "✅ Copied to: $SCRIPT_DIR/oxy_money_auth.wasm"

# Step 5: Display JWT key info
echo ""
echo "[5/6] JWT Keys Info:"
echo "----------------------------------------"
echo "Private Key (for signing): $KEYS_DIR/jwt-private.pem"
echo "Public Key (for validation): $KEYS_DIR/jwt-public.pem"
echo ""
echo "Public Key Content:"
cat "$KEYS_DIR/jwt-public.pem"
echo "----------------------------------------"

# Step 6: Create deployment script
echo ""
echo "[6/6] Creating deployment script..."
cat > "$SCRIPT_DIR/deploy_new_wasm.sh" << 'EOFDEPLOY'
#!/bin/bash
set -e

echo "=========================================="
echo "🚀 Deploy Updated WASM to Cilium"
echo "=========================================="

WASM_FILE="./oxy_money_auth.wasm"

if [ ! -f "$WASM_FILE" ]; then
    echo "❌ WASM file not found: $WASM_FILE"
    exit 1
fi

echo "[1/4] Copying WASM to all Kind nodes..."
for node in cilium-demo-control-plane cilium-demo-worker cilium-demo-worker2; do
    echo "  → $node"
    docker exec $node mkdir -p /var/lib/cilium/wasm
    docker cp "$WASM_FILE" $node:/var/lib/cilium/wasm/oxy_money_auth.wasm
done
echo "✅ WASM copied to all nodes"

echo ""
echo "[2/4] Verifying WASM on nodes..."
for node in cilium-demo-control-plane cilium-demo-worker cilium-demo-worker2; do
    echo "  → $node:"
    docker exec $node ls -lh /var/lib/cilium/wasm/oxy_money_auth.wasm
done

echo ""
echo "[3/4] Restarting Cilium Envoy pods to reload WASM..."
kubectl delete pods -n kube-system -l k8s-app=cilium-envoy
sleep 10

echo ""
echo "[4/4] Waiting for pods to be ready..."
kubectl wait --for=condition=ready pod -n kube-system -l k8s-app=cilium-envoy --timeout=60s

echo ""
echo "✅ Deployment complete!"
echo ""
echo "Verify with:"
echo "  kubectl logs -n kube-system -l k8s-app=cilium-envoy | grep 'Auth filter configured'"
EOFDEPLOY

chmod +x "$SCRIPT_DIR/deploy_new_wasm.sh"
echo "✅ Created: $SCRIPT_DIR/deploy_new_wasm.sh"

echo ""
echo "=========================================="
echo "✅ Build Complete!"
echo "=========================================="
echo ""
echo "Next steps:"
echo "1. Deploy WASM: ./deploy_new_wasm.sh"
echo "2. Create test JWT using the private key"
echo "3. Test with: curl -H 'pass_key: test_api_key_456' -H 'Authorization: Bearer JWT' ..."
echo ""
echo "Your pass-keys:"
echo "  - dEuX2RiyzqEpsun7QiKtsx8Gpdxxn9yvCDfBPaE8Gud2IZ2x (user1)"
echo "  - test_api_key_456 (user2)"
echo "  - test_api_key_789 (admin_user)"
