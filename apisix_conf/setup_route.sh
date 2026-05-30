#!/bin/bash
# APISIX 路由配置脚本 - Keycloak OIDC 集成
# 使用 direct_access_grants_enabled 模式进行 Token Introspection

set -e

echo "=========================================="
echo "APISIX 路由配置开始 (Keycloak OIDC)"
echo "=========================================="

# 等待 APISIX 就绪
echo "Waiting for APISIX..."
for i in {1..30}; do
    if curl -s http://apisix:9180/apisix/admin/services > /dev/null 2>&1; then
        echo "APISIX is ready"
        break
    fi
    echo "Waiting... ($i/30)"
    sleep 2
done

API_KEY="edd1c9f034335f136f87ad84b625c8f1"
ADMIN_URL="http://apisix:9180/apisix/admin"

# 获取 Keycloak 容器 IP
KEYCLOAK_IP=$(getent hosts keycloak | awk '{print $1}')
echo "Keycloak IP: ${KEYCLOAK_IP}"

# 等待 Keycloak 就绪
echo "Waiting for Keycloak..."
for i in {1..30}; do
    if curl -s "http://${KEYCLOAK_IP}:8080/health/ready" > /dev/null 2>&1; then
        echo "Keycloak is ready"
        break
    fi
    echo "Waiting... ($i/30)"
    sleep 2
done

# 修正 Keycloak discovery 中的 issuer URL (从外部域名改为内部可达的 keycloak hostname)
echo "Fixing Keycloak discovery issuer for internal access..."
curl -s "http://${KEYCLOAK_IP}:8080/realms/apisix_test_realm/.well-known/openid-configuration" | \
    sed "s|http://keycloak.example.com:8080|http://keycloak:8080|g" > /tmp/oidc_fixed.json

# 删除旧配置
echo "Cleaning up old configs..."
curl -s -X DELETE "${ADMIN_URL}/routes/1" -H "X-API-KEY: ${API_KEY}" 2>/dev/null || true
curl -s -X DELETE "${ADMIN_URL}/services/1" -H "X-API-KEY: ${API_KEY}" 2>/dev/null || true

# 创建路由
echo "Creating route with OIDC..."
curl -s -X PUT "${ADMIN_URL}/routes/1" \
  -H "X-API-KEY: ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "api-v1-route",
    "uri": "/api/v1/*",
    "methods": ["GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS"],
    "upstream": {
      "type": "roundrobin",
      "nodes": [{"host": "fastapi-service", "port": 8000, "weight": 1}]
    },
    "labels": {
      "app": "fastapi",
      "auth": "oidc"
    },
    "plugins": {
      "openid-connect": {
        "client_id": "apisix",
        "client_secret": "venF4ngPZhKk3I4NY2opc13wOIqFGOsb",
        "discovery": "http://'"${KEYCLOAK_IP}"':8080/realms/apisix_test_realm/.well-known/openid-configuration",
        "scope": "openid profile email",
        "bearer_only": true,
        "ssl_verify": false,
        "introspection_endpoint_auth_method": "client_secret_post"
      },
      "cors": {
        "allow_origins": "*",
        "allow_methods": "GET,POST,PUT,DELETE,PATCH,OPTIONS",
        "allow_headers": "Authorization,Content-Type",
        "max_age": 3600
      },
      "proxy-rewrite": {
        "uri": "/v1$uri"
      }
    }
  }'

echo ""
echo "=========================================="
echo "APISIX 路由配置完成!"
echo ""
echo "测试命令:"
echo "  # 获取 access token"
echo "  TOKEN=\$(curl -sk -X POST \\"
echo "    'https://keycloak.example.com/realms/apisix_test_realm/protocol/openid-connect/token' \\"
echo "    -H 'Content-Type: application/x-www-form-urlencoded' \\"
echo "    -d 'grant_type=password' \\"
echo "    -d 'client_id=apisix' \\"
echo "    -d 'username=testuser' \\"
echo "    -d 'password=testpass' | python3 -c \"import sys,json; print(json.load(sys.stdin)['access_token'])\")"
echo ""
echo "  # 调用需要认证的 API"
echo "  curl -sk -H \"Authorization: Bearer \${TOKEN}\" \\"
echo "    'https://localhost/api/v1/echo?msg=hello'"
echo "=========================================="