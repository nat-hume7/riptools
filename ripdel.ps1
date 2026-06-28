param(
    [Parameter(Mandatory)][string] $Path,
    [switch] $Force,            # kill non-critical lockers without prompting
    [int] $Parallel = 12,       # concurrent robocopy /MIR processes
    [int] $Threads  = 32,      # robocopy /MT per process
    [int] $MaxDepth = 8,       # max depth to recurse when splitting fat directories
    [int] $Spread   = 3        # job granularity multiplier; higher = more/smaller jobs
)
$ErrorActionPreference = 'Stop'

$item = Get-Item -LiteralPath $Path

# =
# ==
# ===
# ======
# ==========
# ================
# ========================
# ========================================
# =================================================================
# ============================================================================================
# DIRECTORY DELETION
# ============================================================================================
$target = $item.FullName.TrimEnd('\')

# ---- SINGLE FILE FAST PATH ---------------------------------------------------
if (-not $item.PSIsContainer) {
    try { Remove-Item -LiteralPath $item.FullName -Force -ErrorAction Stop }
    catch {
        Write-Host ("  Cannot delete: {0}" -f $item.Name)
        & "$PSScriptRoot/ripunlock.ps1" $item.FullName -Force:$Force
        Remove-Item -LiteralPath $item.FullName -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $item.FullName) { Write-Error "Could not delete: $($item.FullName)"; exit 1 }
    }
    Write-Host "Done."; exit 0
}

# ===
# =======
# =========================
# ============================================================================================
# ---- 0. SCAN -----------------------------------------------------------------
# Walk the target tree down to $MaxDepth building per-directory file counts.
# At MaxDepth, bulk-count via .NET enumeration (no per-file PowerShell overhead).
$recCount    = @{}   # dir -> recursive file count
$directCount = @{}   # dir -> files directly in dir
$children    = @{}   # dir -> set of immediate child dirs containing files
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

$total = $recCount[$target] ?? 0

# ===
# =======
# =========================
# ============================================================================================
# ---- 1. SPLIT ----------------------------------------------------------------
# Break fat directories into subtree jobs. Unlike ripcpy, we only emit subtree
# Emit subtree jobs AND files-only jobs at split nodes.
# Files-only jobs use robocopy without /MIR to delete only top-level files,
# leaving child directories for their own subtree jobs.
$shareTarget = [math]::Max(1, [math]::Ceiling($total / ($Parallel * $Spread)))
$jobs = [System.Collections.Generic.List[object]]::new()

function Add-Jobs([string]$dir, [int]$depth, [int]$weight) {
    $subdirs = if ($children.ContainsKey($dir)) { @($children[$dir]) } else { @() }
    if ($weight -le $shareTarget -or $depth -ge $MaxDepth -or $subdirs.Count -eq 0) {
        $jobs.Add([pscustomobject]@{ Dir = $dir; Weight = $weight; FilesOnly = $false })
        return
    }
    $direct = $directCount[$dir] ?? 0
    if ($direct -gt 0) {
        $jobs.Add([pscustomobject]@{ Dir = $dir; Weight = $direct; FilesOnly = $true })
    }
    foreach ($sd in $subdirs) { Add-Jobs $sd ($depth + 1) ($recCount[$sd] ?? 0) }
}
Add-Jobs $target 0 $total

# ===
# =======
# =========================
# ============================================================================================
# ---- 2. DISPATCH -------------------------------------------------------------
$emptyDir = Join-Path ([System.IO.Path]::GetTempPath()) "ripdel-empty-$PID"
[void](New-Item -ItemType Directory -Path $emptyDir -Force)

try {
    $pathPrefix = $target
    $maxRelLen = ($jobs | ForEach-Object {
        if ($_.Dir.Length -gt $pathPrefix.Length) { $_.Dir.Length - $pathPrefix.Length - 1 } else { 1 }
    } | Measure-Object -Maximum).Maximum
    $colW = [math]::Max($maxRelLen, 4)

    Write-Host ("Deleting: {0}" -f $target)
    Write-Host ("Dispatching {0} job(s), {1} concurrent runners, {2} files total." -f $jobs.Count, $Parallel, $total)
    $hdr = ('Total','Copied','Skipped','Mismatch','FAILED','Extras' | ForEach-Object { $_.PadLeft(9) }) -join ''
    Write-Host ("        {0,-$colW}  {1}" -f 'Path', $hdr)
    Write-Host ""
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    $results = $jobs | Sort-Object Weight -Descending | ForEach-Object -Parallel {
        $threads  = $using:Threads
        $emptyDir = $using:emptyDir
        $pfx      = $using:pathPrefix
        $cw       = $using:colW
        $jobSw = [System.Diagnostics.Stopwatch]::StartNew()
        if ($_.FilesOnly) {
            # Delete only top-level files, leave subdirs for their own jobs
            $out = robocopy $emptyDir $_.Dir /MT:$threads /R:1 /W:1
        } else {
            # Full recursive mirror — deletes everything in this subtree
            $out = robocopy $emptyDir $_.Dir /MIR /MT:$threads /R:1 /W:1
        }
        $code = $LASTEXITCODE
        $jobSw.Stop()
        $filesLine = ($out | Where-Object { $_ -match '^\s*Files :\s+\d' } | Select-Object -Last 1)
        $rel = if ($_.Dir.Length -gt $pfx.Length) { $_.Dir.Substring($pfx.Length + 1) } else { '.' }
        $status = if ($code -ge 8) { 'FAIL' } else { 'ok' }
        if ($filesLine -match '^\s*Files :\s+(.+)$') {
            $nums = ($Matches[1].Trim() -split '\s+' | ForEach-Object { $_.PadLeft(9) }) -join ''
        } else { $nums = "$($_.Weight) files" }
        Write-Host ("  [{0}] {1,-$cw}  {2}  ({3:N1}s)" -f $status, $rel, $nums, $jobSw.Elapsed.TotalSeconds)
        [pscustomobject]@{ Dir = $_.Dir; Code = $code; Output = $out }
    } -ThrottleLimit $Parallel

    # ---- 3. CLEANUP & LOCK RESOLUTION -------------------------------------------
    # Single retry loop: attempt removal, identify blockers, kill, repeat.
    $maxRetries = 2
    for ($attempt = 0; $attempt -lt $maxRetries; $attempt++) {
        Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $target)) { break }

        # Something still blocking — call ripunlock to identify and kill lockers
        & "$PSScriptRoot/ripunlock.ps1" $target -Force:$Force
        if ($LASTEXITCODE -ne 0) { break }  # user declined or only critical lockers
    }

    # ---- 4. REPORT ---------------------------------------------------------------
    $elapsed = $sw.Elapsed.TotalSeconds
    Write-Host ("`n{0:N1}s elapsed." -f $elapsed)
    if (Test-Path -LiteralPath $target) { Write-Warning "Directory could not be fully removed."; exit 1 }
    else                                { Write-Host "Done."; exit 0 }

} finally {
    Remove-Item -LiteralPath $emptyDir -Force -ErrorAction SilentlyContinue
}
