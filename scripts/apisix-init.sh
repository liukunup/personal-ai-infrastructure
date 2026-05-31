#!/bin/sh
set -e

# ============================================
# APISIX 初始化脚本
# ============================================

# 环境变量
APISIX_URL="${APISIX_URL:-http://apisix:9180}"
APISIX_CONF="${APISIX_CONF:-/usr/local/apisix/conf/config.yaml}"
APISIX_ADMIN_KEY="${APISIX_ADMIN_KEY:-$(grep -A1 'name: admin' "${APISIX_CONF}" 2>/dev/null | grep 'key:' | awk '{print $2}' | head -1)}"
KC_REALM="${KC_REALM:-pai_realm}"
KC_CLIENT_ID="${KC_CLIENT_ID:-apisix}"
KC_ADMIN_USERNAME="${KC_ADMIN_USERNAME:-admin}"
KC_ADMIN_PASSWORD="${KC_ADMIN_PASSWORD:?KC_ADMIN_PASSWORD is not set}"

# HMAC credentials (generate if not provided)
HMAC_KEY_ID="${HMAC_KEY_ID:-$(openssl rand -hex 8 2>/dev/null || head -c 16 /dev/urandom | xxd -p)}"
HMAC_SECRET_KEY="${HMAC_SECRET_KEY:-$(openssl rand -base64 32 2>/dev/null || head -c 32 /dev/urandom | base64)}"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ============================================
# Helper: 获取 Keycloak OIDC Discovery URL
# ============================================
get_keycloak_discovery() {
    echo "http://keycloak:8080/realms/${KC_REALM}/.well-known/openid-configuration"
}

# ============================================
# Helper: 获取 Keycloak Client Secret
# ============================================
get_keycloak_client_secret() {
    local kc_admin_user="${KC_ADMIN_USERNAME:-admin}"
    local kc_admin_pass="${KC_ADMIN_PASSWORD}"
    local kc_client_id="${KC_CLIENT_ID:-apisix}"

    local token
    token=$(curl -s -X POST "http://keycloak:8080/realms/master/protocol/openid-connect/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "username=${kc_admin_user}&password=${kc_admin_pass}&grant_type=password&client_id=admin-cli" \
        | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)

    local client_uuid
    client_uuid=$(curl -s -X GET "http://keycloak:8080/admin/realms/${KC_REALM}/clients?clientId=${kc_client_id}" \
        -H "Authorization: Bearer ${token}" \
        | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)

    curl -s -X GET "http://keycloak:8080/admin/realms/${KC_REALM}/clients/${client_uuid}/client-secret" \
        -H "Authorization: Bearer ${token}" \
        | grep -o '"value":"[^"]*"' | cut -d'"' -f4
}

# ============================================
# 1. 创建 Route: /demo/api/*
# ============================================
create_api_route() {
    log_info "创建 Route: demo-api-route"

    local route_json='{
        "id": "demo-api-route",
        "name": "demo-api-route",
        "desc": "Route for /demo/api/*",
        "uri": "/demo/api/*",
        "plugins": {
            "proxy-rewrite": {
                "regex_uri": ["^/demo/api/(.*)", "/api/v1/$1"]
            }
        },
        "upstream": {
            "service_name": "demo-service",
            "type": "roundrobin",
            "discovery_type": "nacos",
            "discovery_args": {
                "namespace_id": "public",
                "group_name": "DEFAULT_GROUP"
            }
        }
    }'

    local response
    response=$(curl -s -X PUT "${APISIX_URL}/apisix/admin/routes/demo-api-route" \
        -H "X-API-KEY: ${APISIX_ADMIN_KEY}" \
        -H "Content-Type: application/json" \
        -d "${route_json}")

    if echo "${response}" | grep -q '"code":0\|"id":"demo-api-route"'; then
        log_info "Route 'demo-api-route' 创建成功"
    else
        log_warn "Route 响应: ${response}"
    fi
}

