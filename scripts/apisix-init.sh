#!/bin/bash
set -e

# ============================================
# APISIX Consumer + Routes 自动配置脚本
# 调用 APISIX Admin API
# ============================================

APISIX_URL="${APISIX_URL:-http://apisix:9180}"
ADMIN_KEY="${APISIX_ADMIN_KEY:-edd1c9f034335f136f87ad84b625c8f1}"

# Client secret from Keycloak
KC_REALM="apisix_test_realm"
APISIX_CLIENT_SECRET="${APISIX_CLIENT_SECRET:-vARhVsot5zbV5xR6lOVCj7tItQPSjkL8}"

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
    local keycloak_ip=$(getent hosts keycloak | awk '{print $1}')
    echo "http://${keycloak_ip}:8080/realms/${KC_REALM}/.well-known/openid-configuration"
}

# ============================================
# 1. 等待 APISIX 就绪
# ============================================
wait_for_apisix() {
    log_info "等待 APISIX 就绪..."

    local max_attempts=30
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        if curl -sf "${APISIX_URL}/apisix/admin/health" -H "X-API-KEY: ${ADMIN_KEY}" > /dev/null 2>&1; then
            log_info "APISIX 已就绪"
            return 0
        fi

        echo -n "."
        attempt=$((attempt + 1))
        sleep 2
    done

    log_error "APISIX 启动超时"
    return 1
}

# ============================================
# 2. 创建 Consumer (使用 authz-keycloak)
# ============================================
create_consumer() {
    log_info "创建 Consumer: keycloak-consumer"

    local consumer_json='{
        "username": "keycloak-consumer",
        "plugins": {
            "authz-keycloak": {
                "token_endpoint": "http://keycloak:8080/realms/'${KC_REALM}'/protocol/openid-connect/token",
                "client_id": "apisix",
                "client_secret": "'"${APISIX_CLIENT_SECRET}"'",
                "scope": "openid profile email",
                "ssl_verify": false,
                "bearer_only": false,
                "realm": "'"${KC_REALM}"'"
            }
        }
    }'

    local response
    response=$(curl -s -X PUT "${APISIX_URL}/apisix/admin/consumers/keycloak-consumer" \
        -H "X-API-KEY: ${ADMIN_KEY}" \
        -H "Content-Type: application/json" \
        -d "${consumer_json}")

    if echo "${response}" | grep -q '"code":0\|"username":"keycloak-consumer"'; then
        log_info "Consumer 'keycloak-consumer' 创建成功"
    else
        log_warn "Consumer 响应: ${response}"
    fi
}

