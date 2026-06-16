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

# ---- RESTART MANAGER P/INVOKE ------------------------------------------------
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public struct RM_UNIQUE_PROCESS {
    public int dwProcessId;
    public System.Runtime.InteropServices.ComTypes.FILETIME ProcessStartTime;
}

public enum RM_APP_TYPE { RmUnknownApp = 0, RmMainWindow = 1, RmOtherWindow = 2, RmService = 3, RmExplorer = 4, RmConsole = 5, RmCritical = 1000 }

[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public struct RM_PROCESS_INFO {
    public RM_UNIQUE_PROCESS Process;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string strAppName;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)]  public string strServiceShortName;
    public RM_APP_TYPE ApplicationType;
    public int AppStatus;
    public int TSSessionId;
    [MarshalAs(UnmanagedType.Bool)] public bool bRestartable;
}

public static class RestartManager {
    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)] public static extern int RmStartSession(out int pSessionHandle, int dwSessionFlags, string strSessionKey);
    [DllImport("rstrtmgr.dll")]                            public static extern int RmEndSession(int pSessionHandle);
    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)] public static extern int RmRegisterResources(int pSessionHandle, int nFiles, string[] rgsFileNames, int nApplications, RM_UNIQUE_PROCESS[] rgApplications, int nServices, string[] rgsServiceNames);
    [DllImport("rstrtmgr.dll")]                            public static extern int RmGetList(int pSessionHandle, out int pnProcInfoNeeded, ref int pnProcInfo, [In, Out] RM_PROCESS_INFO[] rgAffectedApps, out int lpdwRebootReasons);
}
'@ -ErrorAction SilentlyContinue

function Get-FileLockers([string[]]$filePaths) {
    $lockers = [System.Collections.Generic.List[object]]::new()
    for ($batch = 0; $batch -lt $filePaths.Length; $batch += 128) {
        $chunk = $filePaths[$batch..[math]::Min($batch + 127, $filePaths.Length - 1)]
        $handle = 0
        $key = [guid]::NewGuid().ToString()
        if ([RestartManager]::RmStartSession([ref]$handle, 0, $key) -ne 0) { continue }
        try {
            if ([RestartManager]::RmRegisterResources($handle, $chunk.Length, $chunk, 0, $null, 0, $null) -ne 0) { continue }
            $needed = 0; $count = 0; $reboot = 0
            [RestartManager]::RmGetList($handle, [ref]$needed, [ref]$count, $null, [ref]$reboot) | Out-Null
            if ($needed -eq 0) { continue }
            $count = $needed
            $procs = [RM_PROCESS_INFO[]]::new($count)
            if ([RestartManager]::RmGetList($handle, [ref]$needed, [ref]$count, $procs, [ref]$reboot) -ne 0) { continue }
            for ($i = 0; $i -lt $count; $i++) {
                $p = $procs[$i]
                $lockers.Add([pscustomobject]@{
                    PID         = $p.Process.dwProcessId
                    Name        = $p.strAppName
                    Type        = $p.ApplicationType
                    Restartable = $p.bRestartable
                    Critical    = ($p.ApplicationType -eq [RM_APP_TYPE]::RmCritical)
                })
            }
        } finally { [RestartManager]::RmEndSession($handle) | Out-Null }
    }
    $lockers | Sort-Object PID -Unique
}

# ---- SINGLE FILE FAST PATH ---------------------------------------------------
if (-not $item.PSIsContainer) {
    try { Remove-Item -LiteralPath $item.FullName -Force -ErrorAction Stop }
    catch {
        Write-Host ("  Cannot delete: {0}" -f $item.Name)
        $lockers = Get-FileLockers @($item.FullName)
        if ($lockers.Count -gt 0) {
            $killable = $lockers | Where-Object { -not $_.Critical }
            Write-Host "  Locked by:"
            foreach ($l in $lockers) {
                $tag = if ($l.Critical) { 'CRITICAL' } elseif ($l.Restartable) { 'restartable' } else { $l.Type }
                Write-Host ("    PID {0,-6} {1,-20} [{2}]" -f $l.PID, $l.Name, $tag)
            }
            $doKill = $Force -or ($(Read-Host "  Kill non-critical locker(s)? [y/N]") -match '^[yY]')
            if ($doKill -and $killable.Count -gt 0) {
                foreach ($l in $killable) { Stop-Process -Id $l.PID -Force -ErrorAction SilentlyContinue }
                Start-Sleep -Milliseconds 500
                Remove-Item -LiteralPath $item.FullName -Force -ErrorAction Stop
                Write-Host "Done."; exit 0
            }
        }
        Write-Error "Could not delete: $($item.FullName)"; exit 1
    }
    Write-Host "Done."; exit 0
}

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
Scan-Dir $target 0

