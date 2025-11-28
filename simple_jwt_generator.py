#!/usr/bin/env python3
"""
Simple JWT generator using cryptography library
Install: pip install cryptography
"""

import json
import time
import base64
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa, padding
from cryptography.hazmat.backends import default_backend

def base64url_encode(data):
    """Base64 URL encode without padding"""
    if isinstance(data, str):
        data = data.encode('utf-8')
    elif isinstance(data, dict):
        data = json.dumps(data, separators=(',', ':')).encode('utf-8')
    
    encoded = base64.urlsafe_b64encode(data).decode('utf-8')
    return encoded.rstrip('=')

def generate_keys():
    """Generate RSA key pair"""
    print("Generating RSA key pair...")
    private_key = rsa.generate_private_key(
        public_exponent=65537,
        key_size=2048,
        backend=default_backend()
    )
    public_key = private_key.public_key()
    
    # Serialize keys
    private_pem = private_key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.TraditionalOpenSSL,
        encryption_algorithm=serialization.NoEncryption()
    )
    
    public_pem = public_key.public_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PublicFormat.SubjectPublicKeyInfo
    )
    
    # Save to files
    with open('jwt-keys/jwt-private.pem', 'wb') as f:
        f.write(private_pem)
    
    with open('jwt-keys/jwt-public.pem', 'wb') as f:
        f.write(public_pem)
    
    print("✅ Keys saved to jwt-keys/")
    return private_key

def create_jwt(payload, private_key):
    """Create RS256 signed JWT"""
    # Header
    header = {
        "alg": "RS256",
        "typ": "JWT"
    }
    
    # Encode header and payload
    header_encoded = base64url_encode(header)
    payload_encoded = base64url_encode(payload)
    
    # Create message to sign
    message = f"{header_encoded}.{payload_encoded}".encode('utf-8')
    
    # Sign with private key (RS256 = PKCS1v15 + SHA256)
    signature = private_key.sign(
        message,
        padding.PKCS1v15(),
        hashes.SHA256()
    )
    
    # Encode signature
    signature_encoded = base64url_encode(signature)
    
    # Combine to create JWT
    jwt_token = f"{message.decode('utf-8')}.{signature_encoded}"
    
    return jwt_token

def main():
    print("=" * 70)
    print("🔐 JWT Generator for WASM Filter Testing")
    print("=" * 70)
    print()
    
    # Generate keys
    try:
        private_key = generate_keys()
    except Exception as e:
        print(f"❌ Error generating keys: {e}")
        return
    
    now = int(time.time())
    
    # Create JWTs for each user
    users = [
        {
            "name": "user2",
            "pass_key": "test_api_key_456",
            "client_id": "client_002",
            "payload": {
                "iss": "https://auth.oxymoney.com",
                "sub": "user2",
                "aud": ["api.oxymoney.com"],
                "exp": now + 3600,
                "nbf": now,
                "iat": now,
                "client_id": "client_002",
                "username": "user2",
                "scope": "read write",
                "roles": "user"
            }
        },
        {
            "name": "admin",
            "pass_key": "test_api_key_789",
            "client_id": "client_003",
            "payload": {
                "iss": "https://auth.oxymoney.com",
                "sub": "admin_user",
                "aud": ["api.oxymoney.com"],
                "exp": now + 3600,
                "nbf": now,
                "iat": now,
                "client_id": "client_003",
                "username": "admin_user",
                "scope": "read write admin",
                "roles": "admin,user"
            }
        },
        {
            "name": "user1",
            "pass_key": "dEuX2RiyzqEpsun7QiKtsx8Gpdxxn9yvCDfBPaE8Gud2IZ2x",
            "client_id": "BYTYBnuQqM6H4Haijasxkaxgkgig1pPuI7BwDnB8nXNA6YTy6",
            "payload": {
                "iss": "https://auth.oxymoney.com",
                "sub": "user1",
                "aud": ["api.oxymoney.com"],
                "exp": now + 3600,
                "nbf": now,
                "iat": now,
                "client_id": "BYTYBnuQqM6H4Haijasxkaxgkgig1pPuI7BwDnB8nXNA6YTy6",
                "username": "user1",
                "scope": "read write transactions",
                "roles": "user,premium"
            }
        }
    ]
    
    print()
    for user in users:
        print(f"Generating JWT for {user['name']}...")
        jwt = create_jwt(user['payload'], private_key)
        filename = f"jwt_{user['name']}.txt"
        with open(filename, 'w') as f:
            f.write(jwt)
        print(f"✅ {filename}")
        print(f"   Pass-key: {user['pass_key']}")
        print(f"   JWT: {jwt[:60]}...")
        print()
    
    print("=" * 70)
    print("✅ All JWTs Generated!")
    print("=" * 70)
    print()
    print("Test commands (run on remote server):")
    print()
    print("ENVOY_IP=$(kubectl get pod -n kube-system -l k8s-app=cilium-envoy -o jsonpath='{.items[0].status.podIP}')")
    print()
    print("# Test user2")
    print("kubectl exec test-client -- curl -v \\")
    print("  -H 'pass_key: test_api_key_456' \\")
    print(f"  -H 'Authorization: Bearer $(cat jwt_user2.txt)' \\")
    print("  http://$ENVOY_IP:10000/api/protected")

if __name__ == '__main__':
    main()
