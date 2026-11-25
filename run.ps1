param (
    [string]$Port = "8188",
    [string]$Listen = "0.0.0.0",
    [string]$PythonVersion = "3.13",
    [string]$OutputDir = "E:\ComfyUI\output",
    [switch]$NoManager,
    [switch]$NoPreview,
    [switch]$Offline,
    [switch]$ForceSync,
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

# Runs native commands safely in Windows PowerShell 5.1 (stderr warnings won't abort under Stop).
function Invoke-Quiet {
    param([scriptblock]$Command)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & $Command 2>$null
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Invoke-Native {
    param([scriptblock]$Command)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & $Command
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Get-Sha256 {
    param([string]$Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        try {
            return ([BitConverter]::ToString($sha.ComputeHash($stream)) -replace '-', '')
        } finally { $stream.Dispose() }
    } finally { $sha.Dispose() }
}

# ─── 1. Ensure mise ──────────────────────────────────────────────────────
Info "Checking mise..."
if (-not (Get-Command mise -ErrorAction SilentlyContinue)) {
    Fail "mise not found. Install it: https://mise.jdx.dev/getting-started.html"
}
$MiseVer = (Invoke-Quiet { mise --version }) -split "`n" | Select-Object -First 1
Ok "mise: $MiseVer"

# ─── 2. Ensure Python via mise ───────────────────────────────────────────
Info "Ensuring Python $PythonVersion via mise..."
$installedPythons = (Invoke-Quiet { mise ls python }) | Out-String
if ($installedPythons -notmatch $PythonVersion) {
    Warn "Installing Python $PythonVersion with mise (one-time)..."
    mise install "python@$PythonVersion"
    if ($LASTEXITCODE -ne 0) { Fail "Failed to install Python $PythonVersion" }
}
# Pin it for this directory
Invoke-Quiet { mise use "python@$PythonVersion" } | Out-Null
$PythonExe = (Invoke-Quiet { mise which python } | Select-Object -First 1)
if (-not $PythonExe -or -not (Test-Path $PythonExe)) {
    Fail "Could not resolve python from mise. Run 'mise doctor' to debug."
}
$PyVer = (Invoke-Quiet { & $PythonExe --version }) -join " "
Ok "Python: $PyVer ($PythonExe)"

# ─── 3. Ensure uv via mise ───────────────────────────────────────────────
Info "Ensuring uv via mise..."
if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
    Warn "Installing uv with mise (one-time)..."
    mise use -g uv@latest
    if ($LASTEXITCODE -ne 0) { Fail "Failed to install uv" }
}
$UvVer = (Invoke-Quiet { uv --version }) -join " "
Ok "uv: $UvVer"
# ─── 4. Create or reuse venv ─────────────────────────────────────────────
$VenvDir = Join-Path $ScriptDir ".venv"
if (-not (Test-Path (Join-Path $VenvDir "pyvenv.cfg"))) {
    Info "Creating virtual environment with uv..."
    Invoke-Native { uv venv --python $PythonExe $VenvDir }
    if ($LASTEXITCODE -ne 0) { Fail "Failed to create venv" }
    Ok "Created .venv"
} else {
    Ok "Reusing existing .venv"
}

# Activate (set PATH so uv/python resolve inside venv)
$VenvScripts = Join-Path $VenvDir "Scripts"
$env:VIRTUAL_ENV = $VenvDir
$env:PATH = "$VenvScripts;$env:PATH"
$env:UV_LINK_MODE = "copy"
$VenvPython = Join-Path $VenvScripts "python.exe"

# ─── 5. Install / sync PyTorch (GPU auto-detect) ────────────────────────
Info "Checking PyTorch..."
$torchOk = $false
try {
    $cudaCheck = Invoke-Quiet { & $VenvPython -c "import torch; print(torch.cuda.is_available())" }
    if ($cudaCheck -match "True") {
        $torchOk = $true
        $torchVer = (Invoke-Quiet { & $VenvPython -c "import torch; print(torch.__version__)" }) -join ""
        Ok "PyTorch $torchVer already installed with CUDA"
    }
} catch {}

if (-not $torchOk) {
    Warn "Installing PyTorch with CUDA (cu130 for RTX 20-series+)..."
    Invoke-Native { uv pip install torch torchvision torchaudio --extra-index-url https://download.pytorch.org/whl/cu130 }
    if ($LASTEXITCODE -ne 0) { Fail "Failed to install PyTorch" }
    Ok "PyTorch installed"
}

# ─── 6. Install / sync dependencies (hash-cached) ───────────────────────
$enableManager = -not $NoManager
$enablePreview = -not $NoPreview
$mgrReq = Join-Path $ScriptDir "manager_requirements.txt"
$reqHashFile = Join-Path $VenvDir ".req_hash"

$hashInputs = @((Get-Sha256 (Join-Path $ScriptDir "requirements.txt")))
if ($enableManager -and (Test-Path $mgrReq)) {
    $hashInputs += (Get-Sha256 $mgrReq)
}
$expectedHash = ($hashInputs -join ":") + ":mgr=$enableManager"
$currentHash = if (Test-Path $reqHashFile) { (Get-Content $reqHashFile -Raw).Trim() } else { "" }

if ($ForceSync -or ($currentHash -ne $expectedHash)) {
    Info "Syncing dependencies from requirements.txt..."
    Invoke-Native { uv pip install -r requirements.txt }
    if ($LASTEXITCODE -ne 0) { Fail "Failed to install requirements" }
    if ($enableManager) {
        if (Test-Path $mgrReq) {
            Info "Installing ComfyUI-Manager dependencies..."
            Invoke-Native { uv pip install -r $mgrReq }
            if ($LASTEXITCODE -ne 0) { Fail "Failed to install manager requirements" }
        } else {
            Warn "manager_requirements.txt not found, skipping manager"
        }
    }
    Set-Content -Path $reqHashFile -Value $expectedHash -NoNewline
    Ok "Dependencies synced"
} else {
    Ok "Dependencies up to date (use -ForceSync to reinstall)"
}

# ─── 7. Build launch args ────────────────────────────────────────────────
if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}
$env:PYTORCH_CUDA_ALLOC_CONF = "expandable_segments:True"

$launchArgs = @("main.py", "--listen", $Listen, "--port", $Port, "--output-directory", $OutputDir)

if ($enableManager) {
    $launchArgs += "--enable-manager"
}
if ($Offline) {
    $launchArgs += "--offline"
}
if ($enablePreview) {
    $launchArgs += @("--preview-method", "auto")
}
if ($ExtraArgs.Count -gt 0) {
    $launchArgs += $ExtraArgs
}

$portNum = [int]$Port
$portBusy = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners() |
    Where-Object { $_.Port -eq $portNum } | Select-Object -First 1
if ($portBusy) {
    Fail "Port $Port is already in use (another ComfyUI instance may be running). Stop it first or pass -Port."
}

# ─── 8. Launch ───────────────────────────────────────────────────────────
Write-Host ""
Write-Host "══════════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host " ComfyUI starting on $Listen`:$Port"                       -ForegroundColor Green
Write-Host " URL:     http://$Listen`:$Port"                           -ForegroundColor White
Write-Host " Output:  $OutputDir"                                      -ForegroundColor White
Write-Host " Python:  $PyVer"
Write-Host " venv:    $VenvDir"
if ($enableManager) {
    Write-Host " Manager: enabled"                                     -ForegroundColor Cyan
}
if ($enablePreview) {
    Write-Host " Preview: auto"                                        -ForegroundColor Cyan
}
if ($Offline) {
    Write-Host " Mode:    offline"                                     -ForegroundColor Yellow
}
Write-Host "══════════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host ""

$ErrorActionPreference = "Continue"
& $VenvPython @launchArgs