# ============================================
# 2. 创建 Route: /demo/openapi/*
# ============================================
create_openapi_route() {
    log_info "Creating Route: openapi-route"

    local route_json='{
        "id": "openapi-route",
        "name": "openapi-route",
        "desc": "Route for /demo/openapi/*",
        "uri": "/demo/openapi/*",
        "plugins": {
            "proxy-rewrite": {
                "regex_uri": ["^/demo/openapi/(.*)", "/api/v1/$1"]
            },
            "hmac-auth": {
                "key_id": "'"${HMAC_KEY_ID}"'",
                "secret_key": "'"${HMAC_SECRET_KEY}"'",
                "allowed_algorithms": ["hmac-sha256"],
                "clock_skew": 30,
                "hide_credentials": false
            },
            "cors": {
                "allow_origins": "*",
                "allow_methods": "GET,POST,PUT,DELETE,PATCH,OPTIONS",
                "allow_headers": "Authorization,Content-Type,Date",
                "max_age": 3600
            },
            "request-id": {
                "algorithm": "uuid",
                "header_name": "X-Request-Id",
                "include_in_response": true
            },
            "limit-req": {
                "rate": 100,
                "burst": 20,
                "key": "remote_addr",
                "key_type": "var",
                "rejected_code": 429,
                "nodelay": true
            }
        },
        "upstream": {
            "service_name": "demo-service",
            "type": "roundrobin",
            "discovery_type": "nacos",
            "discovery_args": {
                "namespace_id": "public",
                "group_name": "DEFAULT_GROUP"
            }
        }
    }'

    local response
    response=$(curl -s -X PUT "${APISIX_URL}/apisix/admin/routes/openapi-route" \
        -H "X-API-KEY: ${APISIX_ADMIN_KEY}" \
        -H "Content-Type: application/json" \
        -d "${route_json}")

    if echo "${response}" | grep -q '"code":0\|"id":"openapi-route"'; then
        log_info "Route 'openapi-route' 创建成功"
    else
        log_warn "Route 响应: ${response}"
    fi
}

# ============================================
# 2. 创建 Route: /api/v1/users/* (openid-connect + authz-casbin)
# ============================================
create_users_route() {
    log_info "Creating Route: users-route (openid-connect + authz-casbin)"

    local discovery=$(get_keycloak_discovery)
    local route_json='{
        "id": "users-route",
        "uri": "/api/v1/users/*",
        "plugins": {
            "openid-connect": {
                "client_id": "'"${KC_CLIENT_ID}"'",
                "client_secret": "'"${CLIENT_SECRET}"'",
                "discovery": "'"${discovery}"'",
                "scope": "openid profile email groups",
                "required_scopes": ["groups"],
                "bearer_only": true,
                "ssl_verify": false,
                "set_userinfo_header": true,
                "access_token_in_authorization_header": false,
                "token_endpoint_auth_method": "client_secret_post"
            },
            "authz-casbin": {
                "model": "[request_definition]\nr = sub, obj, act\n[policy_definition]\np = sub, obj, act\n[role_definition]\ng = _, _\n[policy_effect]\ne = some(where (p.eft == allow))\n[matchers]\nm = (g(r.sub, p.sub) || keyMatch(r.sub, p.sub)) && keyMatch(r.obj, p.obj) && keyMatch(r.act, p.act)",
                "policy": "p, admin, /api/v1/users, GET\np, admin, /api/v1/users, POST\np, admin, /api/v1/users, PUT\np, admin, /api/v1/users, DELETE\np, user, /api/v1/users, GET\np, user, /api/v1/users, POST\ng, admin, admin\ng, user, user",
                "username": "preferred_username"
            },
            "proxy-rewrite": {
                "uri": "/v1$uri"
            },
            "cors": {
                "allow_origins": "*",
                "allow_methods": "GET,POST,PUT,DELETE,PATCH,OPTIONS",
                "allow_headers": "Authorization,Content-Type",
                "max_age": 3600
            }
        },
        "upstream": {
            "service_name": "demo-service",
            "type": "roundrobin",
            "discovery_type": "nacos",
            "discovery_args": {
                "namespace_id": "public",
                "group_name": "DEFAULT_GROUP"
            }
        }
    }'

    local response
    response=$(curl -s -X PUT "${APISIX_URL}/apisix/admin/routes/users-route" \
        -H "X-API-KEY: ${APISIX_ADMIN_KEY}" \
        -H "Content-Type: application/json" \
        -d "${route_json}")

    if echo "${response}" | grep -q '"code":0\|"id":"users-route"'; then
        log_info "Route 'users-route' 创建成功"
    else
        log_warn "Route 响应: ${response}"
    fi
}

