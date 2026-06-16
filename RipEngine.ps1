# RipEngine.ps1 — Shared scan/split/dispatch engine for ripcpy and ripdel.
# Dot-source this, then call Invoke-RipEngine with your parameters.

function Invoke-RipEngine {
    param(
        [Parameter(Mandatory)][string] $ScanRoot,
        [Parameter(Mandatory)][ValidateSet('Copy','Delete')][string] $Mode,
        [string] $CopyTarget,     # Copy mode: destination base path
        [string] $DeleteEmptyDir, # Delete mode: path to empty dir for /MIR
        [int] $Parallel = 8,
        [int] $Threads  = 32,
        [int] $MaxDepth = 8,
        [int] $Spread   = 3
    )

    $scanRoot = (Get-Item -LiteralPath $ScanRoot).FullName.TrimEnd('\')

    # ---- 0. SCAN -------------------------------------------------------------
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
                    if (-not $children.ContainsKey($dir)) {
                        $children[$dir] = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                    }
                    [void]$children[$dir].Add($sd)
                }
            }
        } else {
            foreach ($sd in $subdirs) {
                Scan-Dir $sd ($depth + 1)
                $total += $recCount[$sd]
                if (($recCount[$sd] ?? 0) -gt 0) {
                    if (-not $children.ContainsKey($dir)) {
                        $children[$dir] = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                    }
                    [void]$children[$dir].Add($sd)
                }
            }
        }
        $recCount[$dir] = $total
    }
    Scan-Dir $scanRoot 0

    $total = $recCount[$scanRoot] ?? 0
    if ($total -eq 0) { return @{ Total = 0; Results = @(); Elapsed = 0 } }

    # ---- 1. SPLIT ------------------------------------------------------------
    $shareTarget = [math]::Max(1, [math]::Ceiling($total / ($Parallel * $Spread)))
    $jobs = [System.Collections.Generic.List[object]]::new()

    function Add-Jobs([string]$dir, [int]$depth, [int]$weight) {
        $subdirs = if ($children.ContainsKey($dir)) { @($children[$dir]) } else { @() }

        if ($weight -le $shareTarget -or $depth -ge $MaxDepth -or $subdirs.Count -eq 0) {
            $jobs.Add([pscustomobject]@{ Dir = $dir; Weight = $weight })
            return
        }
        # Loose files at split nodes: emit a files-only job (copy mode only).
        # In delete mode, stray files at split nodes are cleaned up by the caller after.
        $direct = $directCount[$dir] ?? 0
        if ($direct -gt 0 -and $Mode -eq 'Copy') {
            $jobs.Add([pscustomobject]@{ Dir = $dir; Weight = $direct; FilesOnly = $true })
        }
        foreach ($sd in $subdirs) {
            Add-Jobs $sd ($depth + 1) ($recCount[$sd] ?? 0)
        }
    }
    Add-Jobs $scanRoot 0 $total

    # ---- 2. DISPATCH ---------------------------------------------------------
    Write-Host ("Dispatching {0} job(s), {1} concurrent runners, {2} files total.`n" -f `
        $jobs.Count, $Parallel, $total)

    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    $results = $jobs | Sort-Object Weight -Descending | ForEach-Object -Parallel {
        $threads    = $using:Threads
        $mode       = $using:Mode
        $scanRoot   = $using:scanRoot
        $copyTarget = $using:CopyTarget
        $emptyDir   = $using:DeleteEmptyDir
        $jobSw = [System.Diagnostics.Stopwatch]::StartNew()

        if ($mode -eq 'Copy') {
            $rel = $_.Dir.Substring($scanRoot.Length).TrimStart('\')
            $dst = if ($rel) { Join-Path $copyTarget $rel } else { $copyTarget }
            if ($_.FilesOnly) { $out = robocopy $_.Dir $dst /MT:$threads /R:1 /W:1 }
            else              { $out = robocopy $_.Dir $dst /E /MT:$threads /R:1 /W:1 }
        } else {
            $out = robocopy $emptyDir $_.Dir /MIR /MT:$threads /R:1 /W:1
        }

        $code = $LASTEXITCODE
        $jobSw.Stop()
        $filesLine = ($out | Where-Object { $_ -match '^\s*Files :\s+\d' } | Select-Object -Last 1)
        $name   = Split-Path $_.Dir -Leaf
        $info   = if ($filesLine) { $filesLine.Trim() } else { "$($_.Weight) files" }
        $status = if ($code -ge 8) { 'FAIL' } else { 'ok' }
        Write-Host ("  [{0}] {1}  {2}  ({3:N1}s)" -f $status, $name, $info, $jobSw.Elapsed.TotalSeconds)
        [pscustomobject]@{ Dir = $_.Dir; Code = $code; Files = $filesLine; Output = $out }
    } -ThrottleLimit $Parallel

    $sw.Stop()
    $elapsed = $sw.Elapsed.TotalSeconds

    # Report failures
    foreach ($r in $results) {
        if ($r.Code -ge 8) {
            Write-Host ("`n  FAILED: {0}" -f (Split-Path $r.Dir -Leaf))
            $r.Output | ForEach-Object { Write-Host "    $_" }
        }
    }

    $worst = ($results | ForEach-Object Code | Measure-Object -Maximum).Maximum
    Write-Host ("`n{0:N1}s elapsed." -f $elapsed)

    return @{ Total = $total; Results = $results; Worst = $worst; Elapsed = $elapsed }
}
