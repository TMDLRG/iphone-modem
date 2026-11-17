<#
  Proves, with byte counters, that the PC's traffic goes through Modem and not
  through Personal Hotspot.

  Run it while Modem is connected in full mode. It downloads a test file
  (25 MB by default; that counts against your cellular data) the normal Windows
  way, and compares how many bytes crossed the Modem adapter with how many
  crossed the hotspot adapters (the iPhone's USB Ethernet, and Wi-Fi when it is
  joined to the hotspot). Nothing is changed.

    powershell -ExecutionPolicy Bypass -File prove-modem.ps1 [-Megabytes 25]
#>
param([int]$Megabytes = 25)

function Get-Counters([string[]]$Names) {
    $result = @{}
    foreach ($name in $Names) {
        $stats = Get-NetAdapterStatistics -Name $name -ErrorAction SilentlyContinue
        if ($stats) { $result[$name] = $stats }
    }
    $result
}

function Format-MB([double]$bytes) { '{0,10:N2} MB' -f ($bytes / 1MB) }

$modem = Get-NetAdapter -Name 'ModemTether' -ErrorAction SilentlyContinue
if (-not $modem) {
    Write-Host 'Modem is not connected in full mode. Start it with the Modem desktop icon first.' -ForegroundColor Yellow
    exit 1
}

# Hotspot paths: the iPhone's USB Ethernet, plus any adapter with a hotspot address (172.20.10.x).
$hotspot = @(Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -like 'Apple Mobile Device Ethernet*' } | ForEach-Object Name)
$hotspot += @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -like '172.20.10.*' } |
    ForEach-Object { (Get-NetAdapter -InterfaceIndex $_.InterfaceIndex).Name })
$hotspot = @($hotspot | Where-Object { $_ } | Select-Object -Unique)

Write-Host ''
Write-Host 'Where Windows sends internet traffic right now:' -ForegroundColor Cyan
foreach ($target in '1.1.1.1', '2606:4700:4700::1111') {
    $route = Find-NetRoute -RemoteIPAddress $target -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceAlias } | Select-Object -First 1
    $family = if ($target -like '*:*') { 'IPv6' } else { 'IPv4' }
    if ($route) { Write-Host ("  {0}: {1}" -f $family, $route.InterfaceAlias) } else { Write-Host "  ${family}: no route" }
}
if ($hotspot.Count -eq 0) {
    Write-Host '  Personal Hotspot: not connected to this PC (nothing can count as hotspot data).' -ForegroundColor Green
} else {
    Write-Host ('  Personal Hotspot is still connected via: ' + ($hotspot -join ', '))
}

$names = @('ModemTether') + $hotspot
$before = Get-Counters $names
Write-Host ''
Write-Host "Downloading $Megabytes MB through the normal Windows network path..." -ForegroundColor Cyan
$watch = [Diagnostics.Stopwatch]::StartNew()
& curl.exe -sS -o NUL --max-time 600 "https://speed.cloudflare.com/__down?bytes=$($Megabytes * 1000000)"
$ok = $LASTEXITCODE -eq 0
$watch.Stop()
Start-Sleep -Seconds 2
$after = Get-Counters $names

if (-not $ok) {
    Write-Host 'The download failed, so there is nothing to compare.' -ForegroundColor Red
    exit 1
}
Write-Host ('Done in {0:N1} s ({1:N1} MB/s).' -f $watch.Elapsed.TotalSeconds, ($Megabytes / [math]::Max($watch.Elapsed.TotalSeconds, 0.1)))
Write-Host ''
Write-Host 'Bytes that crossed each adapter during the download:' -ForegroundColor Cyan
$modemReceived = $null
$hotspotReceived = 0
foreach ($name in $names) {
    $role = if ($name -eq 'ModemTether') { 'Modem (phone app over USB)' } else { 'Personal Hotspot' }
    if ($before.ContainsKey($name) -and $after.ContainsKey($name)) {
        $rx = $after[$name].ReceivedBytes - $before[$name].ReceivedBytes
        $tx = $after[$name].SentBytes - $before[$name].SentBytes
        Write-Host ("  {0,-12} {1,-28} received {2}   sent {3}" -f $name, $role, (Format-MB $rx), (Format-MB $tx))
        if ($name -eq 'ModemTether') { $modemReceived = $rx } else { $hotspotReceived += $rx }
    } else {
        Write-Host ("  {0,-12} {1,-28} (no counters available)" -f $name, $role)
    }
}

$expected = $Megabytes * 1000000
Write-Host ''
if ($hotspot.Count -eq 0) {
    Write-Host "PASS: Personal Hotspot isn't connected, so none of this can count as hotspot data." -ForegroundColor Green
} elseif ($hotspotReceived -lt $expected * 0.02) {
    Write-Host ('PASS: the hotspot adapters carried {0:N2} MB of the {1} MB download (background noise only).' -f ($hotspotReceived / 1MB), $Megabytes) -ForegroundColor Green
} else {
    Write-Host ('FAIL: {0:N2} MB went over Personal Hotspot. Run "ModemBridge.exe --where" to see which traffic.' -f ($hotspotReceived / 1MB)) -ForegroundColor Red
}
if ($modemReceived -ne $null -and $modemReceived -lt $expected * 0.9) {
    Write-Host 'Note: the Modem adapter counted less than the download size; its counters may be incomplete.' -ForegroundColor Yellow
}
Write-Host ''
Write-Host 'Cross-check on the iPhone: Settings > Cellular, scroll to the app list.' -ForegroundColor Cyan
Write-Host '  "Modem" should have grown by about this download; "Personal Hotspot" should not have.'
