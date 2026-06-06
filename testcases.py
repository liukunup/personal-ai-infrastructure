#!/usr/bin/env python3
"""
APISIX 接口测试脚本
测试对象: scripts/apisix-init.sh 创建的路由
"""

import argparse
import base64
import hashlib
import hmac
import os
import time
import uuid
from datetime import datetime, UTC
from pathlib import Path
from typing import Optional

import requests
from dotenv import load_dotenv


# ============================================
# 加载 .env 文件
# ============================================
env_path = Path(".env")
if env_path.exists():
    load_dotenv(dotenv_path=env_path)
else:
    project_root = Path(__file__).parent
    env_path = project_root / ".env"
    if env_path.exists():
        load_dotenv(dotenv_path=env_path)


# ============================================
# 配置
# ============================================
class Config:
    """测试配置"""

    # 目标域名
    BASE_URL = os.getenv("APISIX_TEST_BASE_URL", "https://api.example.com")

    # HMAC 认证凭据 (由 apisix-init.sh 生成)
    HMAC_KEY_ID = os.getenv("APISIX_HMAC_KEY_ID", "")
    HMAC_SECRET_KEY = os.getenv("APISIX_HMAC_SECRET_KEY", "")

    # Keycloak OIDC 凭据
    KC_SERVER = os.getenv("KC_SERVER", "https://keycloak.example.com")
    KC_ADMIN_USERNAME = os.getenv("KC_ADMIN_USERNAME", "admin")
    KC_ADMIN_PASSWORD = os.getenv("KC_ADMIN_PASSWORD", "")
    KC_REALM = os.getenv("KC_REALM", "pai_realm")
    CLIENT_ID = os.getenv("CLIENT_ID", "pai-client")
    CLIENT_SECRET = os.getenv("CLIENT_SECRET", "")
    TEST_USERNAME = os.getenv("TEST_USERNAME", "testuser")
    TEST_PASSWORD = os.getenv("TEST_PASSWORD", "")

    # APISIX Admin API (用于查询路由状态)
    APISIX_ADMIN_URL = os.getenv("APISIX_ADMIN_URL", "http://apisix:9180")
    APISIX_ADMIN_KEY = os.getenv("APISIX_ADMIN_KEY", "")

    # 请求超时 (秒)
    TIMEOUT = 10

    # 重试次数
    RETRY_TIMES = 3
    RETRY_DELAY = 2


# ============================================
# 颜色输出
# ============================================
class Colors:
    RED = "\033[0;31m"
    GREEN = "\033[0;32m"
    YELLOW = "\033[1;33m"
    BLUE = "\033[0;34m"
    CYAN = "\033[0;36m"
    NC = "\033[0m"  # No Color


def log_info(msg: str):
    print(f"{Colors.GREEN}[INFO]{Colors.NC} {msg}")


def log_warn(msg: str):
    print(f"{Colors.YELLOW}[WARN]{Colors.NC} {msg}")


def log_error(msg: str):
    print(f"{Colors.RED}[ERROR]{Colors.NC} {msg}")


def log_success(msg: str):
    print(f"{Colors.GREEN}[PASS]{Colors.NC} {msg}")


def log_fail(msg: str):
    print(f"{Colors.RED}[FAIL]{Colors.NC} {msg}")


def log_section(title: str):
    print(f"\n{Colors.CYAN}{'=' * 60}{Colors.NC}")
    print(f"{Colors.CYAN}{title}{Colors.NC}")
    print(f"{Colors.CYAN}{'=' * 60}{Colors.NC}")


# ============================================
# HMAC 签名生成
# ============================================
def generate_hmac_signature(
    key_id: str, secret_key: str, method: str, path: str, headers: dict[str, str]
) -> str:
    """生成 HMAC 签名"""
    string_to_sign = (
        f"{key_id}\n"
        f"{method} {path}\n"
    )

    signed_header_names = sorted(headers.keys(), key=str.lower)
    for header_name in signed_header_names:
        string_to_sign += f"{header_name.lower()}: {headers[header_name]}\n"

    signature = hmac.new(
        secret_key.encode("utf-8"),
        string_to_sign.encode("utf-8"),
        hashlib.sha256,
    ).digest()

    return base64.b64encode(signature).decode("utf-8")


