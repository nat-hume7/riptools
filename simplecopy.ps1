param(
    [Parameter(Mandatory)][string] $Source,
    [Parameter(Mandatory)][string] $Target
)
robocopy $Source $Target /E /MT:32 /R:1 /W:1

# Robocopy exit codes are bitmasks: 8=failures, 16=fatal
if ($LASTEXITCODE -band 16) { Write-Error "FATAL: robocopy could not run." }
elseif ($LASTEXITCODE -band 8) { Write-Warning "Some files FAILED to copy. Check output above." }
else { Write-Host "Done." }
