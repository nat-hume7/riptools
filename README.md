# Riptools
Dead-simple commands that rip through bulk file operations on Windows. 

**Please install Poweshell 7 for these scripts to work. They will not work in standard Powershell 5.1**
https://learn.microsoft.com/en-us/powershell/scripting/install/install-powershell-on-windows?view=powershell-7.6

Dramatically faster than File Explorer, and still quite notably faster than `Remove-Item`, or standard multi-threaded `robocopy` for many operations. Particularly powerful for copy/delete operations involving many small loose files. 

<br>

## Commands
Parallel copy — scans the source tree, splits it into balanced jobs, and dispatches them across multiple concurrent robocopy processes.
```
ripcopy <source> <target>
ripcopy C:\projects\my-app D:\backup\my-app
```

Parallel delete - uses the robocopy `/MIR` empty-directory trick for multi-threaded deletion. Automatically identifies and offers to kill processes blocking locked files.
```
ripdel <path> [-Force]
ripdel C:\projects\old-build
ripdel C:\projects\old-build -Force   # kill lockers without prompting
```

### Tuning parameters

Both commands accept these optional parameters (defaults work well for most cases):

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-Parallel` | `12` | Concurrent robocopy processes |
| `-Threads` | `32` | Robocopy `/MT` threads per process |
| `-MaxDepth` | `8` | How deep to recurse when splitting large directories |
| `-Spread` | `3` | Job granularity — higher = more, smaller jobs |

<br>

## How it works
Fundamentally, this script uses two levels of parallelism to totally saturate the computer file I/O: 
- Level 1: Standard `Robocopy /MT`
- Level 2: Pwsh 7 `ForEach-Object -Parallel`

For a single operation, it scans the source tree, intelligently splits it into balanced jobs, then dispatches them across multiple concurrent `robocopy /MT` processes. 

This is composed into three steps for both tools: 
1. **Scan** - walk the tree down to `MaxDepth`, bulk-count below that
2. **Split** - break fat directories into right-sized jobs by file count
3. **Dispatch** - feed jobs heaviest-first into a `ForEach-Object -Parallel` work queue

`ripcopy` runs `robocopy /E /MT:32` per job. `ripdel` mirrors an empty directory over each subtree with `robocopy /MIR /MT:32`.

<br>

## Lock resolution (ripdel)

When files or directories can't be deleted, ripdel identifies the blocking processes using three methods:

| Method | What it finds | Speed |
|--------|--------------|-------|
| PEB CurrentDirectory scan | Processes cd'd into the directory | Instant |
| Restart Manager API | Processes with files open | Instant |
| handle.exe (Sysinternals) | Any remaining open handles | Slow (fallback) |

Without `-Force`, ripdel shows the lockers and asks before killing. With `-Force`, it kills all non-critical processes automatically. Critical system processes are never killed.

<br>

## Install

One-liner:
```powershell
irm https://raw.githubusercontent.com/nat-hume7/riptools/main/install.ps1 | iex
```

This downloads `ripcopy.ps1`, `ripdel.ps1`, and `handle.exe` to `~/.riptools/` and adds it to your PATH.

Or clone and add to PATH manually:

```powershell
git clone https://github.com/nat-hume7/riptools.git
# add the cloned directory to your PATH
```

<br>

## License

[MIT](LICENSE)
