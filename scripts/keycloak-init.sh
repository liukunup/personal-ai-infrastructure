#!/bin/bash
set -e

# ============================================
# Keycloak 初始化脚本
# ============================================

# 环境变量
KC_SERVER="${KC_SERVER:-http://keycloak:8080}"
KC_REALM="${KC_REALM:?KC_REALM is not set}"
KC_ADMIN_USERNAME="${KC_ADMIN_USERNAME:-admin}"
KC_ADMIN_PASSWORD="${KC_ADMIN_PASSWORD:?KC_ADMIN_PASSWORD is not set}"
CLIENT_ID="${CLIENT_ID:-pai-client}"
CLIENT_NAME="${CLIENT_NAME:-PAI Client}"
TEST_USERNAME="${TEST_USERNAME:-testuser}"
TEST_PASSWORD="${TEST_PASSWORD:?TEST_PASSWORD is not set}"
TEST_FIRSTNAME="${TEST_FIRSTNAME:-Test}"
TEST_LASTNAME="${TEST_LASTNAME:-User}"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ============================================
# 1. 初始化 kcadm 配置
# ============================================
init_kcadm() {
    log_info "初始化 kcadm 配置..."

    KCADM="/opt/keycloak/bin/kcadm.sh"

    ${KCADM} config credentials \
        --server "${KC_SERVER}" \
        --realm master \
        --user "${KC_ADMIN_USERNAME}" \
        --password "${KC_ADMIN_PASSWORD}"

    log_info "kcadm 登录成功"
}

# ============================================
# 2. 创建 Realm
# ============================================
create_realm() {
    log_info "创建 Realm: ${KC_REALM}"

    if ${KCADM} get realms/${KC_REALM} > /dev/null 2>&1; then
        log_warn "Realm '${KC_REALM}' 已存在，跳过创建"
        return 0
    fi

    ${KCADM} create realms \
        -s realm=${KC_REALM} \
        -s enabled=true

    log_info "Realm '${KC_REALM}' 创建成功"
}

# ============================================
# 3. 创建 Groups
# ============================================
create_groups() {
    log_info "创建 Groups: admin, user, guest"

    local groups=("admin" "user" "guest")

    for group in "${groups[@]}"; do
        if ${KCADM} get groups -r ${KC_REALM} -q name=${group} 2>/dev/null | grep -q '"name" : "'${group}'"'; then
            log_warn "Group '${group}' 已存在，跳过创建"
        else
            ${KCADM} create groups -r ${KC_REALM} -s name=${group}
            log_info "Group '${group}' 创建成功"
        fi
    done
}

# ============================================
# 4. 创建 Client
# ============================================
create_client() {
    log_info "创建 Client: ${CLIENT_ID}"

    local client_existing
    client_existing=$(${KCADM} get clients -r ${KC_REALM} -q clientId=${CLIENT_ID} 2>/dev/null | grep -c '"clientId" : "'${CLIENT_ID}'"' || true)

    if [ "${client_existing}" -eq 0 ]; then
        ${KCADM} create clients -r ${KC_REALM} \
            -s clientId=${CLIENT_ID} \
            -s name="${CLIENT_NAME}" \
            -s enabled=true \
            -s publicClient=false \
            -s bearerOnly=false \
            -s protocol=openid-connect
        log_info "Client '${CLIENT_ID}' 创建成功"
    else
        log_warn "Client '${CLIENT_ID}' 已存在，更新名称..."
        local client_uuid
        client_uuid=$(${KCADM} get clients -r ${KC_REALM} -q clientId=${CLIENT_ID} --fields id --format csv --noquotes | tr -d '[:space:]')
        ${KCADM} update clients/${client_uuid} -r ${KC_REALM} -s name="${CLIENT_NAME}"
        log_info "Client 名称已更新为 ${CLIENT_NAME}"
    fi
}

