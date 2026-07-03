$ErrorActionPreference = "Stop"

Write-Host "=== Starting Multi-Service K8s DevOps Platform Bootstrap ===" -ForegroundColor Green

# Disable Docker BuildKit to avoid Buildx EOF pipe issues on Windows
$env:DOCKER_BUILDKIT = "0"

# 1. Ensure Docker is running
try {
    & docker info > $null
} catch {
    Write-Error "Docker is not running. Please start Docker Desktop and try again."
    exit 1
}

# 2. Compute immutable image tag from git SHA (Fix 2)
$GIT_SHA = (git rev-parse --short HEAD).Trim()
if (-not $GIT_SHA) {
    Write-Error "Failed to determine git SHA. Ensure you are inside a git repository."
    exit 1
}
$env:IMAGE_TAG = $GIT_SHA
Write-Host "Image tag: $GIT_SHA" -ForegroundColor Cyan

# 3. Manage Kind Cluster
$clusters = kind get clusters
if ($clusters -contains "kind-multi-node") {
    Write-Host "Cluster 'kind-multi-node' already exists. Recreating to ensure clean state..." -ForegroundColor Yellow
    kind delete cluster --name kind-multi-node
}

Write-Host "Creating kind cluster..." -ForegroundColor Cyan
kind create cluster --name kind-multi-node --config kind-config.yaml

# 4. Install Calico CNI (resolves CRD race issues in Helm)
Write-Host "Installing Calico CNI..." -ForegroundColor Cyan
& kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml

Write-Host "Pre-installing Prometheus ServiceMonitor CRD..." -ForegroundColor Cyan
& kubectl apply -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/main/example/prometheus-operator-crd/monitoring.coreos.com_servicemonitors.yaml

Write-Host "Waiting for Calico CNI to initialize..." -ForegroundColor Yellow
Start-Sleep -Seconds 15

# 5. Build Application Docker Images with immutable SHA tag (Fix 2)
Write-Host "Building Docker images with tag $GIT_SHA ..." -ForegroundColor Cyan
docker build -t "gateway:$GIT_SHA" ./app/gateway
docker build -t "orders:$GIT_SHA" ./app/orders
docker build -t "payments:$GIT_SHA" ./app/payments

# 6. Load Docker Images into Cluster
Write-Host "Loading Docker images into kind cluster..." -ForegroundColor Cyan
kind load docker-image "gateway:$GIT_SHA" --name kind-multi-node
kind load docker-image "orders:$GIT_SHA" --name kind-multi-node
kind load docker-image "payments:$GIT_SHA" --name kind-multi-node

# 7. Add and Update Helm Repositories
Write-Host "Configuring Helm repositories..." -ForegroundColor Cyan
& helm repo add projectcalico https://docs.tigera.io/calico/charts
& helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
& helm repo add grafana https://grafana.github.io/helm-charts
& helm repo update

# 8. Initialize and Apply Terraform (pass immutable image tag as variable)
Write-Host "Initializing Terraform..." -ForegroundColor Cyan
Push-Location terraform
try {
    terraform init
    Write-Host "Applying Terraform configuration with image tag $GIT_SHA ..." -ForegroundColor Cyan
    terraform apply -auto-approve -var="image_tag=$GIT_SHA"
} finally {
    Pop-Location
}

Write-Host "=== Bootstrap Completed Successfully ===" -ForegroundColor Green
