[CmdletBinding()]
param([int]$Top = 10)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'rg-common.ps1')

$snap = Get-RgSnapshot
$table = Get-RgProcessTable
$cfg = Get-RgConfig
$snap | Add-Member -NotePropertyName heavyRunning -NotePropertyValue @(Get-RgHeavyRoots $table $cfg).Count
$snap | Add-Member -NotePropertyName topProcesses -NotePropertyValue @(
    $table | Sort-Object RamMB -Descending | Select-Object -First $Top Pid, ParentPid, Name, Group, RamMB, Start)
$snap | ConvertTo-Json -Depth 5
