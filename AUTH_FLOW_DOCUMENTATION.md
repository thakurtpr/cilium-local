# OxyMoney WASM Authentication Filter - Complete Flow

## Overview
The WASM filter implements **multi-factor authentication** with TWO supported flows:
1. **pass-key + JWT** (for API-to-API auth)
2. **pass-key + header-secrets** (for encrypted credential auth)

**CRITICAL**: `pass-key` header is **REQUIRED** in ALL requests to protected endpoints.

---

## Authentication Flows

### Flow 1: pass-key + JWT (API Authentication)

#### Step-by-Step Execution

```rust
// From: src/lib.rs, line 340
fn authenticate_passkey_jwt(&mut self) -> Action {
    // Step 1: Validate pass-key
    let pass_key_result = self.validate_pass_key();
    
    // Step 2: Validate JWT using public key (JWKS)
    let jwt_result = self.validate_jwt();
    
    // Step 3: Add auth headers and continue
    self.add_auth_headers();
    Action::Continue  // → HTTP 200 to backend
}
```

**Request Example**:
```http
GET /api/users HTTP/1.1
Host: api.example.com
pass_key: pass-key-test
Authorization: Bearer eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9...
```

**Validation Steps**:

**1. Pass-Key Validation** (`passkey_handler.rs`, line 32)
```rust
pub fn validate_pass_key(pass_key: &str, config: &FilterConfig, request_id: &str) -> AuthResult {
    // Fetch client registry (from remote URL or cache)
    let registry = fetch_pass_key_registry(config, request_id);
    
    // Lookup client by pass-key
    let client = registry.clients.get(pass_key);
    
    // Check if enabled
    if !client.enabled {
        return AuthResult::failure("client_disabled", ...);
    }
    
    // Return success with client_id and username
    AuthResult::success_with_context(auth_context)
}
```

**Pass-Key Registry Source**: 
```yaml
# From config.rs, line 225
registry:
  source: "remote"
  remote_url: "https://gitlab.txninfra.com/infra-devops-pod/ssi-ui/-/raw/thakur-dev/oxyMoney-pass-key.json"
  cache_ttl: 300
```

**Registry Format** (`passkey_handler.rs`, line 11):
```json
{
  "clients": {
    "pass-key-test": {
      "client_id": "test-client-001",
      "client_secret": "test-secret-001",
      "apiusername": "testuser",
      "key": "test-encryption-key",
      "ips": ["0.0.0.0/0"],
      "enabled": true
    }
  }
}
```

**2. JWT Validation** (`jwt_handler.rs`, line 23)
```rust
pub fn validate_jwt(token: &str, config: &FilterConfig, request_id: &str) -> AuthResult {
    // Split token: header.payload.signature
    let parts: Vec<&str> = token.split('.').collect();
    
    // Decode and verify header algorithm
    let header = decode_base64(parts[0]);
    if header.alg != config.jwt.algorithm {  // Must be RS256
        return AuthResult::failure("invalid_algorithm", ...);
    }
    
    // Decode payload
    let claims = decode_base64(parts[1]);
    
    // Validate issuer
    if claims.iss != "https://auth.oxymoney.com" {
        return AuthResult::failure("invalid_issuer", ...);
    }
    
    // Validate audience
    if !claims.aud.contains("api.oxymoney.com") {
        return AuthResult::failure("invalid_audience", ...);
    }
    
    // Validate expiration
    if claims.exp < current_time {
        return AuthResult::failure("token_expired", ...);
    }
    
    // Extract scopes and roles
    auth_context.scopes = claims.scope.split_whitespace();
    auth_context.roles = claims.roles.split(',');
    
    return AuthResult::success_with_context(auth_context);
}
```

**JWT Config** (`config.rs`, line 94):
```yaml
jwt:
  enabled: true
  algorithm: "RS256"
  issuer: "https://auth.oxymoney.com"
  audiences: ["api.oxymoney.com"]
  jwks:
    source: "remote"
    remote_url: "https://auth.oxymoney.com/.well-known/jwks.json"
```

**Result**: If both pass-key AND JWT are valid → **HTTP 200 + Request forwarded to backend**

---

### Flow 2: pass-key + header-secrets (Encrypted Auth)

