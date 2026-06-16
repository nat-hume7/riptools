param(
    [Parameter(Mandatory)][string] $Path,
    [switch] $Force,            # kill non-critical lockers without prompting
    [int] $Parallel = 8,       # concurrent robocopy /MIR processes
    [int] $Threads  = 32,      # robocopy /MT per process
    [int] $MaxDepth = 8,       # max depth to recurse when splitting fat directories
    [int] $Spread   = 3        # job granularity multiplier; higher = more/smaller jobs
)
$ErrorActionPreference = 'Stop'

$item = Get-Item -LiteralPath $Path

# ---- HANDLE.EXE RESOLUTION --------------------------------------------------
$handleExe = Join-Path $PSScriptRoot 'handle.exe'
if (-not (Test-Path $handleExe)) {
    $handleExe = (Get-Command handle.exe -ErrorAction SilentlyContinue)?.Source
    if (-not $handleExe) { $handleExe = (Get-Command handle64.exe -ErrorAction SilentlyContinue)?.Source }
}
if (-not $handleExe) {
    Write-Warning "handle.exe not found. Run install.ps1 or download from https://live.sysinternals.com/handle64.exe"
    Write-Warning "Locked-file identification will be unavailable."
}

# ---- FIND LOCKERS (via handle.exe) ------------------------------------------
function Get-Lockers([string]$targetPath) {
    if (-not $handleExe) { return @() }
    $out = & $handleExe -a -u -accepteula $targetPath 2>&1 | Where-Object { $_ -is [string] }
    # Output format: "processname pid: PID type (access): handle: path"
    # Example: "Code.exe           pid: 12340  type: File  7C4: C:\git\..."
    $lockers = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($line in $out) {
        if ($line -match '^(.+?)\s+pid:\s*(\d+)\s+type:\s*(\w+)') {
            $pid = [int]$Matches[2]
            if ($pid -eq $PID -or $seen.Contains($pid)) { continue }
            [void]$seen.Add($pid)
            $procName = $Matches[1].Trim()
            $lockers.Add([pscustomobject]@{
                PID      = $pid
                Name     = $procName
                Critical = ($procName -in @('System','csrss','smss','wininit','services','lsass'))
            })
        }
    }
    $lockers
}

# ---- KILL & RETRY HELPER ----------------------------------------------------
function Invoke-KillAndRetry([object[]]$lockers, [scriptblock]$retryAction) {
    $critical = @($lockers | Where-Object Critical)
    $killable = @($lockers | Where-Object { -not $_.Critical })

    Write-Host "`n  Locking processes:"
    foreach ($l in $lockers) {
        $tag = if ($l.Critical) { 'CRITICAL' } else { $l.Name }
        Write-Host ("    PID {0,-6} {1,-20} [{2}]" -f $l.PID, $l.Name, $tag)
    }
    if ($critical.Count -gt 0) {
        Write-Host ("`n  {0} CRITICAL process(es) cannot be killed." -f $critical.Count)
    }
    if ($killable.Count -eq 0) { return $false }

    $doKill = $false
    if ($Force) {
        $doKill = $true
        Write-Host "`n  -Force: killing non-critical lockers..."
    } else {
        $answer = Read-Host "`n  Kill $($killable.Count) non-critical process(es) to continue? [y/N]"
        $doKill = $answer -match '^[yY]'
    }
    if (-not $doKill) { return $false }

    foreach ($l in $killable) {
        try {
            Stop-Process -Id $l.PID -Force -ErrorAction Stop
            Write-Host ("    Killed: {0} (PID {1})" -f $l.Name, $l.PID)
        } catch {
            Write-Host ("    Could not kill: {0} (PID {1}) — {2}" -f $l.Name, $l.PID, $_.Exception.Message)
        }
    }
    Start-Sleep -Milliseconds 500
    & $retryAction
    return $true
}

# ---- SINGLE FILE FAST PATH ---------------------------------------------------
if (-not $item.PSIsContainer) {
    try { Remove-Item -LiteralPath $item.FullName -Force -ErrorAction Stop }
    catch {
        Write-Host ("  Cannot delete: {0}" -f $item.Name)
        $lockers = Get-Lockers $item.FullName
        if ($lockers.Count -gt 0) {
            Invoke-KillAndRetry $lockers { Remove-Item -LiteralPath $item.FullName -Force -ErrorAction SilentlyContinue }
        }
        if (Test-Path -LiteralPath $item.FullName) { Write-Error "Could not delete: $($item.FullName)"; exit 1 }
    }
    Write-Host "Done."; exit 0
}

# ==============================================================================
# DIRECTORY DELETION
# ==============================================================================
$target = $item.FullName.TrimEnd('\')

# ---- 0. SCAN -----------------------------------------------------------------
$recCount    = @{}
$directCount = @{}
$children    = @{}
$bulkEnumOpts = [System.IO.EnumerationOptions]@{ RecurseSubdirectories = $true; IgnoreInaccessible = $true }

function Scan-Dir([string]$dir, [int]$depth) {
    try {
        $subdirs = [System.IO.Directory]::GetDirectories($dir)
        $files   = [System.IO.Directory]::GetFiles($dir).Length
    } catch [System.UnauthorizedAccessException] { return }
    $directCount[$dir] = $files
    $total = $files
    if ($depth -ge $MaxDepth -or $subdirs.Length -eq 0) {
        foreach ($sd in $subdirs) {
            $count = [System.Linq.Enumerable]::Count(
                [System.IO.Directory]::EnumerateFiles($sd, '*', $bulkEnumOpts))
            $recCount[$sd] = $count
            $total += $count
            if ($count -gt 0) {
                if (-not $children.ContainsKey($dir)) { $children[$dir] = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase) }
                [void]$children[$dir].Add($sd)
            }
        }
    } else {
        foreach ($sd in $subdirs) {
            Scan-Dir $sd ($depth + 1)
            $total += $recCount[$sd]
            if (($recCount[$sd] ?? 0) -gt 0) {
                if (-not $children.ContainsKey($dir)) { $children[$dir] = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase) }
                [void]$children[$dir].Add($sd)
            }
        }
    }
    $recCount[$dir] = $total
}
Scan-Dir $target 0