$total = $recCount[$target] ?? 0
if ($total -eq 0) {
    Remove-Item -LiteralPath $target -Recurse -Force
    Write-Host "Removed (empty)."; exit 0
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
    foreach ($sd in $subdirs) {
        Add-Jobs $sd ($depth + 1) ($recCount[$sd] ?? 0)
    }
}
Add-Jobs $target 0 $total

# ---- 2. DISPATCH (FIRST PASS) ------------------------------------------------
$emptyDir = Join-Path ([System.IO.Path]::GetTempPath()) "ripdel-empty-$PID"
[void](New-Item -ItemType Directory -Path $emptyDir -Force)

try {
    Write-Host ("Deleting: {0}" -f $target)
    Write-Host ("Dispatching {0} job(s), {1} concurrent runners, {2} files total.`n" -f `
        $jobs.Count, $Parallel, $total)

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
    # Extract failed file paths from robocopy output (ERROR lines with sharing violations)
    $failedFiles = [System.Collections.Generic.List[string]]::new()
    foreach ($r in $results) {
        if ($r.Code -ge 8) {
            foreach ($line in $r.Output) {
                if ($line -match 'ERROR.*(?:Deleting|Copying)\s+(?:File|Dir)\s+(.+)$') {
                    $failedFiles.Add($Matches[1].Trim())
                }
            }
        }
    }

    if ($failedFiles.Count -gt 0) {
        # Only care about files that still actually exist on disk
        $stillExist = @($failedFiles | Where-Object { Test-Path -LiteralPath $_ })
        if ($stillExist.Count -eq 0) {
            Write-Host ("`n  {0} error(s) reported but all files already removed." -f $failedFiles.Count)
        } else {
            Write-Host ("`n  {0} file(s) could not be deleted (likely locked)." -f $stillExist.Count)

            $lockers = Get-FileLockers $stillExist
            if ($lockers.Count -gt 0) {
                $critical = $lockers | Where-Object Critical
                $killable = $lockers | Where-Object { -not $_.Critical }

                Write-Host "`n  Locking processes:"
                foreach ($l in $lockers) {
                    $tag = if ($l.Critical) { 'CRITICAL' } elseif ($l.Restartable) { 'restartable' } else { $l.Type }
                    Write-Host ("    PID {0,-6} {1,-20} [{2}]" -f $l.PID, $l.Name, $tag)
                }

                if ($critical.Count -gt 0) {
                    Write-Host ("`n  {0} CRITICAL process(es) cannot be killed." -f $critical.Count)
                }

                $doKill = $false
                if ($killable.Count -gt 0) {
                    if ($Force) {
                        $doKill = $true
                        Write-Host "`n  -Force: killing non-critical lockers..."
                    } else {
                        Write-Host ""
                        $answer = Read-Host "  Kill $($killable.Count) non-critical process(es) to continue? [y/N]"
                        $doKill = $answer -match '^[yY]'
                    }
                }

                if ($doKill) {
                    foreach ($l in $killable) {
                        try {
                            Stop-Process -Id $l.PID -Force -ErrorAction Stop
                            Write-Host ("    Killed: {0} (PID {1})" -f $l.Name, $l.PID)
                        } catch {
                            Write-Host ("    Could not kill: {0} (PID {1}) — {2}" -f $l.Name, $l.PID, $_.Exception.Message)
                        }
                    }
                    # Brief pause for handles to release
                    Start-Sleep -Milliseconds 500

                    # Retry: directly delete the previously-locked files
                    $retryFailed = 0
                    foreach ($f in $stillExist) {
                        try { Remove-Item -LiteralPath $f -Force -ErrorAction Stop }
                        catch { $retryFailed++; Write-Host ("    Still locked: {0}" -f $f) }
                    }
                    if ($retryFailed -eq 0) { Write-Host "  All locked files removed on retry." }
                    else { Write-Host ("  {0} file(s) still could not be removed." -f $retryFailed) }
                }
            } else {
                Write-Host "  Could not identify locking processes via Restart Manager."
            }
        }
    }

    # ---- 4. FINAL CLEANUP --------------------------------------------------------
    # Remove the now-gutted directory shell and any remaining empty dirs/stray files.
    Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue

    # ---- 5. REPORT ---------------------------------------------------------------
    $elapsed = $sw.Elapsed.TotalSeconds
    $stillExists = Test-Path -LiteralPath $target
    Write-Host ("`n{0:N1}s elapsed." -f $elapsed)
    if ($stillExists) { Write-Warning "Directory could not be fully removed (some files still locked)."; exit 1 }
    else              { Write-Host "Done."; exit 0 }

} finally {
    Remove-Item -LiteralPath $emptyDir -Force -ErrorAction SilentlyContinue
}
