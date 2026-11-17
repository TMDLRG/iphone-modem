<#
  One-time setup for the Windows side of Modem. Safe to run again.

  - Downloads tun2socks and Wintun into .\tools and checks their SHA-256
    against the values pinned below.
  - Compiles ModemBridge.exe from ModemBridge.cs with the C# compiler that is
    built into Windows (no SDK needed).
  - Reports whether Apple Mobile Device Service (from iTunes) is installed.
#>
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$here  = Split-Path -Parent $MyInvocation.MyCommand.Path
$tools = Join-Path $here 'tools'
New-Item -ItemType Directory -Force $tools | Out-Null

$tun2socksVersion = 'v2.7.0'
$wintunVersion    = '0.14.1'
$wintunSha256     = '07c256185d6ee3652e09fa55c0b673e2624b565e02c4b9091c79ca7d2f24ef51'

$arch = $env:PROCESSOR_ARCHITECTURE
if ($env:PROCESSOR_ARCHITEW6432) { $arch = $env:PROCESSOR_ARCHITEW6432 }
switch ($arch) {
    'AMD64' {
        $tun2socksAsset  = 'tun2socks-windows-amd64'
        $tun2socksSha256 = 'c5d46e9452f6c9cc7c15ab9158d6d6a0169ceecd6bca019ce476b49337d2be43'
        $wintunArch      = 'amd64'
    }
    'ARM64' {
        $tun2socksAsset  = 'tun2socks-windows-arm64'
        $tun2socksSha256 = '74497771068da13f42921adfc540f2abb9ac822404582c8cbe34d30e8c0ea1f5'
        $wintunArch      = 'arm64'
    }
    default { throw "Unsupported Windows architecture: $arch" }
}

function Get-VerifiedDownload([string]$Url, [string]$Sha256, [string]$Destination) {
    Write-Host "Downloading $Url"
    Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing
    $actual = (Get-FileHash -Algorithm SHA256 $Destination).Hash.ToLowerInvariant()
    if ($actual -ne $Sha256) {
        Remove-Item $Destination -Force
        throw "Checksum mismatch for $Url (expected $Sha256, got $actual). Not installing it."
    }
}

$work = Join-Path ([IO.Path]::GetTempPath()) ('modem-setup-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $work | Out-Null
try {
    $tun2socksExe = Join-Path $tools 'tun2socks.exe'
    if (Test-Path $tun2socksExe) {
        Write-Host 'tun2socks is already installed.'
    } else {
        $zip = Join-Path $work "$tun2socksAsset.zip"
        Get-VerifiedDownload "https://github.com/xjasonlyu/tun2socks/releases/download/$tun2socksVersion/$tun2socksAsset.zip" $tun2socksSha256 $zip
        Expand-Archive $zip -DestinationPath (Join-Path $work 'tun2socks')
        Copy-Item (Join-Path $work "tun2socks\$tun2socksAsset.exe") $tun2socksExe
        Write-Host "Installed tun2socks $tun2socksVersion." -ForegroundColor Green
    }

    $wintunDll = Join-Path $tools 'wintun.dll'
    if (Test-Path $wintunDll) {
        Write-Host 'Wintun is already installed.'
    } else {
        $zip = Join-Path $work 'wintun.zip'
        Get-VerifiedDownload "https://www.wintun.net/builds/wintun-$wintunVersion.zip" $wintunSha256 $zip
        Expand-Archive $zip -DestinationPath (Join-Path $work 'wintun')
        Copy-Item (Join-Path $work "wintun\wintun\bin\$wintunArch\wintun.dll") $wintunDll
        Copy-Item (Join-Path $work 'wintun\wintun\LICENSE.txt') (Join-Path $tools 'wintun-LICENSE.txt')
        Write-Host "Installed Wintun $wintunVersion." -ForegroundColor Green
    }
} finally {
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}

$source = Join-Path $here 'ModemBridge.cs'
$exe    = Join-Path $here 'ModemBridge.exe'
if ((Test-Path $exe) -and (Get-Item $exe).LastWriteTime -ge (Get-Item $source).LastWriteTime) {
    Write-Host 'ModemBridge.exe is up to date.'
} else {
    $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (-not (Test-Path $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
    & $csc /nologo /optimize+ /target:exe /platform:anycpu "/out:$exe" /r:System.dll /r:System.Core.dll /r:System.Xml.dll $source
    if ($LASTEXITCODE -ne 0) { throw 'Compiling ModemBridge.cs failed.' }
    Write-Host 'Built ModemBridge.exe.' -ForegroundColor Green
}

$service = Get-Service -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like 'Apple Mobile Device*' -or $_.DisplayName -like 'Apple Mobile Device*' } |
    Select-Object -First 1
if ($service) {
    Write-Host "Apple Mobile Device Service is installed ($($service.Status))." -ForegroundColor Green
} else {
    Write-Host 'Apple Mobile Device Service is not installed yet. Install iTunes from apple.com; it provides the USB link to the iPhone.' -ForegroundColor Yellow
}
Write-Host 'Setup complete.' -ForegroundColor Green
