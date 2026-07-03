import time
import uuid
import logging
import json
import contextvars
import asyncio
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
            "service": "payments",
            "request_id": request_id_var.get()
        }
        if record.exc_info:
            log_record["exception"] = self.formatException(record.exc_info)
        return json.dumps(log_record)

logger = logging.getLogger("payments")
logger.setLevel(logging.INFO)
handler = logging.StreamHandler()
handler.setFormatter(JSONFormatter())
logger.addHandler(handler)

# FastAPI App
app = FastAPI(title="Payments Service")

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

# In-memory fault state
fault_active = False

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
    return {"status": "ok", "service": "payments", "fault_active": fault_active}

@app.get("/metrics")
def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)

@app.post("/charge")
async def charge_payment(payload: dict):
    req_id = request_id_var.get()
    order_id = payload.get("order_id", "unknown")
    amount = payload.get("amount", 0.0)
    logger.info(f"Received charge request for order {order_id} with amount {amount}")
    
    if fault_active:
        logger.error(f"Fault active: deliberately failing charge for order {order_id}")
        await asyncio.sleep(2.0)
        return JSONResponse(
            status_code=500,
            content={"status": "error", "message": "Simulated payment processing failure", "order_id": order_id}
        )
    
    transaction_id = f"tx_{str(uuid.uuid4())[:8]}"
    logger.info(f"Successfully processed payment. Transaction ID: {transaction_id}")
    return {"status": "success", "transaction_id": transaction_id, "amount": amount}

@app.post("/fault")
async def toggle_fault(payload: dict):
    global fault_active
    active = payload.get("active", False)
    fault_active = active
    logger.warning(f"Fault injection state changed: fault_active={fault_active}")
    return {"status": "ok", "fault_active": fault_active}
