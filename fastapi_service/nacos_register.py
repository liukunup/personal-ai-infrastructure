import logging
import time
import threading
from nacos import NacosClient
from config import *

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

client = None
REQUEST_COUNT = 0


def register_service():
    global client
    server_addr = f"{NACOS_HOST}:{NACOS_PORT}"
    logger.info(f"Connecting to Nacos at: {server_addr}")

    client = NacosClient(
        server_addr,
        namespace=NACOS_NAMESPACE if NACOS_NAMESPACE else None,
        username=NACOS_USERNAME,
        password=NACOS_PASSWORD,
    )

    instance_id = f"{SERVICE_NAME}-{SERVICE_HOST}-{SERVICE_PORT}"
    success = client.add_naming_instance(
        SERVICE_NAME,
        ip=SERVICE_HOST,
        port=SERVICE_PORT,
        cluster_name="DEFAULT",
        weight=1.0,
        metadata=None,
        enable=True,
        healthy=True,
        ephemeral=True,
    )

    logger.info(f"Register service: {SERVICE_NAME}, success: {success}")
    return success


def heartbeat():
    global client
    if client:
        client.send_heartbeat(
            SERVICE_NAME,
            ip=SERVICE_HOST,
            port=SERVICE_PORT,
            cluster_name="DEFAULT",
            weight=1.0,
            metadata=None,
            ephemeral=True,
        )
        logger.info("Heartbeat sent")


def start_heartbeat(interval=10):
    def run():
        while True:
            time.sleep(interval)
            heartbeat()
    thread = threading.Thread(target=run, daemon=True)
    thread.start()
    logger.info(f"Heartbeat thread started (interval: {interval}s)")
    return thread


def create_app() -> FastAPI:
    from fastapi import FastAPI, Request
    from fastapi.responses import JSONResponse

    app = FastAPI(title="API Gateway Demo Service")

    @app.on_event("startup")
    async def startup():
        try:
            register_service()
            start_heartbeat(10)
        except Exception as e:
            logger.warning(f"Failed to register with Nacos: {e}. Continuing anyway...")

    @app.get("/")
    async def root():
        global REQUEST_COUNT
        REQUEST_COUNT += 1
        return {
            "service": SERVICE_NAME,
            "message": "Hello from FastAPI!",
            "request_count": REQUEST_COUNT,
            "timestamp": time.time()
        }

    @app.get("/health")
    async def health():
        return {"status": "healthy"}

    @app.get("/api/echo")
    async def echo(msg: str = "default"):
        return {
            "service": SERVICE_NAME,
            "echo": msg,
            "timestamp": time.time()
        }

    @app.post("/api/post")
    async def post_test(request: Request):
        body = await request.json()
        return {
            "service": SERVICE_NAME,
            "received": body,
            "timestamp": time.time()
        }

    return app


app = create_app()


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=SERVICE_PORT)