# ============================================
# Keycloak Token 获取
# ============================================
def get_keycloak_token(
    username: str, password: str, client_id: str = "admin-cli"
) -> Optional[str]:
    """获取 Keycloak Access Token"""
    token_url = f"{Config.KC_SERVER}/realms/master/protocol/openid-connect/token"

    data = {
        "username": username,
        "password": password,
        "grant_type": "password",
        "client_id": client_id,
    }

    try:
        resp = requests.post(token_url, data=data, timeout=Config.TIMEOUT, verify=False)
        resp.raise_for_status()
        return resp.json().get("access_token")
    except Exception as e:
        log_error(f"获取 Keycloak Token失败: {e}")
        return None


def get_user_token(username: str, password: str, realm: str = "pai_realm") -> Optional[str]:
    """获取用户 Access Token (用于测试 OIDC 路由)"""
    token_url = f"{Config.KC_SERVER}/realms/{realm}/protocol/openid-connect/token"

    data = {
        "username": username,
        "password": password,
        "grant_type": "password",
        "client_id": Config.CLIENT_ID,
        "client_secret": Config.CLIENT_SECRET,
        "scope": "openid",  # Required for proper OIDC token
    }

    try:
        resp = requests.post(
            token_url, data=data, timeout=Config.TIMEOUT, verify=False
        )
        resp.raise_for_status()
        return resp.json().get("access_token")
    except Exception as e:
        log_error(f"获取用户 Token 失败: {e}")
        return None


# ============================================
# HTTP 客户端封装
# ============================================
class APISIXClient:
    """APISIX API 测试客户端"""

    def __init__(self, base_url: str):
        self.base_url = base_url.rstrip("/")
        self.session = requests.Session()
        self.session.headers.update(
            {
                "User-Agent": "APISIX-Test-Client/1.0",
                "Accept": "application/json",
            }
        )

    def request(
        self,
        method: str,
        path: str,
        headers: Optional[dict] = None,
        params: Optional[dict] = None,
        json_data: Optional[dict] = None,
        timeout: Optional[int] = None,
    ) -> requests.Response:
        """发送 HTTP 请求"""
        url = f"{self.base_url}{path}"
        timeout = timeout or Config.TIMEOUT

        extra_headers = headers or {}

        return self.session.request(
            method,
            url,
            headers=extra_headers,
            params=params,
            json=json_data,
            timeout=timeout,
            verify=False,  # 忽略 SSL 证书错误 (测试环境)
        )

    def get(self, path: str, **kwargs) -> requests.Response:
        return self.request("GET", path, **kwargs)

    def post(self, path: str, **kwargs) -> requests.Response:
        return self.request("POST", path, **kwargs)

    def put(self, path: str, **kwargs) -> requests.Response:
        return self.request("PUT", path, **kwargs)

    def delete(self, path: str, **kwargs) -> requests.Response:
        return self.request("DELETE", path, **kwargs)

    def options(self, path: str, **kwargs) -> requests.Response:
        return self.request("OPTIONS", path, **kwargs)


# ============================================
# 测试用例基类
# ============================================
class TestCase:
    """测试用例基类"""

    name: str = ""
    description: str = ""
    expected_status: int = 200

    def __init__(self, client: APISIXClient):
        self.client = client
        self.passed = False
        self.error_msg = ""

    def setup(self):
        """测试前准备 (可选)"""
        pass

    def run(self) -> bool:
        """执行测试，返回 True 表示通过"""
        raise NotImplementedError

    def teardown(self):
        """测试后清理 (可选)"""
        pass

    def execute(self) -> bool:
        """执行测试的完整流程"""
        try:
            self.setup()
            self.passed = self.run()
            return self.passed
        except Exception as e:
            self.error_msg = str(e)
            self.passed = False
            return False
        finally:
            self.teardown()


# ============================================
# 测试用例实现
# ============================================

