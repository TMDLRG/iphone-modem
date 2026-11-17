<#
  Creates a "Modem" icon on your desktop that runs "Start Modem.cmd"
  (full mode: the whole PC through the iPhone's cellular data).

    powershell -ExecutionPolicy Bypass -File windows\create-shortcut.ps1

  Safe to run again. Delete the icon from the desktop to remove it.
#>
$repo    = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$target  = Join-Path $repo 'Start Modem.cmd'
$icon    = Join-Path $repo 'windows\Modem.ico'
$desktop = [Environment]::GetFolderPath('Desktop')

if (-not (Test-Path $target)) { throw "Start Modem.cmd not found at $target" }

$shell = New-Object -ComObject WScript.Shell
$link  = $shell.CreateShortcut((Join-Path $desktop 'Modem.lnk'))
$link.TargetPath       = $target
$link.WorkingDirectory = $repo
if (Test-Path $icon) { $link.IconLocation = "$icon,0" }
$link.Description = "Share the iPhone's cellular data with this PC over USB"
$link.WindowStyle = 1
$link.Save()
Write-Host "Created $(Join-Path $desktop 'Modem.lnk')"