# ============================================
# 5. 获取 Client Secret
# ============================================
get_client_secret() {
    log_info "获取 Client Secret..."

    local client_uuid
    client_uuid=$(${KCADM} get clients -r ${KC_REALM} -q clientId=${CLIENT_ID} --fields id --format csv --noquotes | tr -d '[:space:]')

    CLIENT_SECRET=$(${KCADM} get clients/${client_uuid}/client-secret -r ${KC_REALM} --fields value --format csv --noquotes)
    log_info "Client Secret: ${CLIENT_SECRET}"
}

# ============================================
# 6. 创建测试用户
# ============================================
create_user() {
    log_info "创建测试用户: ${TEST_USERNAME}"

    local user_existing
    user_existing=$(${KCADM} get users -r ${KC_REALM} -q username=${TEST_USERNAME} 2>/dev/null | grep -c '"username" : "'${TEST_USERNAME}'"' || true)

    if [ "${user_existing}" -eq 0 ]; then
        ${KCADM} create users -r ${KC_REALM} \
            -s username=${TEST_USERNAME} \
            -s enabled=true \
            -s email="${TEST_USERNAME}@example.com" \
            -s firstName="${TEST_FIRSTNAME}" \
            -s lastName="${TEST_LASTNAME}" \
            -i > /dev/null

        ${KCADM} set-password -r ${KC_REALM} --username ${TEST_USERNAME} --new-password ${TEST_PASSWORD}
        log_info "用户 '${TEST_USERNAME}' 创建成功，密码: ${TEST_PASSWORD}"
    else
        log_warn "用户 '${TEST_USERNAME}' 已存在，更新信息..."
        local user_id
        user_id=$(${KCADM} get users -r ${KC_REALM} -q username=${TEST_USERNAME} --fields id --format csv --noquotes | tr -d '[:space:]')
        ${KCADM} update users/${user_id} -r ${KC_REALM} -s firstName="${TEST_FIRSTNAME}" -s lastName="${TEST_LASTNAME}"
        ${KCADM} set-password -r ${KC_REALM} --username ${TEST_USERNAME} --new-password ${TEST_PASSWORD}
        log_info "用户 '${TEST_USERNAME}' 已更新，密码: ${TEST_PASSWORD}"
    fi
}

# ============================================
# 7. 将用户加入 user 组
# ============================================
assign_user_to_group() {
    log_info "将用户 ${TEST_USERNAME} 加入 user 组..."

    local user_id
    user_id=$(${KCADM} get users -r ${KC_REALM} -q username=${TEST_USERNAME} --fields id --format csv --noquotes | tr -d '[:space:]')

    local groups_json
    groups_json=$(${KCADM} get groups -r ${KC_REALM} 2>/dev/null)
    local user_group_id
    user_group_id=$(echo "${groups_json}" | grep -B1 '"name" : "user"' | grep '"id"' | sed 's/.*"id" : "\([^"]*\)".*/\1/')

    ${KCADM} update "users/${user_id}/groups/${user_group_id}" -r ${KC_REALM} -b '{}'
    log_info "用户 '${TEST_USERNAME}' 已加入 user 组"
}

# ============================================
# 8. 打印配置摘要
# ============================================
print_summary() {
    log_info "=========================================="
    log_info "Keycloak 配置完成!"
    log_info "=========================================="
    log_info "Realm: ${KC_REALM}"
    log_info "Client: ${CLIENT_ID}"
    log_info "Client Secret: ${CLIENT_SECRET}"
    log_info ""
    log_info "测试用户:"
    log_info "  ${TEST_USERNAME} (密码: ${TEST_PASSWORD})"
    log_info "  First Name: ${TEST_FIRSTNAME}, Last Name: ${TEST_LASTNAME}"
    log_info "  所属组: user"
    log_info ""
    log_info "Keycloak 管理控制台: https://keycloak.example.com/"
    log_info "=========================================="
}

# ============================================
# 主流程
# ============================================
main() {
    init_kcadm
    create_realm
    create_groups
    create_client
    get_client_secret
    create_user
    assign_user_to_group
    print_summary
}

main "$@"