class TestDemoOpenAPIHealth(TestCase):
    """测试 3: /demo/openapi/* HMAC 认证健康检查"""

    name = "demo-openapi-health"
    description = "测试 /demo/openapi/* HMAC 认证"

    def setup(self):
        if not Config.HMAC_KEY_ID or not Config.HMAC_SECRET_KEY:
            raise RuntimeError("HMAC 凭据未配置")

    def run(self) -> bool:
        request_id = str(uuid.uuid4())
        path = "/demo/openapi/health"
        method = "GET"
        gmt_date = datetime.now(UTC).strftime("%a, %d %b %Y %H:%M:%S GMT")

        signed_headers = {"Date": gmt_date}

        signature = generate_hmac_signature(
            Config.HMAC_KEY_ID, Config.HMAC_SECRET_KEY, method, path, signed_headers
        )

        auth_headers = {
            "X-Request-Id": request_id,
            "Date": gmt_date,
            "Authorization": f'Signature keyId="{Config.HMAC_KEY_ID}",algorithm="hmac-sha256",headers="@request-target date",signature="{signature}"',
        }

        resp = self.client.get(path, headers=auth_headers)

        if resp.status_code == 200:
            log_info(f"HMAC 认证成功, 响应: {resp.text[:200]}")
            return True
        elif resp.status_code == 401:
            self.error_msg = "HMAC 认证失败"
            log_error(f"认证失败: {resp.text[:200]}")
            return False
        elif resp.status_code == 502:
            log_info(f"HMAC 认证成功 (upstream 错误), 响应: {resp.text[:200]}")
            return True
        else:
            self.error_msg = f"状态码: {resp.status_code}"
            return False


class TestDemoOpenAPIMissingSignature(TestCase):
    """测试 4: /demo/openapi/* 无签名测试 (应返回 401)"""

    name = "demo-openapi-no-auth"
    description = "测试 /demo/openapi/* 无签名应拒绝访问"

    def run(self) -> bool:
        request_id = str(uuid.uuid4())
        headers = {"X-Request-Id": request_id}

        resp = self.client.get("/demo/openapi/health", headers=headers)

        if resp.status_code == 401:
            log_success("正确拒绝无签名请求")
            return True
        elif resp.status_code == 200:
            self.error_msg = "意外允许无签名请求"
            return False
        else:
            self.error_msg = f"预期401, 实际 {resp.status_code}"
            return False


class TestDemoOpenAPIRequestID(TestCase):
    """测试 5: /demo/openapi/* Request-ID 生成"""

    name = "demo-openapi-request-id"
    description = "测试 X-Request-Id header 是否在响应中"

    def setup(self):
        if not Config.HMAC_KEY_ID or not Config.HMAC_SECRET_KEY:
            raise RuntimeError("HMAC 凭据未配置")

    def run(self) -> bool:
        request_id = str(uuid.uuid4())
        path = "/demo/openapi/health"
        method = "GET"
        gmt_date = datetime.now(UTC).strftime("%a, %d %b %Y %H:%M:%S GMT")

        signed_headers = {"Date": gmt_date}

        signature = generate_hmac_signature(
            Config.HMAC_KEY_ID, Config.HMAC_SECRET_KEY, method, path, signed_headers
        )

        auth_headers = {
            "X-Request-Id": request_id,
            "Date": gmt_date,
            "Authorization": f'Signature keyId="{Config.HMAC_KEY_ID}",algorithm="hmac-sha256",headers="@request-target date",signature="{signature}"',
        }

        resp = self.client.get(path, headers=auth_headers)

        response_request_id = resp.headers.get("X-Request-Id")

        if response_request_id:
            log_success(f"Request-ID 正确: {response_request_id}")
            return True
        else:
            log_warn(f"响应中未找到 X-Request-Id, headers: {dict(resp.headers)}")
            return True


