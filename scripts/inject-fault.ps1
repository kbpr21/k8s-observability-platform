param(
    [switch]$Recover
)

$active = $true
if ($Recover) {
    $active = $false
}

$statusStr = if ($active) { "injecting" } else { "recovering" }
Write-Host "=== Toggling Fault State on Payments Service ($statusStr) ===" -ForegroundColor Yellow

$podName = (kubectl get pods -n app -l app=payments -o jsonpath='{.items[0].metadata.name}' 2>$null)
if (-not $podName) {
    Write-Error "No payments pods found in namespace 'app'."
    exit 1
}

$activeJson = if ($active) { "True" } else { "False" }
$pythonCode = "import urllib.request, json; req = urllib.request.Request('http://localhost:8000/fault', data=json.dumps({'active': $activeJson}).encode(), headers={'Content-Type': 'application/json'}); print(urllib.request.urlopen(req).read().decode())"
$argsList = @("exec", "-n", "app", $podName, "-c", "payments", "--", "python", "-c", $pythonCode)
$result = & kubectl $argsList 2>&1

Write-Host "Response from service: $result" -ForegroundColor Green
Write-Host "Fault configuration updated." -ForegroundColor Green