#### Step-by-Step Execution

```rust
// From: src/lib.rs, line 378
fn authenticate_passkey_header_secrets(&mut self) -> Action {
    // Step 1: Validate pass-key and get encryption key
    let (client_info, encryption_key) = self.validate_pass_key_and_get_key();
    
    // Step 2: Get encrypted header-secrets header
    let encrypted_secrets = self.get_http_request_header("header-secrets");
    
    // Step 3: Decrypt header-secrets using encryption key from pass-key registry
    let decrypted_data = decrypt_header_secrets(&encrypted_secrets, &encryption_key);
    
    // Step 4: Validate decrypted credentials (client_id, client_secret, epoch)
    let validation_result = validate_decrypted_secrets(&decrypted_data, &client_info);
    
    // Step 5: Add auth headers and continue
    self.add_auth_headers();
    Action::Continue  // → HTTP 200 to backend
}
```

**Request Example**:
```http
POST /api/transactions HTTP/1.1
Host: api.example.com
pass_key: pass-key-encrypted
header-secrets: eyJjbGllbnRfaWQiOiJ0ZXN0LWNsaWVudC0wMDIi...
```

**Validation Steps**:

**1. Pass-Key Validation + Get Encryption Key** (`passkey_handler.rs`, line 98)
```rust
pub fn validate_and_get_client_info(pass_key: &str) -> Option<(ClientInfo, String)> {
    let registry = fetch_pass_key_registry(config, request_id);
    let client = registry.clients.get(pass_key);
    
    // Return BOTH client info AND encryption key
    Some((client.clone(), client.key.clone()))  // ← key is used to decrypt header-secrets
}
```

**2. Decrypt header-secrets** (`passkey_handler.rs`, line 132)
```rust
pub fn decrypt_header_secrets(encrypted: &str, key: &str) -> Result<DecryptedSecrets> {
    // Decode base64
    let decoded = base64_decode(encrypted);
    
    // Decrypt using key from pass-key registry
    // Production: Use AES-256-GCM or ChaCha20-Poly1305
    let decrypted = aes_decrypt(decoded, key);
    
    // Parse JSON
    let secrets: DecryptedSecrets = json::parse(decrypted);
    
    // Expected format:
    // {
    //   "client_id": "test-client-002",
    //   "client_secret": "test-secret-002",
    //   "epoch": 1700000000
    // }
    
    Ok(secrets)
}
```

**3. Validate Decrypted Credentials** (`passkey_handler.rs`, line 166)
```rust
pub fn validate_decrypted_secrets(decrypted: &DecryptedSecrets, client_info: &ClientInfo) -> AuthResult {
    // Validate client_id matches
    if decrypted.client_id != client_info.client_id {
        return AuthResult::failure("client_id_mismatch", ...);
    }
    
    // Validate client_secret matches
    if decrypted.client_secret != client_info.client_secret {
        return AuthResult::failure("client_secret_mismatch", ...);
    }
    
    // Validate epoch (timestamp) - must be within 5 minutes
    let time_diff = (current_time - decrypted.epoch).abs();
    if time_diff > 300 {  // max_epoch_age from config
        return AuthResult::failure("epoch_expired", ...);
    }
    
    return AuthResult::success_with_context(auth_context);
}
```

**Result**: If pass-key is valid, header-secrets decrypts correctly, AND credentials match → **HTTP 200**

---

## Where Valid Keys Are Stored

### Pass-Keys Location

**Source Code** (`passkey_handler.rs`, line 248):
```rust
fn fetch_pass_key_registry(config: &PassKeyConfig) -> Option<PassKeyRegistry> {
    // In PRODUCTION:
    // 1. Check cache first
    // 2. If cache miss, fetch from remote URL
    // 3. Parse JSON response
    // 4. Update cache with TTL = 300 seconds
    
    // Remote URL from config.rs line 225:
    let url = "https://gitlab.txninfra.com/infra-devops-pod/ssi-ui/-/raw/thakur-dev/oxyMoney-pass-key.json";
    
    // Example response format:
    // {
    //   "clients": {
    //     "actual-pass-key-value": {
    //       "client_id": "...",
    //       "client_secret": "...",
    //       "key": "encryption-key-for-header-secrets",
    //       "enabled": true
    //     }
    //   }
    // }
}
```