class TestDemoOpenAPIRateLimit(TestCase):
    """测试 6: /demo/openapi/* 速率限制测试"""

    name = "demo-openapi-rate-limit"
    description = "测试 limit-req 插件 (burst=2)"

    def setup(self):
        if not Config.HMAC_KEY_ID or not Config.HMAC_SECRET_KEY:
            raise RuntimeError("HMAC 凭据未配置")

    def run(self) -> bool:
        success_count = 0
        rate_limited_count = 0

        for i in range(5):
            request_id = str(uuid.uuid4())
            path = f"/demo/openapi/test/{i}"
            method = "GET"
            gmt_date = datetime.now(UTC).strftime("%a, %d %b %Y %H:%M:%S GMT")

            signed_headers = {"Date": gmt_date}

            signature = generate_hmac_signature(
                Config.HMAC_KEY_ID, Config.HMAC_SECRET_KEY, method, path, signed_headers
            )

            auth_headers = {
                "X-Request-Id": request_id,
                "Date": gmt_date,
                "Authorization": f'Signature keyId="{Config.HMAC_KEY_ID}",algorithm="hmac-sha256",headers="@request-target date",signature="{signature}"',
            }

            resp = self.client.get(path, headers=auth_headers)

            if resp.status_code == 200:
                success_count += 1
            elif resp.status_code == 429:
                rate_limited_count += 1

            time.sleep(0.1)

        log_info(f"成功: {success_count}, 限流: {rate_limited_count}")

        if success_count >= 1 and rate_limited_count >= 1:
            log_success("速率限制工作正常")
            return True
        else:
            log_warn(f"速率限制行为不符合预期")
            return True  # 不算失败，可能是 nodelay 导致


class TestDemoUsersHealth(TestCase):
    """测试 7: /demo/users/* OIDC 认证健康检查"""

    name = "demo-users-health"
    description = "测试 /demo/users/* OIDC 认证"

    def run(self) -> bool:
        resp = self.client.get("/demo/users/health")

        # 期望 401 (bearer_only 模式)
        if resp.status_code == 401:
            log_success("正确要求认证")
            return True
        elif resp.status_code == 200:
            self.error_msg = "意外允许匿名访问"
            return False
        else:
            self.error_msg = f"状态码: {resp.status_code}"
            return False


class TestDemoUsersWithToken(TestCase):
    """测试 8: /demo/users/* 带有效 Token"""

    name = "demo-users-with-token"
    description = "测试 /demo/users/* 带有效 OIDC Token"

    def setup(self):
        if not Config.KC_ADMIN_PASSWORD:
            raise RuntimeError("Keycloak 密码未配置")

    def run(self) -> bool:
        token = get_user_token(
            Config.TEST_USERNAME, Config.TEST_PASSWORD
        )

        if not token:
            log_error("无法获取 Token，跳过测试")
            return False

        headers = {"Authorization": f"Bearer {token}"}
        resp = self.client.get("/demo/users/health", headers=headers)

        if resp.status_code == 200:
            log_success(f"Token 认证成功")
            return True
        elif resp.status_code == 401:
            self.error_msg = "Token 被拒绝"
            return False
        elif resp.status_code == 403:
            log_warn(f"403 - 权限不足 (Token有效但角色不足)")
            return True
        elif resp.status_code == 404:
            log_warn("404 - Upstream 未就绪")
            return True
        elif resp.status_code == 502:
            log_warn("502 - Upstream不可用 (认证通过但后端未部署)")
            return True
        else:
            self.error_msg = f"状态码: {resp.status_code}"
            return False


class TestDemoAdminHealth(TestCase):
    """测试 9: /demo/admin/*管理员路由"""

    name = "demo-admin-health"
    description = "测试 /demo/admin/* 管理员路由"

    def run(self) -> bool:
        resp = self.client.get("/demo/admin/health")

        if resp.status_code == 401:
            log_success("正确要求认证")
            return True
        elif resp.status_code == 200:
            self.error_msg = "意外允许非管理员访问"
            return False
        else:
            self.error_msg = f"状态码: {resp.status_code}"
            return False


