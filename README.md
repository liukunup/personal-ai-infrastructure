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
| `/demo/page/*` | authz-keycloak + authz-casbin | `/api/v1/*` |
| `/demo/api/*` | hmac-auth | `/api/v1/*` |

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

## Plugins Reference

- [authz-keycloak](https://apisix.apache.org/zh/docs/apisix/plugins/authz-keycloak/) - OIDC/UMA authentication
- [authz-casbin](https://apisix.apache.org/zh/docs/apisix/plugins/authz-casbin/) - RBAC authorization
- [hmac-auth](https://apisix.apache.org/zh/docs/apisix/plugins/hmac-auth/) - HMAC signature verification