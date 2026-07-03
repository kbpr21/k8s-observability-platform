import time
import uuid
import logging
import json
import contextvars
import os
import httpx
import redis
from fastapi import FastAPI, Request, Response
from fastapi.responses import JSONResponse
from prometheus_client import Counter, Histogram, generate_latest, CONTENT_TYPE_LATEST

# Context variable to store Request ID for log propagation
request_id_var = contextvars.ContextVar("request_id", default="")

# Setup Structured JSON Logging
class JSONFormatter(logging.Formatter):
    def format(self, record):
        log_record = {
            "timestamp": self.formatTime(record, self.datefmt),
            "level": record.levelname,
            "message": record.getMessage(),
            "name": record.name,
            "service": "orders",
            "request_id": request_id_var.get()
        }
        if record.exc_info:
            log_record["exception"] = self.formatException(record.exc_info)
        return json.dumps(log_record)

logger = logging.getLogger("orders")
logger.setLevel(logging.INFO)
handler = logging.StreamHandler()
handler.setFormatter(JSONFormatter())
logger.addHandler(handler)

# FastAPI App
app = FastAPI(title="Orders Service")

# Prometheus Metrics
HTTP_REQUESTS_TOTAL = Counter(
    "http_requests_total",
    "Total HTTP requests",
    ["method", "endpoint", "status"]
)
HTTP_REQUEST_DURATION = Histogram(
    "http_request_duration_seconds",
    "HTTP request duration in seconds",
    ["method", "endpoint"]
)

# Configuration from env vars
PAYMENTS_SERVICE_URL = os.getenv("PAYMENTS_SERVICE_URL", "http://payments.app.svc.cluster.local:8000/charge")
# Use APP_REDIS_HOST/APP_REDIS_PORT to avoid collision with Kubernetes auto-injected
# REDIS_HOST / REDIS_PORT env vars (which contain a tcp:// URL, not a bare hostname/port).
REDIS_HOST = os.getenv("APP_REDIS_HOST", "redis.app.svc.cluster.local")

_raw_redis_port = os.getenv("APP_REDIS_PORT", "6379")
try:
    REDIS_PORT = int(_raw_redis_port)
except ValueError:
    raise ValueError(
        f"APP_REDIS_PORT must be a plain integer (got: {_raw_redis_port!r}). "
        "Do not use the auto-injected REDIS_PORT variable."
    )


# Initialize Redis client
redis_client = None
try:
    redis_client = redis.Redis(host=REDIS_HOST, port=REDIS_PORT, db=0, socket_timeout=2.0, decode_responses=True)
    logger.info(f"Initialized Redis client for {REDIS_HOST}:{REDIS_PORT}")
except Exception as e:
    logger.error(f"Failed to initialize Redis client: {str(e)}")

# HTTP Client for calling payments service
client = httpx.AsyncClient(timeout=10.0)

# Middleware for Request ID & Metrics tracking
@app.middleware("http")
async def context_and_metrics_middleware(request: Request, call_next):
    req_id = request.headers.get("X-Request-ID")
    if not req_id:
        req_id = str(uuid.uuid4())
    
    token = request_id_var.set(req_id)
    
    method = request.method
    endpoint = request.url.path
    
    start_time = time.time()
    
    try:
        logger.info(f"Incoming request: {method} {endpoint}")
        response = await call_next(request)
        duration = time.time() - start_time
        
        response.headers["X-Request-ID"] = req_id
        status_code = str(response.status_code)
        HTTP_REQUESTS_TOTAL.labels(method=method, endpoint=endpoint, status=status_code).inc()
        HTTP_REQUEST_DURATION.labels(method=method, endpoint=endpoint).observe(duration)
        
        logger.info(f"Request completed: {method} {endpoint} - Status {status_code} in {duration:.4f}s")
        return response
    except Exception as e:
        duration = time.time() - start_time
        HTTP_REQUESTS_TOTAL.labels(method=method, endpoint=endpoint, status="500").inc()
        HTTP_REQUEST_DURATION.labels(method=method, endpoint=endpoint).observe(duration)
        logger.error(f"Request failed: {method} {endpoint} - Error: {str(e)}", exc_info=True)
        return JSONResponse(
            status_code=500,
            content={"detail": "Internal Server Error", "request_id": req_id}
        )
    finally:
        request_id_var.reset(token)

@app.get("/health")
async def health():
    # Simple check for Redis health
    redis_ok = False
    if redis_client:
        try:
            redis_client.ping()
            redis_ok = True
        except Exception:
            pass
    return {"status": "ok", "service": "orders", "redis_connected": redis_ok}

@app.get("/metrics")
def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)

@app.post("/order")
async def create_order(payload: dict):
    req_id = request_id_var.get()
    item = payload.get("item", "unknown")
    logger.info(f"Processing order for item: {item}")
    
    # 1. Write/Read to Redis backend
    order_id = str(uuid.uuid4())
    total_orders = 1
    if redis_client:
        try:
            total_orders = redis_client.incr("order_count")
            redis_client.set(f"order:{order_id}", json.dumps({"item": item, "timestamp": time.time()}))
            logger.info(f"Successfully recorded order {order_id} in Redis. Total orders: {total_orders}")
        except Exception as e:
            logger.error(f"Failed to communicate with Redis backend: {str(e)}")
            # Fail silently or proceed with fallback? We proceed with fallback in-memory count
            total_orders = -1
    else:
        logger.warning("Redis client is not available. Skipping state persistence.")
        total_orders = -1

    # 2. Call Payments service
    logger.info(f"Orders forwarding payment request to payments service at {PAYMENTS_SERVICE_URL}")
    headers = {"X-Request-ID": req_id}
    
    try:
        response = await client.post(
            PAYMENTS_SERVICE_URL,
            headers=headers,
            json={"order_id": order_id, "amount": 99.99}
        )
        logger.info(f"Received response from payments service: Status {response.status_code}")
        
        if response.status_code == 200:
            return {
                "status": "success",
                "order_id": order_id,
                "order_count": total_orders,
                "payment": response.json(),
                "request_id": req_id
            }
        else:
            return JSONResponse(
                status_code=response.status_code,
                content={
                    "status": "failed",
                    "detail": "Payment authorization failed",
                    "payment_response": response.json(),
                    "request_id": req_id
                }
            )
    except httpx.HTTPError as exc:
        logger.error(f"HTTP error occurred while calling payments service: {str(exc)}")
        return JSONResponse(
            status_code=502,
            content={"detail": f"Failed to contact payments service: {str(exc)}", "request_id": req_id}
        )
