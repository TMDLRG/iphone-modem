<#
  Installs what the iPhone side needs. Run as administrator (one prompt):

    powershell -ExecutionPolicy Bypass -File install-prereqs.ps1

  - iTunes (apple.com version)
  - Apple Mobile Device Support: the USB link to the iPhone, used by both
    Sideloadly and ModemBridge (winget's iTunes package does not include it)
  - iCloud (Legacy = the apple.com version), required by Sideloadly
  - Sideloadly, from sideloadly.io (not via winget: its winget entry is stale).
    The installer is not code-signed by its publisher. Pass -SideloadlyInstaller
    and -ExpectedSha256 to install a copy you have already checked.
#>
param(
    [string]$SideloadlyInstaller,
    [string]$ExpectedSha256
)

$log = Join-Path $env:TEMP 'modem-install-prereqs.log'
Start-Transcript -Path $log -Force | Out-Null

foreach ($id in 'Apple.iTunes', 'Apple.AppleMobileDeviceSupport', 'Apple.iCloud') {
    Write-Host ''
    Write-Host "=== $id ===" -ForegroundColor Cyan
    winget install --id $id -e --source winget --silent --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -eq 0) {
        Write-Host "$id installed." -ForegroundColor Green
    } elseif ($LASTEXITCODE -eq -1978335189) {
        Write-Host "$id is already installed and up to date." -ForegroundColor Green   # 0x8A15002B: no applicable upgrade
    } else {
        Write-Host "$id finished with exit code $LASTEXITCODE (see the winget output above)." -ForegroundColor Yellow
    }
}

# Sideloadly installs per user (under %LOCALAPPDATA%), not into Program Files.
function Find-Sideloadly {
    foreach ($dir in @((Join-Path $env:LOCALAPPDATA 'Sideloadly'), (Join-Path $env:ProgramFiles 'Sideloadly'))) {
        $candidate = Join-Path $dir 'sideloadly.exe'
        if (Test-Path $candidate) { return $candidate }
    }
    return $null
}

Write-Host ''
Write-Host '=== Sideloadly ===' -ForegroundColor Cyan
$sideloadlyExe = Find-Sideloadly
if ($sideloadlyExe) {
    Write-Host "Sideloadly is already installed ($sideloadlyExe)."
} else {
    if (-not $SideloadlyInstaller) {
        $SideloadlyInstaller = Join-Path $env:TEMP 'SideloadlySetup64.exe'
        Write-Host 'Downloading https://sideloadly.io/SideloadlySetup64.exe'
        Invoke-WebRequest -Uri 'https://sideloadly.io/SideloadlySetup64.exe' -OutFile $SideloadlyInstaller -UseBasicParsing
    }
    $hash = (Get-FileHash $SideloadlyInstaller -Algorithm SHA256).Hash
    Write-Host "Installer SHA-256: $hash"
    if ($ExpectedSha256 -and $hash -ne $ExpectedSha256.ToUpperInvariant()) {
        Write-Host 'Checksum does not match the expected value. Not installing Sideloadly.' -ForegroundColor Red
    } else {
        $process = Start-Process -FilePath $SideloadlyInstaller -ArgumentList '/S' -Wait -PassThru
        Write-Host "Sideloadly installer finished with exit code $($process.ExitCode)"
    }
}

Write-Host ''
$service = Get-Service -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like 'Apple Mobile Device*' -or $_.DisplayName -like 'Apple Mobile Device*' } |
    Select-Object -First 1
if ($service) {
    if ($service.Status -ne 'Running') { Start-Service $service.Name -ErrorAction SilentlyContinue }
    Write-Host "Apple Mobile Device Service: $((Get-Service $service.Name).Status)" -ForegroundColor Green
} else {
    Write-Host 'Apple Mobile Device Service was not found.' -ForegroundColor Yellow
}
$sideloadlyExe = Find-Sideloadly
if ($sideloadlyExe) {
    Write-Host "Sideloadly installed: $sideloadlyExe" -ForegroundColor Green
} else {
    Write-Host 'Sideloadly was not found after installation.' -ForegroundColor Yellow
}

Stop-Transcript | Out-Null
Write-Host ''
Write-Host 'All done. You can close this window.' -ForegroundColor Green
Read-Host 'Press Enter to close'
