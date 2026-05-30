import os

NACOS_HOST = os.getenv("NACOS_HOST", "nacos")
NACOS_PORT = int(os.getenv("NACOS_PORT", "8848"))
NACOS_NAMESPACE = os.getenv("NACOS_NAMESPACE", "")
NACOS_USERNAME = os.getenv("NACOS_USERNAME", "nacos")
NACOS_PASSWORD = os.getenv("NACOS_PASSWORD", "nacos")

SERVICE_NAME = "fastapi-service"
SERVICE_HOST = os.getenv("SERVICE_HOST", "fastapi-service")
SERVICE_PORT = int(os.getenv("SERVICE_PORT", "8000"))