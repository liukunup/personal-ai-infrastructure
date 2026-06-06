#!/bin/bash

set -e  # 遇到错误立即退出

# 根证书配置
CA_SUBJECT="/C=CN/ST=Guangdong/L=Shenzhen/O=Example Ltd/CN=Example Root CA"
CA_KEY="ca.key"
CA_CRT="ca.crt"
CA_DAYS=3650
CA_KEY_BITS=4096

DH_FILE="dhparam.pem"
DH_BITS=2048

# 域名列表（空格分隔）
DOMAINS="api.example.com keycloak.example.com"

# 证书配置
CERT_DAYS=365
CERT_KEY_BITS=2048
CERT_SUBJECT_BASE="/C=CN/ST=Guangdong/L=Shenzhen/O=Example Ltd/CN="

# 主目录（当前脚本所在目录的 nginx_conf/ssl 子目录）
BASE_DIR="$(cd "$(dirname "$0")" && pwd)/nginx_conf/ssl"
echo "运行路径: ${BASE_DIR}"

# 创建目录
mkdir -p "${BASE_DIR}"
cd "${BASE_DIR}"

# ===== 1. 生成 DH 参数文件 =====
echo ""
echo "[1/3] 检查 Diffie-Hellman 参数文件..."

if [ -f "${DH_FILE}" ]; then
    echo "✓ DH 参数文件已存在，跳过: ${DH_FILE}"
else
    echo "→ 正在生成 DH 参数文件（${DH_BITS} 位），可能需要几分钟..."
    openssl dhparam -out "${DH_FILE}" "${DH_BITS}"
    echo "✓ DH 参数文件生成完成: ${DH_FILE}"
fi

# ===== 2. 生成根证书 =====
echo ""
echo "[2/3] 检查根证书..."

if [ -f "${CA_CRT}" ] && [ -f "${CA_KEY}" ]; then
    echo "✓ 根证书已存在，跳过: ${CA_CRT} 和 ${CA_KEY}"
else
    echo "→ 正在生成根证书..."
    openssl req -x509 \
        -newkey "rsa:${CA_KEY_BITS}" \
        -sha256 \
        -days "${CA_DAYS}" \
        -nodes \
        -keyout "${CA_KEY}" \
        -out "${CA_CRT}" \
        -subj "${CA_SUBJECT}"
    echo "✓ 根证书生成完成: ${CA_CRT} 和 ${CA_KEY}"
fi

# ===== 3. 为每个域名生成证书 =====
echo ""
echo "[3/3] 开始生成域名证书..."

for DOMAIN in ${DOMAINS}; do
    echo ""
    echo "----------------------------------------"
    echo "域名: ${DOMAIN}"
    echo "----------------------------------------"

    # 创建域名专属文件夹
    DOMAIN_DIR="${BASE_DIR}/${DOMAIN}"
    mkdir -p "${DOMAIN_DIR}"

    # 定义文件路径
    KEY_FILE="${DOMAIN_DIR}/server.key"
    CSR_FILE="${DOMAIN_DIR}/server.csr"
    CRT_FILE="${DOMAIN_DIR}/server.crt"

    # 检查证书和私钥是否已存在
    if [ -f "${CRT_FILE}" ] && [ -f "${KEY_FILE}" ]; then
        echo "✓ 域名 ${DOMAIN} 的证书已存在，跳过"
        echo "  证书 ${CRT_FILE}"
        echo "  私钥 ${KEY_FILE}"
        continue
    fi

    # 1) 生成私钥和 CSR
    echo "→ 生成私钥和证书签名请求（CSR）..."
    openssl req -newkey "rsa:${CERT_KEY_BITS}" \
        -nodes \
        -keyout "${KEY_FILE}" \
        -out "${CSR_FILE}" \
        -subj "${CERT_SUBJECT_BASE}${DOMAIN}"

    # 2) 使用根证书签名生成最终证书
    echo "→ 使用根证书签名生成最终证书..."
    openssl x509 -req \
        -CA "${CA_CRT}" \
        -CAkey "${CA_KEY}" \
        -CAcreateserial \
        -in "${CSR_FILE}" \
        -out "${CRT_FILE}" \
        -days "${CERT_DAYS}" \
        -sha256 \
        -extfile <(echo -e "subjectAltName=DNS:*.${DOMAIN},DNS:${DOMAIN}\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth")

    # 清理临时 CSR 文件（可选，取消注释以删除）
    rm -f "${CSR_FILE}"

    echo "✓ 域名 ${DOMAIN} 证书生成完成"
    echo "  私钥 ${KEY_FILE}"
    echo "  证书 ${CRT_FILE}"
done

echo ""
echo "所有证书生成完成！"