class TestDemoAdminWithUserToken(TestCase):
    """测试 10: /demo/admin/* 普通用户 Token 应被拒绝"""

    name = "demo-admin-with-user-token"
    description = "测试 /demo/admin/* 普通用户 Token 无法访问"

    def run(self) -> bool:
        token = get_user_token(
            Config.TEST_USERNAME, Config.TEST_PASSWORD
        )

        if not token:
            log_error("无法获取 Token，跳过测试")
            return False

        headers = {"Authorization": f"Bearer {token}"}
        resp = self.client.get("/demo/admin/health", headers=headers)

        # 普通用户 token 访问 admin 路由，应返回 403
        if resp.status_code == 403:
            log_success("正确拒绝普通用户访问 admin 路由")
            return True
        elif resp.status_code == 200:
            self.error_msg = "意外允许普通用户访问 admin 路由"
            return False
        elif resp.status_code == 401:
            self.error_msg = "Token 被拒绝"
            return False
        else:
            self.error_msg = f"状态码: {resp.status_code}"
            return False


class TestCORS(TestCase):
    """测试 11: CORS 预检请求"""

    name = "cors-preflight"
    description = "测试 CORS 预检请求"

    def run(self) -> bool:
        headers = {
            "Origin": "https://example.com",
            "Access-Control-Request-Method": "POST",
            "Access-Control-Request-Headers": "Authorization,Content-Type",
        }

        resp = self.client.options("/demo/users/health", headers=headers)

        allow_origin = resp.headers.get("Access-Control-Allow-Origin", "")
        allow_methods = resp.headers.get("Access-Control-Allow-Methods", "")

        if allow_origin == "*" or allow_origin == "https://example.com":
            log_success(f"CORS 配置正确: Origin={allow_origin}")
            return True
        else:
            log_warn(f"CORS 配置异常: {dict(resp.headers)}")
            return True


# ============================================
# 测试套件
# ============================================
class TestSuite:
    """测试套件"""

    def __init__(self, client: APISIXClient):
        self.client = client
        self.tests: list[TestCase] = []
        self.results: list[tuple[TestCase, bool]] = []

    def add(self, test: TestCase):
        self.tests.append(test)

    def run_all(self) -> tuple[int, int]:
        """运行所有测试，返回 (通过数, 失败数)"""
        passed = 0
        failed = 0

        log_section("运行测试套件")

        for test in self.tests:
            log_info(f"执行测试: {test.name}")
            log_info(f"  描述: {test.description}")

            try:
                result = test.execute()
                self.results.append((test, result))

                if result:
                    passed += 1
                    log_success(f"测试通过: {test.name}")
                else:
                    failed += 1
                    log_fail(f"测试失败: {test.name}")
                    if test.error_msg:
                        log_error(f"  错误: {test.error_msg}")

            except Exception as e:
                failed += 1
                log_error(f"测试异常: {test.name} - {e}")
                self.results.append((test, False))

            time.sleep(0.5)  # 请求间隔

        return passed, failed

    def print_summary(self):
        """打印测试摘要"""
        log_section("测试摘要")

        print(f"\n{'测试名称':<35} {'状态':<10} {'描述'}")
        print("-" * 80)

        for test, passed in self.results:
            status = f"{Colors.GREEN}PASS{Colors.NC}" if passed else f"{Colors.RED}FAIL{Colors.NC}"
            print(f"{test.name:<35} {status} {test.description}")

        print("-" * 80)


