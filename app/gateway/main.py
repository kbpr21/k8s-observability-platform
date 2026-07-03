import time
import uuid
import logging
import json
import contextvars
import httpx
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
            "service": "gateway",
            "request_id": request_id_var.get()
        }
        if record.exc_info:
            log_record["exception"] = self.formatException(record.exc_info)
        return json.dumps(log_record)

logger = logging.getLogger("gateway")
logger.setLevel(logging.INFO)
handler = logging.StreamHandler()
handler.setFormatter(JSONFormatter())
logger.addHandler(handler)

# FastAPI App
app = FastAPI(title="Gateway Service")

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

# HTTP Client for calling orders service
ORDERS_SERVICE_URL = "http://orders.app.svc.cluster.local:8000/order"
client = httpx.AsyncClient(timeout=10.0)

# Middleware for Request ID & Metrics tracking
@app.middleware("http")
async def context_and_metrics_middleware(request: Request, call_next):
    # Extract or generate Request ID
    req_id = request.headers.get("X-Request-ID")
    if not req_id:
        req_id = str(uuid.uuid4())
    
    token = request_id_var.set(req_id)
    
    method = request.method
    endpoint = request.url.path
    
    # Exclude /metrics and /health from request tracing metrics if desired, but keep them for general traffic
    start_time = time.time()
    
    try:
        logger.info(f"Incoming request: {method} {endpoint}")
        response = await call_next(request)
        duration = time.time() - start_time
        
        # Inject X-Request-ID into response headers
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
    return {"status": "ok", "service": "gateway"}

@app.get("/metrics")
def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)

@app.get("/")
async def read_root():
    return {"message": "Welcome to the Gateway Service", "request_id": request_id_var.get()}

@app.get("/order")
async def create_order():
    req_id = request_id_var.get()
    logger.info(f"Gateway forwarding order request to orders service at {ORDERS_SERVICE_URL}")
    
    headers = {"X-Request-ID": req_id}
    
    try:
        response = await client.post(ORDERS_SERVICE_URL, headers=headers, json={"item": "premium_membership"})
        logger.info(f"Received response from orders service: Status {response.status_code}")
        return JSONResponse(status_code=response.status_code, content=response.json())
    except httpx.HTTPError as exc:
        logger.error(f"HTTP error occurred while calling orders service: {str(exc)}")
        return JSONResponse(
            status_code=502,
            content={"detail": f"Failed to contact orders service: {str(exc)}", "request_id": req_id}
        )