# ============================================
# 3. 创建 Route: /demo/page/*
# ============================================
create_page_route() {
    log_info "创建 Route: demo-page-route"

    local route_json='{
        "id": "demo-page-route",
        "uri": "/demo/page/*",
        "plugins": {
            "authz-keycloak": {
                "token_endpoint": "http://keycloak:8080/realms/'${KC_REALM}'/protocol/openid-connect/token",
                "client_id": "apisix",
                "client_secret": "'"${APISIX_CLIENT_SECRET}"'",
                "permissions": ["demo-resource#read"],
                "lazy_load_paths": true,
                "http_method_as_scope": true,
                "policy_enforcement_mode": "ENFORCING",
                "ssl_verify": false
            },
            "authz-casbin": {
                "model": "[request_definition]\nr = sub, obj, act\n[policy_definition]\np = sub, obj, act\n[role_definition]\ng = _, _\n[policy_effect]\ne = some(where (p.eft == allow))\n[matchers]\nm = (g(r.sub, p.sub) || keyMatch(r.sub, p.sub)) && keyMatch(r.obj, p.obj) && keyMatch(r.act, p.act)",
                "policy": "p, *, /, GET\np, admin, *, *\ng, admin, admin",
                "username": "preferred_username"
            },
            "proxy-rewrite": {
                "regex_uri": ["^/demo/page/(.*)", "/$1"]
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
    response=$(curl -s -X PUT "${APISIX_URL}/apisix/admin/routes/demo-page-route" \
        -H "X-API-KEY: ${ADMIN_KEY}" \
        -H "Content-Type: application/json" \
        -d "${route_json}")

    if echo "${response}" | grep -q '"code":0\|"id":"demo-page-route"'; then
        log_info "Route 'demo-page-route' 创建成功"
    else
        log_warn "Route 响应: ${response}"
    fi
}

# ============================================
# 4. 创建 Route: /demo/api/*
# ============================================
create_api_route() {
    log_info "创建 Route: demo-api-route"

    local route_json='{
        "id": "demo-api-route",
        "uri": "/demo/api/*",
        "plugins": {
            "hmac-auth": {
                "key_id": "demo-key",
                "secret_key": "demo-secret-key",
                "allowed_algorithms": ["hmac-sha256"],
                "clock_skew": 30,
                "hide_credentials": false
            },
            "proxy-rewrite": {
                "regex_uri": ["^/demo/api/(.*)", "/$1"]
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
        -H "X-API-KEY: ${ADMIN_KEY}" \
        -H "Content-Type: application/json" \
        -d "${route_json}")

    if echo "${response}" | grep -q '"code":0\|"id":"demo-api-route"'; then
        log_info "Route 'demo-api-route' 创建成功"
    else
        log_warn "Route 响应: ${response}"
    fi
}

# ============================================
# 6. 创建 Route: /api/v1/users/* (openid-connect + authz-casbin)
# ============================================
create_users_route() {
    log_info "Creating Route: users-route (openid-connect + authz-casbin)"

    local discovery=$(get_keycloak_discovery)
    local route_json='{
        "id": "users-route",
        "uri": "/api/v1/users/*",
        "plugins": {
            "openid-connect": {
                "client_id": "apisix",
                "client_secret": "'"${APISIX_CLIENT_SECRET}"'",
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
            "type": "roundrobin",
            "nodes": [{"host": "demo", "port": 8000, "weight": 1}]
        }
    }'

    local response
    response=$(curl -s -X PUT "${APISIX_URL}/apisix/admin/routes/users-route" \
        -H "X-API-KEY: ${ADMIN_KEY}" \
        -H "Content-Type: application/json" \
        -d "${route_json}")

    if echo "${response}" | grep -q '"code":0\|"id":"users-route"'; then
        log_info "Route 'users-route' 创建成功"
    else
        log_warn "Route 响应: ${response}"
    fi
}

# ============================================
# 7. 创建 Route: /api/v1/users/admin/* (openid-connect + authz-casbin admin-only)
# ============================================
create_admin_route() {
    log_info "Creating Route: admin-route (openid-connect + authz-casbin admin-only)"

    local discovery=$(get_keycloak_discovery)
    local route_json='{
        "id": "admin-route",
        "uri": "/api/v1/users/admin/*",
        "plugins": {
            "openid-connect": {
                "client_id": "apisix",
                "client_secret": "'"${APISIX_CLIENT_SECRET}"'",
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
                "policy": "p, admin, /api/v1/users/admin, GET\np, admin, /api/v1/users/admin, POST\np, admin, /api/v1/users/admin, PUT\np, admin, /api/v1/users/admin, DELETE\ng, admin, admin",
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
            "type": "roundrobin",
            "nodes": [{"host": "demo", "port": 8000, "weight": 1}]
        }
    }'

    local response
    response=$(curl -s -X PUT "${APISIX_URL}/apisix/admin/routes/admin-route" \
        -H "X-API-KEY: ${ADMIN_KEY}" \
        -H "Content-Type: application/json" \
        -d "${route_json}")

    if echo "${response}" | grep -q '"code":0\|"id":"admin-route"'; then
        log_info "Route 'admin-route' 创建成功"
    else
        log_warn "Route 响应: ${response}"
    fi
}

# ============================================
# 5. 创建 Route: /api/v1/echo (hmac-auth)
# ============================================
create_echo_route() {
    log_info "Creating Route: echo-route (hmac-auth)"

    local route_json='{
        "id": "echo-route",
        "uri": "/api/v1/echo",
        "plugins": {
            "hmac-auth": {
                "key_id": "echo-key",
                "secret_key": "echo-secret-key",
                "allowed_algorithms": ["hmac-sha256"],
                "clock_skew": 30,
                "hide_credentials": false
            },
            "proxy-rewrite": {
                "uri": "/v1/echo"
            },
            "cors": {
                "allow_origins": "*",
                "allow_methods": "GET,POST,PUT,DELETE,PATCH,OPTIONS",
                "allow_headers": "Authorization,Content-Type,Date",
                "max_age": 3600
            }
        },
        "upstream": {
            "type": "roundrobin",
            "nodes": [{"host": "demo", "port": 8000, "weight": 1}]
        }
    }'

    local response
    response=$(curl -s -X PUT "${APISIX_URL}/apisix/admin/routes/echo-route" \
        -H "X-API-KEY: ${ADMIN_KEY}" \
        -H "Content-Type: application/json" \
        -d "${route_json}")

    if echo "${response}" | grep -q '"code":0\|"id":"echo-route"'; then
        log_info "Route 'echo-route' 创建成功"
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
    log_info "Consumer: keycloak-consumer"
    log_info "Routes:"
    log_info "  - demo-page-route (authz-keycloak + authz-casbin)"
    log_info "  - demo-api-route (hmac-auth)"
    log_info "  - users-route (openid-connect + authz-casbin)"
    log_info "  - admin-route (openid-connect + authz-casbin admin-only)"
    log_info "  - echo-route (hmac-auth)"
    log_info ""
    log_info "Keycloak 认证端点: http://keycloak:8080/realms/${KC_REALM}"
    log_info "=========================================="
}

# ============================================
# 主流程
# ============================================
main() {
    log_info "开始 APISIX 配置..."
    log_info "APISIX_URL: ${APISIX_URL}"

    wait_for_apisix || exit 1
    create_consumer
    create_page_route
    create_api_route
    create_users_route
    create_admin_route
    create_echo_route
    print_summary

    log_info "APISIX 初始化完成!"
}

main "$@"