# ============================================
# 7. 创建 Route: /api/v1/admin/* (openid-connect + authz-casbin admin-only)
# ============================================
create_admin_route() {
    log_info "Creating Route: admin-route (openid-connect + authz-casbin admin-only)"

    local discovery=$(get_keycloak_discovery)
    local route_json='{
        "id": "admin-route",
        "uri": "/api/v1/admin/*",
        "plugins": {
            "openid-connect": {
                "client_id": "'"${KC_CLIENT_ID}"'",
                "client_secret": "'"${CLIENT_SECRET}"'",
                "discovery": "'"${discovery}"'",
                "scope": "openid profile email groups",
                "required_scopes": ["groups"],
                "bearer_only": true,
                "ssl_verify": false,
                "set_userinfo_header": true,
                "access_token_in_authorization_header": false,
                "token_endpoint_auth_method": "client_secret_post"
            },
            "authz-casbin": {
                "model": "[request_definition]\nr = sub, obj, act\n[policy_definition]\np = sub, obj, act\n[role_definition]\ng = _, _\n[policy_effect]\ne = some(where (p.eft == allow))\n[matchers]\nm = (g(r.sub, p.sub) || keyMatch(r.sub, p.sub)) && keyMatch(r.obj, p.obj) && keyMatch(r.act, p.act)",
                "policy": "p, admin, /api/v1/admin, GET\np, admin, /api/v1/admin, POST\np, admin, /api/v1/admin, PUT\np, admin, /api/v1/admin, DELETE\ng, admin, admin",
                "username": "preferred_username"
            },
            "proxy-rewrite": {
                "uri": "/v1$uri"
            },
            "cors": {
                "allow_origins": "*",
                "allow_methods": "GET,POST,PUT,DELETE,PATCH,OPTIONS",
                "allow_headers": "Authorization,Content-Type",
                "max_age": 3600
            }
        },
        "upstream": {
            "service_name": "demo-service",
            "type": "roundrobin",
            "discovery_type": "nacos",
            "discovery_args": {
                "namespace_id": "public",
                "group_name": "DEFAULT_GROUP"
            }
        }
    }'

    local response
    response=$(curl -s -X PUT "${APISIX_URL}/apisix/admin/routes/admin-route" \
        -H "X-API-KEY: ${APISIX_ADMIN_KEY}" \
        -H "Content-Type: application/json" \
        -d "${route_json}")

    if echo "${response}" | grep -q '"code":0\|"id":"admin-route"'; then
        log_info "Route 'admin-route' 创建成功"
    else
        log_warn "Route 响应: ${response}"
    fi
}

# ============================================
# 8. 打印摘要
# ============================================
print_summary() {
    log_info "=========================================="
    log_info "APISIX 配置完成!"
    log_info "=========================================="
    log_info "Keycloak OIDC:"
    log_info "  realm: ${KC_REALM}"
    log_info "  client_id: ${KC_CLIENT_ID}"
    log_info "  discovery: http://keycloak:8080/realms/${KC_REALM}/.well-known/openid-configuration"
    log_info ""
    log_info "HMAC credentials:"
    log_info "  key_id: ${HMAC_KEY_ID}"
    log_info "  secret_key: ${HMAC_SECRET_KEY}"
    log_info ""
    log_info "Routes:"
    log_info "  - demo-api-route (proxy-rewrite, no auth)"
    log_info "  - openapi-route (hmac-auth + cors + request-id + limit-req)"
    log_info "  - users-route (openid-connect + authz-casbin)"
    log_info "  - admin-route (openid-connect + authz-casbin admin-only)"
    log_info "=========================================="
}

# ============================================
# 主流程
# ============================================
main() {
    log_info "开始 APISIX 配置..."
    log_info "APISIX_URL: ${APISIX_URL}"

    log_info "获取 Keycloak Client Secret..."
    CLIENT_SECRET=$(get_keycloak_client_secret)
    if [ -z "${CLIENT_SECRET}" ]; then
        log_error "无法获取 Client Secret，请检查 KC_CLIENT_ID 是否存在"
        exit 1
    fi
    log_info "Client Secret 获取成功"

    create_api_route
    create_openapi_route
    create_users_route
    create_admin_route
    print_summary

    log_info "APISIX 初始化完成!"
}

main "$@"