# ---- EMPTY DIRECTORY CASE ----------------------------------------------------
$total = $recCount[$target] ?? 0
if ($total -eq 0) {
    Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path -LiteralPath $target)) { Write-Host "Removed."; exit 0 }
    Write-Host "Directory locked — identifying lockers..."
    $lockers = Get-Lockers $target
    if ($lockers.Count -gt 0) {
        Invoke-KillAndRetry $lockers { Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue }
    }
    if (-not (Test-Path -LiteralPath $target)) { Write-Host "Removed."; exit 0 }
    Write-Warning "Could not remove (held open by another process): $target"; exit 1
}

# ---- 1. SPLIT ----------------------------------------------------------------
$shareTarget = [math]::Max(1, [math]::Ceiling($total / ($Parallel * $Spread)))
$jobs = [System.Collections.Generic.List[object]]::new()

function Add-Jobs([string]$dir, [int]$depth, [int]$weight) {
    $subdirs = if ($children.ContainsKey($dir)) { @($children[$dir]) } else { @() }
    if ($weight -le $shareTarget -or $depth -ge $MaxDepth -or $subdirs.Count -eq 0) {
        $jobs.Add([pscustomobject]@{ Dir = $dir; Weight = $weight })
        return
    }
    foreach ($sd in $subdirs) { Add-Jobs $sd ($depth + 1) ($recCount[$sd] ?? 0) }
}
Add-Jobs $target 0 $total

# ---- 2. DISPATCH -------------------------------------------------------------
$emptyDir = Join-Path ([System.IO.Path]::GetTempPath()) "ripdel-empty-$PID"
[void](New-Item -ItemType Directory -Path $emptyDir -Force)

try {
    Write-Host ("Deleting: {0}" -f $target)
    Write-Host ("Dispatching {0} job(s), {1} concurrent runners, {2} files total.`n" -f $jobs.Count, $Parallel, $total)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    $results = $jobs | Sort-Object Weight -Descending | ForEach-Object -Parallel {
        $threads  = $using:Threads
        $emptyDir = $using:emptyDir
        $jobSw = [System.Diagnostics.Stopwatch]::StartNew()
        $out = robocopy $emptyDir $_.Dir /MIR /MT:$threads /R:1 /W:1
        $code = $LASTEXITCODE
        $jobSw.Stop()
        $filesLine = ($out | Where-Object { $_ -match '^\s*Files :\s+\d' } | Select-Object -Last 1)
        $name = Split-Path $_.Dir -Leaf
        $info = if ($filesLine) { $filesLine.Trim() } else { "$($_.Weight) files" }
        $status = if ($code -ge 8) { 'FAIL' } else { 'ok' }
        Write-Host ("  [{0}] {1}  {2}  ({3:N1}s)" -f $status, $name, $info, $jobSw.Elapsed.TotalSeconds)
        [pscustomobject]@{ Dir = $_.Dir; Code = $code; Output = $out }
    } -ThrottleLimit $Parallel

    # ---- 3. HANDLE LOCKED FILES --------------------------------------------------
    $failedPaths = [System.Collections.Generic.List[string]]::new()
    foreach ($r in $results) {
        if ($r.Code -ge 8) {
            foreach ($line in $r.Output) {
                if ($line -match 'ERROR.*(?:Deleting|Copying)\s+(?:File|Dir)\s+(.+)$') {
                    $failedPaths.Add($Matches[1].Trim())
                }
            }
        }
    }

    if ($failedPaths.Count -gt 0) {
        $stillExist = @($failedPaths | Where-Object { Test-Path -LiteralPath $_ })
        if ($stillExist.Count -gt 0) {
            Write-Host ("`n  {0} path(s) could not be deleted." -f $stillExist.Count)
            $lockers = Get-Lockers $target
            if ($lockers.Count -gt 0) {
                Invoke-KillAndRetry $lockers {
                    foreach ($f in $stillExist) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
                }
            }
        }
    }

    # ---- 4. FINAL CLEANUP --------------------------------------------------------
    Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue

    # If still locked, one more attempt with handle.exe
    if (Test-Path -LiteralPath $target) {
        $lockers = Get-Lockers $target
        if ($lockers.Count -gt 0) {
            Invoke-KillAndRetry $lockers { Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    # ---- 5. REPORT ---------------------------------------------------------------
    $elapsed = $sw.Elapsed.TotalSeconds
    Write-Host ("`n{0:N1}s elapsed." -f $elapsed)
    if (Test-Path -LiteralPath $target) { Write-Warning "Directory could not be fully removed."; exit 1 }
    else                                { Write-Host "Done."; exit 0 }

} finally {
    Remove-Item -LiteralPath $emptyDir -Force -ErrorAction SilentlyContinue
}
