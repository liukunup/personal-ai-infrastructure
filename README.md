# Personal AI Infrastructure (PAI)

TL;DR;

```bash
docker compose up -d
# 初始化会自动完成:
# 1. kcadm-init 创建 Keycloak realm/client/users
# 2. apisix-init 创建 APISIX consumer/routes
```

## 自动初始化 (kcadm + APISIX Admin API)

启动时自动配置，无需手动操作：

1. **Keycloak 配置** (via kcadm.sh)
   - Realm: `demo`
   - Client: `apisix-client` (client_secret: apisix-secret-changeit)
   - Roles: `admin`, `user`, `demo-role`
   - Users: `alice/password123` (admin), `bob/password123` (user)

2. **APISIX 配置** (via Admin API)
   - Consumer: `keycloak-consumer` (authz-keycloak)
   - Routes: `demo-page-route`, `demo-api-route`

## API Routes

| Route | Auth | Upstream |
|-------|------|----------|
| `/api/v1/users` | openid-connect + authz-casbin | `/v1/users` |
| `/api/v1/users/admin/*` | openid-connect + authz-casbin (admin only) | `/v1/users/admin` |
| `/api/v1/echo` | hmac-auth | `/v1/echo` |

## Demo Service Endpoints

- `GET /` - Health check
- `GET /health` - Health check
- `GET /api/v1/echo?msg=xxx` - Echo endpoint
- `GET /api/v1/users` - User list
- `GET /api/v1/users/{id}` - Get user by ID

## Setup via Admin API

Run the setup script:

```bash
cd apisix_conf/routes
bash demo.yaml
```

This creates:
1. **Consumer** `demo-user` with HMAC credentials
2. **Route** `demo-page-route` - Page access with authz-keycloak + authz-casbin
3. **Route** `demo-api-route` - API access with hmac-auth

## Testing

### Page Access (requires Keycloak token)

获取 Token:
```bash
# alice (admin)
curl -X POST "http://keycloak:8080/realms/demo/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "client_id=apisix-client" \
  -d "client_secret=apisix-secret-changeit" \
  -d "grant_type=password" \
  -d "username=alice" \
  -d "password=password123"

# bob (user)
curl -X POST "http://keycloak:8080/realms/demo/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "client_id=apisix-client" \
  -d "client_secret=apisix-secret-changeit" \
  -d "grant_type=password" \
  -d "username=bob" \
  -d "password=password123"
```

访问 API:
```bash
curl http://127.0.0.1:9080/demo/page/api/v1/users \
  -H "Authorization: Bearer <TOKEN>"
```

### API Access (requires HMAC signature)

Generate signature with Python:

```python
import hmac, hashlib, base64, datetime, timezone
key_id, secret_key = "demo-key", b"demo-secret-key"
method, path = "GET", "/demo/api/api/v1/echo"
gmt = datetime.now(timezone.utc).strftime("%a, %d %b %Y %H:%M:%S GMT")
string = f"{key_id}\n{method} {path}\ndate: {gmt}\n"
sig = base64.b64encode(hmac.new(secret_key, string.encode(), hashlib.sha256).digest()).decode()
auth = f'Signature keyId="{key_id}",algorithm="hmac-sha256",headers="@request-target date",signature="{sig}"'
print(f"Date: {gmt}\nAuthorization: {auth}")
```

Then call the API:

```bash
curl http://127.0.0.1:9080/demo/api/api/v1/echo?msg=hello \
  -H "Date: <GMT_TIME>" \
  -H "Authorization: <SIGNATURE>"
```

### Testing New Routes

#### OIDC Authentication (alice - admin, bob - user)