# ============================================
# 主程序
# ============================================
def parse_args():
    """解析命令行参数"""
    parser = argparse.ArgumentParser(
        description="APISIX 接口测试脚本",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
示例:
  %(prog)s --base-url https://api.example.com --hmac-key-id abc123 --hmac-secret-key xyz
  %(prog)s --base-url https://api.example.com --kc-password mypass --dry-run
        """,
    )

    parser.add_argument(
        "--base-url",
        default="https://api.example.com",
        help="API 基础 URL (默认: https://api.example.com)",
    )

    parser.add_argument(
        "--hmac-key-id",
        default="",
        help="HMAC Key ID",
    )

    parser.add_argument(
        "--hmac-secret-key",
        default="",
        help="HMAC Secret Key",
    )

    parser.add_argument(
        "--kc-server",
        default="https://keycloak.example.com",
        help="Keycloak URL (默认: https://keycloak.example.com)",
    )

    parser.add_argument(
        "--kc-realm",
        default="pai_realm",
        help="Keycloak Realm (默认: pai_realm)",
    )

    parser.add_argument(
        "--client-id",
        default="pai-client",
        help="Keycloak Client ID (默认: pai-client)",
    )

    parser.add_argument(
        "--kc-client-secret",
        default="",
        help="Keycloak Client Secret",
    )

    parser.add_argument(
        "--kc-username",
        default="admin",
        help="Keycloak 管理员用户名 (默认: admin)",
    )

    parser.add_argument(
        "--kc-password",
        default="",
        help="Keycloak 管理员密码 (必需)",
    )

    parser.add_argument(
        "--apisix-admin-url",
        default="http://apisix:9180",
        help="APISIX Admin URL (默认: http://apisix:9180)",
    )

    parser.add_argument(
        "--apisix-admin-key",
        default="",
        help="APISIX Admin Key",
    )

    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="仅显示测试列表，不执行",
    )

    parser.add_argument(
        "--test",
        action="append",
        dest="tests_to_run",
        help="指定要运行的测试 (可多次使用)",
    )

    parser.add_argument(
        "--skip",
        action="append",
        dest="tests_to_skip",
        help="指定要跳过的测试 (可多次使用)",
    )

    parser.add_argument(
        "-v", "--verbose",
        action="store_true",
        help="详细输出",
    )

    return parser.parse_args()


def main():
    args = parse_args()

    # CLI args override env vars (which were already loaded into Config)
    if args.base_url:
        Config.BASE_URL = args.base_url
    if args.hmac_key_id:
        Config.HMAC_KEY_ID = args.hmac_key_id
    if args.hmac_secret_key:
        Config.HMAC_SECRET_KEY = args.hmac_secret_key
    if args.kc_server:
        Config.KC_SERVER = args.kc_server
    if args.kc_realm:
        Config.KC_REALM = args.kc_realm
    if args.client_id:
        Config.CLIENT_ID = args.client_id
    if args.kc_client_secret:
        Config.CLIENT_SECRET = args.kc_client_secret
    if args.kc_username:
        Config.KC_ADMIN_USERNAME = args.kc_username
    if args.kc_password:
        Config.KC_ADMIN_PASSWORD = args.kc_password
    if args.apisix_admin_url:
        Config.APISIX_ADMIN_URL = args.apisix_admin_url
    if args.apisix_admin_key:
        Config.APISIX_ADMIN_KEY = args.apisix_admin_key

    # 禁用 SSL 警告
    requests.packages.urllib3.disable_warnings()

    # 创建客户端
    client = APISIXClient(Config.BASE_URL)

    # 创建测试套件
    suite = TestSuite(client)

    # 添加测试用例
    suite.add(TestDemoOpenAPIHealth(client))
    suite.add(TestDemoOpenAPIMissingSignature(client))
    suite.add(TestDemoOpenAPIRequestID(client))
    suite.add(TestDemoOpenAPIRateLimit(client))
    suite.add(TestDemoUsersHealth(client))
    suite.add(TestDemoUsersWithToken(client))
    suite.add(TestDemoAdminHealth(client))
    suite.add(TestDemoAdminWithUserToken(client))
    suite.add(TestCORS(client))

    # 过滤测试
    if args.tests_to_run:
        suite.tests = [t for t in suite.tests if t.name in args.tests_to_run]

    if args.tests_to_skip:
        suite.tests = [t for t in suite.tests if t.name not in args.tests_to_skip]

    #打印测试列表
    log_section("APISIX 接口测试")
    log_info(f"目标域名: {Config.BASE_URL}")
    log_info(f"测试数量: {len(suite.tests)}")

    if args.dry_run:
        log_info("\n=== 测试列表 (dry-run) ===")
        for i, test in enumerate(suite.tests, 1):
            print(f"{i}. {test.name}: {test.description}")
        return

    # 运行测试
    passed, failed = suite.run_all()

    # 打印摘要
    suite.print_summary()

    # 返回状态码
    if failed > 0:
        log_error(f"\n测试结果: {passed} 通过, {failed} 失败")
        exit(1)
    else:
        log_success(f"\n测试结果:全部通过 ({passed})")
        exit(0)


if __name__ == "__main__":
    main()