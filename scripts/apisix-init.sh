#!/bin/sh
set -e

# ============================================
# APISIX 初始化脚本
# ============================================

# 环境变量
APISIX_URL="${APISIX_URL:-http://apisix:9180}"
APISIX_STATUS_URL="${APISIX_STATUS_URL:-http://apisix:7085/status/ready}"

APISIX_CONF="${APISIX_CONF:-/usr/local/apisix/conf/config.yaml}"
APISIX_ADMIN_KEY="${APISIX_ADMIN_KEY:-$(grep -A1 'name: admin' "${APISIX_CONF}" 2>/dev/null | grep 'key:' | awk '{print $2}' | head -1)}"

KC_SERVER="${KC_SERVER:-http://keycloak:8080}"
KC_REALM="${KC_REALM:?KC_REALM is not set}"
KC_ADMIN_USERNAME="${KC_ADMIN_USERNAME:-admin}"
KC_ADMIN_PASSWORD="${KC_ADMIN_PASSWORD:?KC_ADMIN_PASSWORD is not set}"

CLIENT_ID="${CLIENT_ID:-pai-client}"

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
    echo "${KC_SERVER}/realms/${KC_REALM}/.well-known/openid-configuration"
}

# ============================================
# Helper: 等待 APISIX 就绪
# ============================================
wait_for_apisix_ready() {
    local max_attempts=30
    local attempt=1

    log_info "等待 APISIX 就绪 (${APISIX_STATUS_URL})..."

    while [ $attempt -le $max_attempts ]; do
        if curl -sf "${APISIX_STATUS_URL}" > /dev/null 2>&1; then
            log_info "APISIX 已就绪 (尝试 ${attempt}/${max_attempts})"
            return 0
        fi
        log_warn "等待 APISIX 就绪... (${attempt}/${max_attempts})"
        sleep 3
        attempt=$((attempt + 1))
    done

    log_error "APISIX 就绪检查失败，已超时 (${max_attempts} 次尝试)"
    return 1
}

# ============================================
# Helper: 获取 Keycloak Client Secret
# ============================================
get_keycloak_client_secret() {
    local kc_server="${KC_SERVER:-http://keycloak:8080}"
    local kc_admin_username="${KC_ADMIN_USERNAME:-admin}"
    local kc_admin_password="${KC_ADMIN_PASSWORD}"
    local client_id="${CLIENT_ID:-pai-client}"

    local token
    token=$(curl -s -X POST "${kc_server}/realms/master/protocol/openid-connect/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "username=${kc_admin_username}&password=${kc_admin_password}&grant_type=password&client_id=admin-cli" \
        | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)

    local client_uuid
    client_uuid=$(curl -s -X GET "${kc_server}/admin/realms/${KC_REALM}/clients?clientId=${client_id}" \
        -H "Authorization: Bearer ${token}" \
        | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)

    curl -s -X GET "${kc_server}/admin/realms/${KC_REALM}/clients/${client_uuid}/client-secret" \
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
# 2. 创建 HMAC Consumer 和 Credential
# ============================================
create_hmac_consumer() {
    log_info "创建 HMAC Consumer 和 Credential"

    # 创建 Consumer
    local consumer_json='{
        "username": "hmac-consumer",
        "desc": "HMAC authentication consumer"
    }'

    local consumer_response
    consumer_response=$(curl -s -X PUT "${APISIX_URL}/apisix/admin/consumers/hmac-consumer" \
        -H "X-API-KEY: ${APISIX_ADMIN_KEY}" \
        -H "Content-Type: application/json" \
        -d "${consumer_json}")

    if echo "${consumer_response}" | grep -q '"code":0\|"username":"hmac-consumer"'; then
        log_info "Consumer 'hmac-consumer' 创建成功"
    else
        log_warn "Consumer 响应: ${consumer_response}"
    fi

    # 创建 HMAC Credential
    local credential_json='{
        "id": "hmac-credential",
        "plugins": {
            "hmac-auth": {
                "key_id": "'"${HMAC_KEY_ID}"'",
                "secret_key": "'"${HMAC_SECRET_KEY}"'",
                "signed_headers": ["X-Request-Id"]
            }
        }
    }'

    local credential_response
    credential_response=$(curl -s -X PUT "${APISIX_URL}/apisix/admin/consumers/hmac-consumer/credentials" \
        -H "X-API-KEY: ${APISIX_ADMIN_KEY}" \
        -H "Content-Type: application/json" \
        -d "${credential_json}")

    if echo "${credential_response}" | grep -q '"code":0\|"id":"hmac-credential"'; then
        log_info "HMAC Credential 'hmac-credential' 创建成功"
    else
        log_warn "Credential 响应: ${credential_response}"
    fi
}

