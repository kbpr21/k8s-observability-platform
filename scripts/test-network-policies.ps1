$ErrorActionPreference = "Continue"

Write-Host "=== Testing Kubernetes NetworkPolicies ===" -ForegroundColor Green

# Helper function to run connection test
function Test-Connection($sourceDeploy, $targetUrl, $shouldSucceed) {
    Write-Host "Testing connection from deploy/$sourceDeploy to $targetUrl ... " -NoNewline -ForegroundColor Cyan
    
    # Run python urllib connection test inside the pod
    $cmd = "python -c `"import urllib.request; urllib.request.urlopen('$targetUrl', timeout=3)`""
    
    # Find a pod name for the deployment
    $podName = (kubectl get pods -n app -l app=$sourceDeploy -o jsonpath='{.items[0].metadata.name}' 2>$null)
    if (-not $podName) {
        Write-Host "FAILED (No pods found for deploy/$sourceDeploy)" -ForegroundColor Red
        return $false
    }
    
    # Execute the command directly in python using array arguments to prevent quote stripping
    $pythonCode = "import urllib.request; urllib.request.urlopen('$targetUrl', timeout=3)"
    $argsList = @("exec", "-n", "app", $podName, "-c", $sourceDeploy, "--", "python", "-c", $pythonCode)
    $result = & kubectl $argsList 2>&1
    $exitCode = $LASTEXITCODE
    
    if ($exitCode -eq 0) {
        if ($shouldSucceed) {
            Write-Host "SUCCESS (Connected as expected)" -ForegroundColor Green
            return $true
        } else {
            Write-Host "FAILED (Connected, but should have been blocked!)" -ForegroundColor Red
            return $false
        }
    } else {
        if ($shouldSucceed) {
            Write-Host "FAILED (Could not connect, but should have!)" -ForegroundColor Red
            Write-Host "Command output: $result" -ForegroundColor Red
            return $false
        } else {
            Write-Host "SUCCESS (Blocked by NetworkPolicy as expected)" -ForegroundColor Green
            return $true
        }
    }
}

# Wait for deployments to be ready
Write-Host "Waiting for deployments to be ready..." -ForegroundColor Yellow
kubectl rollout status deployment/gateway -n app --timeout=60s
kubectl rollout status deployment/orders -n app --timeout=60s
kubectl rollout status deployment/payments -n app --timeout=60s

$allPassed = $true

# Test 1: Gateway calling Orders (Should succeed)
if (-not (Test-Connection "gateway" "http://orders:8000/health" $true)) { $allPassed = $false }

# Test 2: Orders calling Payments (Should succeed)
if (-not (Test-Connection "orders" "http://payments:8000/health" $true)) { $allPassed = $false }

# Test 3: Gateway calling Payments directly (Should fail/be blocked)
if (-not (Test-Connection "gateway" "http://payments:8000/health" $false)) { $allPassed = $false }

if ($allPassed) {
    Write-Host "`n=== All NetworkPolicy Tests Passed Successfully! ===" -ForegroundColor Green
    exit 0
} else {
    Write-Host "`n=== Some NetworkPolicy Tests Failed! ===" -ForegroundColor Red
    exit 1
}
