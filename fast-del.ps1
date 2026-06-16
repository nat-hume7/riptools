param(
    [Parameter(Mandatory)][string] $Dir
)
$e = "$env:TEMP\robocopy_empty"
New-Item $e -ItemType Directory -Force | Out-Null
robocopy $e $Dir /MIR /MT:32 /R:1 /W:1
Remove-Item $Dir -Force
Remove-Item $e -Force
