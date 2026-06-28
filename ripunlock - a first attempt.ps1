param(
    [Parameter(Mandatory)][string] $Path,
    [switch] $Force   # kill non-critical lockers without prompting
)
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/_riptools-unlock.ps1"

$item = Get-Item -LiteralPath $Path
$target = $item.FullName.TrimEnd('\')

Write-Host "Scanning for lockers on: $target"

# Enumerate file paths for Restart Manager (Tier 2)
if ($item.PSIsContainer) {
    $filePaths = @(Get-ChildItem -LiteralPath $target -Recurse -File -Force -ErrorAction SilentlyContinue |
                   Select-Object -ExpandProperty FullName)
} else {
    $filePaths = @($item.FullName)
}

$lockers = Get-Lockers $target -filePaths $filePaths

if ($lockers.Count -eq 0) {
    Write-Host "No lockers found."
    exit 0
}

Write-Host ("Found {0} locking process(es)." -f $lockers.Count)
$killed = Invoke-Kill $lockers -Force:$Force

if ($killed) {
    Write-Host "`nDone. Locks cleared."
    exit 0
} else {
    Write-Host "`nNo locks were cleared."
    exit 1
}
