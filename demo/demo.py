import os
from contextlib import asynccontextmanager
from v2.nacos import (
    NacosNamingService,
    ClientConfigBuilder,
    GRPCConfig,
    RegisterInstanceParam,
    DeregisterInstanceParam,
)
from fastapi import FastAPI


# Nacos
NACOS_HOST = os.getenv("NACOS_HOST", "nacos")
NACOS_PORT = os.getenv("NACOS_PORT", "8848")
# Service
SERVICE_NAME = os.getenv("SERVICE_NAME", "demo-service")
SERVICE_HOST = os.getenv("SERVICE_HOST", "demo")
SERVICE_PORT = int(os.getenv("SERVICE_PORT", "8000"))

client = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    global client
    config = ClientConfigBuilder() \
        .server_address(f"{NACOS_HOST}:{NACOS_PORT}") \
        .log_level("INFO") \
        .grpc_config(GRPCConfig(grpc_timeout=5000)) \
        .build()
    client = await NacosNamingService.create_naming_service(config)
    await client.register_instance(RegisterInstanceParam(
        service_name=SERVICE_NAME, group_name="DEFAULT_GROUP",
        ip=SERVICE_HOST, port=SERVICE_PORT,
        cluster_name="DEFAULT", weight=1.0, ephemeral=True,
    ))
    print(f"Registered {SERVICE_NAME}@{SERVICE_HOST}:{SERVICE_PORT}")
    yield
    if client:
        await client.deregister_instance(DeregisterInstanceParam(
            service_name=SERVICE_NAME, group_name="DEFAULT_GROUP",
            ip=SERVICE_HOST, port=SERVICE_PORT, ephemeral=True,
        ))


app = FastAPI(lifespan=lifespan)


@app.get("/")
async def root():
    return {"service": SERVICE_NAME, "message": "Hello from Nacos Server!"}


@app.get("/health")
async def health():
    return {"status": "ok"}


@app.get("/api/v1/echo")
async def echo(msg: str = "default"):
    from datetime import datetime
    return {
        "echo": msg,
        "timestamp": datetime.now(datetime.timezone.utc).isoformat() + "Z",
        "service": SERVICE_NAME
    }


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=SERVICE_PORT)