```bash
# Get alice's token (admin)
ALICE_TOKEN=$(curl -s -X POST "http://keycloak:8080/realms/apisix_test_realm/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "client_id=apisix" \
  -d "client_secret=${APISIX_CLIENT_SECRET:-vARhVsot5zbV5xR6lOVCj7tItQPSjkL8}" \
  -d "grant_type=password" \
  -d "username=alice" \
  -d "password=password123" | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

# Get bob's token (user)
BOB_TOKEN=$(curl -s -X POST "http://keycloak:8080/realms/apisix_test_realm/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "client_id=apisix" \
  -d "client_secret=${APISIX_CLIENT_SECRET:-vARhVsot5zbV5xR6lOVCj7tItQPSjkL8}" \
  -d "grant_type=password" \
  -d "username=bob" \
  -d "password=password123" | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

# Test alice access to users (admin - succeeds)
curl -s -H "Authorization: Bearer ${ALICE_TOKEN}" http://localhost:9080/api/v1/users

# Test alice access to admin (admin - succeeds)
curl -s -H "Authorization: Bearer ${ALICE_TOKEN}" http://localhost:9080/api/v1/users/admin

# Test bob access to users (user - succeeds for GET/POST)
curl -s -H "Authorization: Bearer ${BOB_TOKEN}" http://localhost:9080/api/v1/users

# Test bob access to admin (user - fails, 403)
curl -s -H "Authorization: Bearer ${BOB_TOKEN}" http://localhost:9080/api/v1/users/admin
```

#### HMAC Authentication for /api/v1/echo

```bash
# Generate HMAC signature with Python
python3 << 'EOF'
import hmac, hashlib, base64
from datetime import datetime, timezone

key_id, secret_key = "echo-key", b"echo-secret-key"
method, path = "GET", "/api/v1/echo"
gmt = datetime.now(timezone.utc).strftime("%a, %d %b %Y %H:%M:%S GMT")
string = f"{key_id}\n{method} {path}\ndate: {gmt}\n"
sig = base64.b64encode(hmac.new(secret_key, string.encode(), hashlib.sha256).digest()).decode()
auth = f'Signature keyId="{key_id}",algorithm="hmac-sha256",headers="@request-target date",signature="{sig}"'
print(f"Date: {gmt}")
print(f"Authorization: {auth}")
EOF
```

## Testing with Script

Run the automated test suite:

```bash
python scripts/test-apisix.py \
  --base-url https://api.example.com \
  --kc-url http://keycloak:8080 \
  --kc-realm pai_realm \
  --kc-client-id apisix \
  --kc-username admin \
  --kc-password changeit
```

### Available Tests

| Test | Description | Auth Required |
|------|-------------|---------------|
| `demo-openapi-health` | HMAC signature authentication | Yes (HMAC) |
| `demo-openapi-no-auth` | Verify unsigned requests are rejected | No |
| `demo-openapi-request-id` | Check X-Request-Id header in response | Yes (HMAC) |
| `demo-openapi-rate-limit` | Test limit-req plugin (rate=1, burst=2) | Yes (HMAC) |
| `demo-users-health` | OIDC authentication check | No (expects 401) |
| `demo-users-with-token` | Access with valid OIDC token | Yes (OIDC) |
| `demo-admin-health` | Admin route authentication check | No (expects 401) |
| `demo-admin-with-user-token` | Verify regular users cannot access admin routes | Yes (OIDC) |
| `cors-preflight` | Test CORS preflight requests | No |

### Options

```bash
# List available tests without running
python scripts/test-apisix.py --dry-run

# Run specific tests only
python scripts/test-apisix.py --test demo-users-health --test cors-preflight

# Skip certain tests
python scripts/test-apisix.py --skip demo-openapi-health --skip demo-openapi-rate-limit
```

## Plugins Reference

- [authz-keycloak](https://apisix.apache.org/zh/docs/apisix/plugins/authz-keycloak/) - OIDC/UMA authentication
- [authz-casbin](https://apisix.apache.org/zh/docs/apisix/plugins/authz-casbin/) - RBAC authorization
- [hmac-auth](https://apisix.apache.org/zh/docs/apisix/plugins/hmac-auth/) - HMAC signature verification