param (
    [string]$Port = "8188",
    [string]$Listen = "0.0.0.0",
    [string]$PythonVersion = "3.13",
    [switch]$EnableManager,
    [switch]$Offline,
    [switch]$Preview,
    [string[]]$ExtraArgs = @()
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir

# ─── Colors ──────────────────────────────────────────────────────────────
function Info   { param($m) Write-Host "==> $m" -ForegroundColor Cyan }
function Warn   { param($m) Write-Host "==> $m" -ForegroundColor Yellow }
function Ok     { param($m) Write-Host "==> $m" -ForegroundColor Green }
function Fail   { param($m) Write-Host "==> $m" -ForegroundColor Red; exit 1 }

# ─── 1. Ensure mise ──────────────────────────────────────────────────────
Info "Checking mise..."
if (-not (Get-Command mise -ErrorAction SilentlyContinue)) {
    Fail "mise not found. Install it: https://mise.jdx.dev/getting-started.html"
}
Info "Updating mise..."
mise self-update -y 2>$null
$MiseVer = (mise --version 2>&1) -split "`n" | Select-Object -First 1
Ok "mise: $MiseVer"

# ─── 2. Ensure Python via mise ───────────────────────────────────────────
Info "Ensuring Python $PythonVersion via mise..."
$installedPythons = (mise ls python 2>$null) | Out-String
if ($installedPythons -notmatch $PythonVersion) {
    Warn "Installing Python $PythonVersion with mise (one-time)..."
    mise install "python@$PythonVersion"
}
# Pin it for this directory
mise use "python@$PythonVersion"
$PythonExe = (mise which python 2>$null)
if (-not $PythonExe -or -not (Test-Path $PythonExe)) {
    Fail "Could not resolve python from mise. Run 'mise doctor' to debug."
}
$PyVer = & $PythonExe --version 2>&1
Ok "Python: $PyVer ($PythonExe)"

# ─── 3. Ensure uv via mise ───────────────────────────────────────────────
Info "Ensuring uv via mise..."
if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
    Warn "Installing uv with mise (one-time)..."
    mise use -g uv@latest
}
$UvVer = (uv --version 2>&1)
Ok "uv: $UvVer"

# ─── 4. Create or reuse venv ─────────────────────────────────────────────
$VenvDir = Join-Path $ScriptDir ".venv"
if (-not (Test-Path (Join-Path $VenvDir "pyvenv.cfg"))) {
    Info "Creating virtual environment with uv..."
    uv venv --python $PythonExe $VenvDir
    if ($LASTEXITCODE -ne 0) { Fail "Failed to create venv" }
    Ok "Created .venv"
} else {
    Ok "Reusing existing .venv"
}

# Activate (set PATH so uv/python resolve inside venv)
$VenvScripts = Join-Path $VenvDir "Scripts"
$env:VIRTUAL_ENV = $VenvDir
$env:PATH = "$VenvScripts;$env:PATH"
$VenvPython = Join-Path $VenvScripts "python.exe"

# ─── 5. Install / sync PyTorch (GPU auto-detect) ────────────────────────
Info "Checking PyTorch..."
$torchOk = $false
try {
    $cudaCheck = & $VenvPython -c "import torch; print(torch.cuda.is_available())" 2>$null
    if ($cudaCheck -match "True") {
        $torchOk = $true
        $torchVer = & $VenvPython -c "import torch; print(torch.__version__)" 2>$null
        Ok "PyTorch $torchVer already installed with CUDA"
    }
} catch {}

if (-not $torchOk) {
    Warn "Installing PyTorch with CUDA (cu130 for RTX 20-series+)..."
    uv pip install torch torchvision torchaudio --extra-index-url https://download.pytorch.org/whl/cu130
    if ($LASTEXITCODE -ne 0) { Fail "Failed to install PyTorch" }
    Ok "PyTorch installed"
}

# ─── 6. Install / sync requirements.txt ──────────────────────────────────
Info "Syncing dependencies from requirements.txt..."
uv pip install -r requirements.txt
if ($LASTEXITCODE -ne 0) { Fail "Failed to install requirements" }
Ok "Dependencies synced"

# ─── 7. Manager (optional) ───────────────────────────────────────────────
if ($EnableManager) {
    $mgrReq = Join-Path $ScriptDir "manager_requirements.txt"
    if (Test-Path $mgrReq) {
        Info "Installing ComfyUI-Manager dependencies..."
        uv pip install -r $mgrReq
    } else {
        Warn "manager_requirements.txt not found, skipping manager"
    }
}

# ─── 8. Build launch args ────────────────────────────────────────────────
$launchArgs = @("main.py", "--listen", $Listen, "--port", $Port)

if ($EnableManager) {
    $launchArgs += "--enable-manager"
}
if ($Offline) {
    $launchArgs += "--offline"
}
if ($Preview) {
    $launchArgs += @("--preview-method", "auto")
}
if ($ExtraArgs.Count -gt 0) {
    $launchArgs += $ExtraArgs
}

# ─── 9. Launch ───────────────────────────────────────────────────────────
Write-Host ""
Write-Host "══════════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host " ComfyUI starting on $Listen`:$Port"                       -ForegroundColor Green
Write-Host " URL:     http://$Listen`:$Port"                           -ForegroundColor White
Write-Host " Python:  $PyVer"
Write-Host " venv:    $VenvDir"
if ($EnableManager) {
    Write-Host " Manager: enabled"                                     -ForegroundColor Cyan
}
if ($Offline) {
    Write-Host " Mode:    offline"                                     -ForegroundColor Yellow
}
Write-Host "══════════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host ""

& $VenvPython @launchArgs
