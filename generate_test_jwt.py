#!/usr/bin/env python3
"""
Generate test JWT tokens for WASM filter testing
"""

import json
import time
from datetime import datetime, timedelta
import subprocess
import sys
import os

def generate_jwt_with_openssl(payload, private_key_path):
    """Generate JWT using OpenSSL for RS256 signing"""
    import base64
    import hashlib
    
    # JWT Header
    header = {
        "alg": "RS256",
        "typ": "JWT"
    }
    
    # Base64 encode header and payload
    def base64url_encode(data):
        json_str = json.dumps(data, separators=(',', ':'))
        encoded = base64.urlsafe_b64encode(json_str.encode()).decode()
        # Remove padding
        return encoded.rstrip('=')
    
    header_encoded = base64url_encode(header)
    payload_encoded = base64url_encode(payload)
    
    # Create message to sign
    message = f"{header_encoded}.{payload_encoded}"
    
    # Sign with OpenSSL
    try:
        # Write message to temp file
        with open('/tmp/jwt_message.txt', 'w') as f:
            f.write(message)
        
        # Sign with private key
        result = subprocess.run([
            'openssl', 'dgst', '-sha256', '-sign', private_key_path,
            '/tmp/jwt_message.txt'
        ], capture_output=True, check=True)
        
        signature_bytes = result.stdout
        
        # Base64url encode signature
        signature_encoded = base64.urlsafe_b64encode(signature_bytes).decode().rstrip('=')
        
        # Combine to create JWT
        jwt_token = f"{message}.{signature_encoded}"
        
        # Cleanup
        os.remove('/tmp/jwt_message.txt')
        
        return jwt_token
        
    except subprocess.CalledProcessError as e:
        print(f"Error signing JWT: {e}")
        print(f"stderr: {e.stderr.decode()}")
        return None
    except Exception as e:
        print(f"Error: {e}")
        return None

def main():
    # Path to private key
    keys_dir = os.path.join(os.path.dirname(__file__), 'jwt-keys')
    private_key = os.path.join(keys_dir, 'jwt-private.pem')
    
    if not os.path.exists(private_key):
        print(f"❌ Private key not found: {private_key}")
        print("Run ./generate_keys_and_build.sh first!")
        sys.exit(1)
    
    print("=" * 60)
    print("🔐 JWT Token Generator")
    print("=" * 60)
    print()
    
    # Current time
    now = int(time.time())
    
    # Token 1: For user2 (test_api_key_456)
    print("[1/3] Generating JWT for user2...")
    payload_user2 = {
        "iss": "https://auth.oxymoney.com",
        "sub": "user2",
        "aud": ["api.oxymoney.com"],
        "exp": now + 3600,  # 1 hour from now
        "nbf": now,
        "iat": now,
        "client_id": "client_002",
        "username": "user2",
        "scope": "read write",
        "roles": "user"
    }
    
    jwt_user2 = generate_jwt_with_openssl(payload_user2, private_key)
    
    if jwt_user2:
        print(f"✅ JWT for user2 generated")
        print(f"Pass-key: test_api_key_456")
        print(f"JWT: {jwt_user2[:50]}...{jwt_user2[-50:]}")
        print()
        
        # Save to file
        with open('jwt_user2.txt', 'w') as f:
            f.write(jwt_user2)
        print(f"Saved to: jwt_user2.txt")
        print()
    
    # Token 2: For admin_user (test_api_key_789)
    print("[2/3] Generating JWT for admin_user...")
    payload_admin = {
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
    
    jwt_admin = generate_jwt_with_openssl(payload_admin, private_key)
    
    if jwt_admin:
        print(f"✅ JWT for admin_user generated")
        print(f"Pass-key: test_api_key_789")
        print(f"JWT: {jwt_admin[:50]}...{jwt_admin[-50:]}")
        print()
        
        with open('jwt_admin.txt', 'w') as f:
            f.write(jwt_admin)
        print(f"Saved to: jwt_admin.txt")
        print()
    
    # Token 3: For user1 (long pass-key)
    print("[3/3] Generating JWT for user1...")
    payload_user1 = {
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
    
    jwt_user1 = generate_jwt_with_openssl(payload_user1, private_key)
    
    if jwt_user1:
        print(f"✅ JWT for user1 generated")
        print(f"Pass-key: dEuX2RiyzqEpsun7QiKtsx8Gpdxxn9yvCDfBPaE8Gud2IZ2x")
        print(f"JWT: {jwt_user1[:50]}...{jwt_user1[-50:]}")
        print()
        
        with open('jwt_user1.txt', 'w') as f:
            f.write(jwt_user1)
        print(f"Saved to: jwt_user1.txt")
        print()
    
    print("=" * 60)
    print("✅ All JWTs Generated!")
    print("=" * 60)
    print()
    print("Test commands:")
    print()
    print("# Get Envoy IP")
    print("ENVOY_IP=$(kubectl get pod -n kube-system cilium-envoy-4sw55 -o jsonpath='{.status.podIP}')")
    print()
    print("# Test with user2")
    print(f"kubectl exec test-client -- curl -v \\")
    print(f"  -H 'pass_key: test_api_key_456' \\")
    print(f"  -H 'Authorization: Bearer $(cat jwt_user2.txt)' \\")
    print(f"  http://$ENVOY_IP:10000/api/protected")
    print()
    print("# Test with admin")
    print(f"kubectl exec test-client -- curl -v \\")
    print(f"  -H 'pass_key: test_api_key_789' \\")
    print(f"  -H 'Authorization: Bearer $(cat jwt_admin.txt)' \\")
    print(f"  http://$ENVOY_IP:10000/api/protected")
    print()

if __name__ == '__main__':
    main()
