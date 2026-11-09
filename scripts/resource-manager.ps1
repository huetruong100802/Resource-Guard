# CLI chung cho Claude/Codex/người dùng:
#   resource-manager.ps1 status | processes | disk scan | preflight <build|test|subagent|session>
#   resource-manager.ps1 serve [-Port 8765] [-Detach] [-NoOpen]   # UI realtime trên localhost; serve stop để dừng; serve setpin đặt PIN tự dọn
#   resource-manager.ps1 register -ProcessId N -Agent claude -Label "dotnet test"
#   resource-manager.ps1 cleanup plan | show PLAN_ID | approve PLAN_ID (-All | -ItemIds 1,2) | apply PLAN_ID [-DryRun]
# Thêm -Json để lấy đầu ra máy-đọc.
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Command = 'status',
    [Parameter(Position = 1)][string]$Sub = '',
    [Parameter(Position = 2)][string]$Arg = '',
    [int]$ProcessId = 0, [string]$Agent = 'unknown', [string]$Label = '', [int]$OwnerPid = 0,
    [int]$Top = 15, [int[]]$ItemIds, [switch]$All, [switch]$DryRun, [switch]$Json,
    [int]$Port = 8765, [switch]$Detach, [switch]$NoOpen, [switch]$NoToast
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'rg-common.ps1')

function Show($obj, [scriptblock]$Text) {
    if ($Json) { $obj | ConvertTo-Json -Depth 8 } else { & $Text }
}
function MB($b) { [math]::Round([double]$b / 1MB, 1) }

switch ($Command) {
    'status' {
        $b = Get-RgBudget -Task 'session'
        $snap = Get-RgSnapshot
        $out = [pscustomobject]@{ budget = $b; snapshot = $snap }
        Show $out {
            "State: $($b.state)  (RAM $($b.ramState), disk $($b.diskState), commit $($b.commitState))"
            "RAM free $($snap.availRamGB)/$($snap.totalRamGB) GB | commit $($snap.commitPct)% | CPU $($snap.cpuPct)% | disk $($snap.diskDrive): $($snap.diskFreeGB) GB free"
            "Heavy tasks running: $($b.heavyRunning)/$($b.maxHeavy)   Cleanup mode: $($b.cleanupMode)"
            foreach ($r in $b.reasons) { "  - $r" }
        }
    }
    'processes' {
        $table = Get-RgProcessTable
        $ledger = @(Read-RgLedger)
        $orph = @{}; foreach ($o in (Get-RgOrphanCandidates $table)) { $orph[[int]$o.Pid] = $true }
        $rows = $table | Sort-Object RamMB -Descending | Select-Object -First $Top | ForEach-Object {
            $p = $_
            [pscustomobject]@{
                Pid = $p.Pid; Parent = $p.ParentPid; Name = $p.Name; Group = $p.Group; RamMB = $p.RamMB
                Agent = [bool]@($ledger | Where-Object { $_.pid -eq $p.Pid -and $_.start -eq $p.Start }).Count
                OrphanCandidate = $orph.ContainsKey([int]$p.Pid)
            }
        }
        Show $rows { $rows | Format-Table -AutoSize | Out-String }
    }
    'disk' {
        $items = @(Get-RgCandidates)
        $rows = $items | Where-Object { $_.kind -ne 'process' } | Sort-Object { $_.sizeBytes } -Descending |
            Select-Object kind, action, @{ n = 'MB'; e = { MB $_.sizeBytes } }, path, reason
        Show $rows { $rows | Format-Table -AutoSize -Wrap | Out-String }
    }
    'preflight' {
        $task = if ($Sub) { $Sub } else { 'session' }
        $b = Get-RgBudget -Task $task
        Write-RgLog 'preflight' $b
        Show $b { "Task=$task decision=$($b.decision) state=$($b.state) heavy=$($b.heavyRunning)/$($b.maxHeavy)"; foreach ($r in $b.reasons) { "  - $r" } }
        if ($b.decision -eq 'deny') { exit 2 }
    }
    'register' {
        if (-not $ProcessId) { throw '-ProcessId is required.' }
        Register-RgProcess -ProcId $ProcessId -Agent $Agent -Label $Label -OwnerPid $OwnerPid | ConvertTo-Json -Depth 4
    }
    'cleanup' {
        switch ($Sub) {
            'plan' {
                $plan = New-RgPlan -Items @(Get-RgCandidates)
                Show $plan {
                    "Plan $($plan.planId): $(@($plan.items).Count) item(s), reclaimable ~$(MB $plan.totalReclaimableBytes) MB (status: $($plan.status))"
                    $plan.items | Select-Object id, level, kind, action, @{ n = 'MB'; e = { MB $_.sizeBytes } }, path, pid, name, reason | Format-Table -AutoSize -Wrap | Out-String
                    "Next: a human runs 'cleanup approve $($plan.planId) -All' (or -ItemIds ...) at an interactive console, then 'cleanup apply $($plan.planId)'."
                }
            }
            'show' { $plan = Read-RgPlan $Arg; Show $plan { $plan | ConvertTo-Json -Depth 8 } }
            'approve' { $p = Approve-RgPlan -PlanId $Arg -ItemIds $ItemIds -All:$All; Show $p { "Approved items: $(@($p.approval.approvedItemIds) -join ',')" } }
            'apply' {
                $r = Invoke-RgApply -PlanId $Arg -DryRun:$DryRun
                Show $r { "$($r.message); freed ~$(MB $r.freedBytes) MB"; $r.results | Format-Table -AutoSize -Wrap | Out-String }
                if ($r.code -ne 0) { exit $r.code }
                if (-not $r.ok) { exit 1 }
            }
            default { throw "Unknown cleanup subcommand '$Sub' (plan|show|approve|apply)." }
        }
    }
    'serve' {   # watcher + UI realtime http://localhost:<port>/ ; 'serve stop' để dừng bản chạy ngầm
        $srv = Join-Path $PSScriptRoot 'rg-server.ps1'
        if ($Sub -eq 'stop') { & $srv -Stop }
        elseif ($Sub -eq 'setpin') {   # PIN cho chế độ tự dọn 'on'; chỉ đặt được ở console tương tác, không qua UI/agent
            if ([Console]::IsInputRedirected -or -not [Environment]::UserInteractive) { throw 'Đặt PIN cần console tương tác.' }
            . (Join-Path $PSScriptRoot 'rg-policy.ps1')
            $a = Read-Host 'PIN mới (4-64 ký tự)' -AsSecureString
            $b = Read-Host 'Nhập lại PIN' -AsSecureString
            $pa = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($a))
            $pb = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($b))
            if ($pa -ne $pb) { throw 'Hai lần nhập không khớp.' }
            Set-RgPin $pa
            'Đã đặt PIN. Dùng nó khi bật/nới lỏng chế độ tự dọn "on" trên UI.'
        }
        else { & $srv -Port $Port -Detach:$Detach -NoOpen:$NoOpen -NoToast:$NoToast }
    }
    default { throw "Unknown command '$Command' (status|processes|disk|preflight|register|cleanup|serve)." }
}