# ============================================
# 3. 创建 Route: /demo/openapi/*
# ============================================
create_openapi_route() {
    log_info "创建 Route: demo-openapi-route"

    local route_json='{
        "id": "demo-openapi-route",
        "name": "demo-openapi-route",
        "desc": "Route for /demo/openapi/*",
        "uri": "/demo/openapi/*",
        "plugins": {
            "proxy-rewrite": {
                "regex_uri": ["^/demo/openapi/(.*)", "/api/v1/$1"]
            },
            "hmac-auth": {
                "allowed_algorithms": ["hmac-sha256"],
                "validate_request_body": true,
                "signed_headers": ["X-Request-Id"]
            },
            "request-id": {
                "header_name": "X-Request-Id",
                "include_in_response": true,
                "algorithm": "uuid"
            },
            "limit-req": {
                "rate": 1,
                "burst": 2,
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
    response=$(curl -s -X PUT "${APISIX_URL}/apisix/admin/routes/demo-openapi-route" \
        -H "X-API-KEY: ${APISIX_ADMIN_KEY}" \
        -H "Content-Type: application/json" \
        -d "${route_json}")

    if echo "${response}" | grep -q '"code":0\|"id":"demo-openapi-route"'; then
        log_info "Route 'demo-openapi-route' 创建成功"
    else
        log_warn "Route 响应: ${response}"
    fi
}

# ============================================
# 4. 创建 Route: /demo/users/* (openid-connect + authz-casbin)
# ============================================
create_users_route() {
    log_info "创建 Route: demo-users-route (openid-connect + authz-casbin)"

    local discovery=$(get_keycloak_discovery)
    local route_json='{
        "id": "demo-users-route",
        "name": "demo-users-route",
        "desc": "Route for /demo/users/* with OIDC and Casbin auth",
        "uri": "/demo/users/*",
        "plugins": {
            "proxy-rewrite": {
                "regex_uri": ["^/demo/users/(.*)", "/api/v1/$1"]
            },
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
    response=$(curl -s -X PUT "${APISIX_URL}/apisix/admin/routes/demo-users-route" \
        -H "X-API-KEY: ${APISIX_ADMIN_KEY}" \
        -H "Content-Type: application/json" \
        -d "${route_json}")

    if echo "${response}" | grep -q '"code":0\|"id":"demo-users-route"'; then
        log_info "Route 'demo-users-route' 创建成功"
    else
        log_warn "Route 响应: ${response}"
    fi
}

# ============================================
# 5. 创建 Route: /demo/admin/* (openid-connect + authz-casbin admin-only)
# ============================================
create_admin_route() {
    log_info "创建 Route: demo-admin-route (openid-connect + authz-casbin admin-only)"

    local discovery=$(get_keycloak_discovery)
    local route_json='{
        "id": "demo-admin-route",
        "name": "demo-admin-route",
        "desc": "Route for /demo/admin/* with OIDC and Casbin auth (admin only)",
        "uri": "/demo/admin/*",
        "plugins": {
            "proxy-rewrite": {
                "regex_uri": ["^/demo/admin/(.*)", "/api/v1/$1"]
            },
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
    response=$(curl -s -X PUT "${APISIX_URL}/apisix/admin/routes/demo-admin-route" \
        -H "X-API-KEY: ${APISIX_ADMIN_KEY}" \
        -H "Content-Type: application/json" \
        -d "${route_json}")

    if echo "${response}" | grep -q '"code":0\|"id":"demo-admin-route"'; then
        log_info "Route 'demo-admin-route' 创建成功"
    else
        log_warn "Route 响应: ${response}"
    fi
}

# ============================================
# 6. 打印摘要
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
    log_info "  consumer: hmac-consumer"
    log_info "  credential_id: hmac-credential"
    log_info "  key_id: ${HMAC_KEY_ID}"
    log_info "  secret_key: ${HMAC_SECRET_KEY}"
    log_info ""
    log_info "Routes:"
    log_info "  - demo-api-route (proxy-rewrite, no auth)"
    log_info "  - demo-openapi-route (hmac-auth + validate_body + signed_headers + request-id + limit-req)"
    log_info "  - demo-users-route (openid-connect + authz-casbin)"
    log_info "  - demo-admin-route (openid-connect + authz-casbin admin-only)"
    log_info "=========================================="
}

# ============================================
# 主流程
# ============================================
main() {
    log_info "开始 APISIX 配置..."
    log_info "APISIX_URL: ${APISIX_URL}"

    log_info "检查 APISIX 就绪状态..."
    if ! wait_for_apisix_ready; then
        log_error "APISIX 未就绪，无法继续初始化"
        exit 1
    fi

    log_info "获取 Keycloak Client Secret..."
    CLIENT_SECRET=$(get_keycloak_client_secret)
    if [ -z "${CLIENT_SECRET}" ]; then
        log_error "无法获取 Client Secret，请检查 KC_CLIENT_ID 是否存在"
        exit 1
    fi
    log_info "Client Secret 获取成功"

    create_api_route
    create_hmac_consumer
    create_openapi_route
    create_users_route
    create_admin_route
    print_summary

    log_info "APISIX 初始化完成!"
}

main "$@"