**CURRENT (Mock for Testing)** (`passkey_handler.rs`, line 264):
```rust
let mut clients = HashMap::new();
clients.insert(
    "pass-key-test".to_string(),  // ← This is the valid pass-key
    ClientInfo {
        client_id: "test-client-001",
        client_secret: "test-secret-001",
        apiusername: "testuser",
        key: "test-encryption-key",
        enabled: true,
    },
);
```

**Where to Add Production Keys**:
1. Update JSON file at GitLab URL
2. WASM filter fetches automatically every 5 minutes (cache_ttl)
3. Or restart Envoy pods to force refresh

---

## Public Paths (No Auth Required)

```rust
// From: src/lib.rs, line 160
fn is_public_path(&self, path: &str) -> bool {
    let public_paths = vec!["/health", "/ready", "/live", "/metrics"];
    public_paths.iter().any(|p| path.starts_with(p))
}
```

**These paths skip authentication entirely**.

---

## Complete Request Flow to Get HTTP 200

### Option A: pass-key + JWT
```bash
curl -H "pass_key: pass-key-test" \
     -H "Authorization: Bearer <VALID_JWT>" \
     http://172.18.0.4:10000/api/users
```

**Requirements**:
1. ✅ `pass_key` header exists
2. ✅ Pass-key is in registry
3. ✅ Client is enabled
4. ✅ JWT has valid signature (RS256)
5. ✅ JWT issuer = "https://auth.oxymoney.com"
6. ✅ JWT audience contains "api.oxymoney.com"
7. ✅ JWT not expired

**→ HTTP 200**

### Option B: pass-key + header-secrets
```bash
curl -H "pass_key: pass-key-encrypted" \
     -H "header-secrets: <ENCRYPTED_PAYLOAD>" \
     http://172.18.0.4:10000/api/transactions
```

**Requirements**:
1. ✅ `pass_key` header exists
2. ✅ Pass-key is in registry
3. ✅ Client is enabled
4. ✅ header-secrets decrypts successfully using client's encryption key
5. ✅ Decrypted client_id matches registry
6. ✅ Decrypted client_secret matches registry
7. ✅ Decrypted epoch is within 5 minutes of current time

**→ HTTP 200**

---

## Failure Scenarios

| Scenario | HTTP Code | Error Code |
|----------|-----------|------------|
| No `pass_key` header | 401 | `missing_pass_key` |
| Invalid `pass_key` | 401 | `invalid_pass_key` |
| Client disabled | 401 | `client_disabled` |
| No JWT or header-secrets | 401 | `invalid_auth_method` |
| Invalid JWT signature | 401 | `invalid_token` |
| JWT expired | 401 | `token_expired` |
| Wrong JWT issuer | 401 | `invalid_issuer` |
| header-secrets decryption failed | 401 | `decryption_failed` |
| client_id mismatch | 401 | `client_id_mismatch` |
| client_secret mismatch | 401 | `client_secret_mismatch` |
| Epoch too old | 401 | `epoch_expired` |

---

## Testing Commands

```bash
# Get Envoy IP
ENVOY_IP=$(kubectl get pod -n kube-system cilium-envoy-4sw55 -o jsonpath='{.status.podIP}')

# Test 1: Public endpoint (no auth)
kubectl exec test-client -- curl http://$ENVOY_IP:10000/health
# → HTTP 200

# Test 2: Protected endpoint (no auth)
kubectl exec test-client -- curl -I http://$ENVOY_IP:10000/api/protected
# → HTTP 401

# Test 3: With valid pass-key only
kubectl exec test-client -- curl -H "pass_key: pass-key-test" http://$ENVOY_IP:10000/api/protected
# → HTTP 401 (need JWT or header-secrets)

# Test 4: With pass-key + mock JWT
kubectl exec test-client -- curl \
  -H "pass_key: pass-key-test" \
  -H "Authorization: Bearer VALID_JWT_HERE" \
  http://$ENVOY_IP:10000/api/protected
# → HTTP 200 (if JWT is valid)

# Monitor WASM logs
kubectl logs -n kube-system cilium-envoy-4sw55 -f | grep oxy_money
```
