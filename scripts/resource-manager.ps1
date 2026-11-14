# CLI chung cho Claude/Codex/người dùng:
#   resource-manager.ps1 status | processes | disk scan | preflight <build|test|subagent|session>
#   resource-manager.ps1 serve [-Port 8765] [-Detach] [-NoOpen]   # UI realtime trên localhost; serve stop để dừng; serve setpin đặt PIN tự dọn
#   resource-manager.ps1 register -ProcessId N -Agent claude -Label "dotnet test"
#   resource-manager.ps1 preflight <build|test|subagent|session> [-Reserve -SessionId S]   # có -Reserve: giữ chỗ cho tác vụ sắp chạy (mã thoát 2 = từ chối, 3 = hoãn)
#   resource-manager.ps1 lease list | acquire|heartbeat|release -SessionId S [-Token T]    # lease phiên cho agent không có hook
#   resource-manager.ps1 cleanup plan | show PLAN_ID | approve PLAN_ID (-All | -ItemIds 1,2) | apply PLAN_ID [-DryRun]
# Thêm -Json để lấy đầu ra máy-đọc.
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Command = 'status',
    [Parameter(Position = 1)][string]$Sub = '',
    [Parameter(Position = 2)][string]$Arg = '',
    [int]$ProcessId = 0, [string]$Agent = 'unknown', [string]$Label = '', [int]$OwnerPid = 0,
    [int]$Top = 15, [int[]]$ItemIds, [switch]$All, [switch]$DryRun, [switch]$Json,
    [int]$Port = 8765, [switch]$Detach, [switch]$NoOpen, [switch]$NoToast,
    [string]$SessionId = '', [string]$Token = '', [switch]$Reserve
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
        # -Reserve / -SessionId: preflight có giữ chỗ (hai agent đồng thời không cùng thấy một phần RAM trống); không có thì giữ cách cũ.
        $b = if ($Reserve -or $SessionId) { Invoke-RgPreflight -Task $task -SessionId $SessionId -Reserve:$Reserve } else { Get-RgBudget -Task $task }
        Write-RgLog 'preflight' $b
        Show $b { "Task=$task decision=$($b.decision) state=$($b.state)$(if ($b.PSObject.Properties['heavyRunning']) { " heavy=$($b.heavyRunning)/$($b.maxHeavy)" })$(if ($b.reservationId) { " reservation=$($b.reservationId)" })"; foreach ($r in $b.reasons) { "  - $r" }; if ($b.PSObject.Properties['warning'] -and $b.warning) { "  ! $($b.warning)" } }
        if ($b.decision -eq 'deny') { exit 2 }
        if ($b.decision -eq 'defer') { exit 3 }   # chưa nên chạy ngay: hỏi lại sau ít giây
    }
    'lease' {   # agent không có hook (Codex...) tự giữ lease: lease acquire|heartbeat|release|list  -SessionId S [-Token T] [-Agent codex] [-OwnerPid N]
        switch ($Sub) {
            'list' { $l = @(Get-RgLeases); Show $l { if ($l.Count) { $l | Format-Table sessionId, agent, token, ownerPid, subagents, reservations, lastSeenUtc -AutoSize | Out-String } else { 'Không có lease nào đang hiệu lực.' } } }
            'acquire' {
                if (-not $SessionId) { throw '-SessionId is required.' }
                $l = New-RgLease -SessionId $SessionId -Agent $Agent -OwnerPid $OwnerPid -Source 'cli'
                Show $l { "Lease cho $SessionId, token $($l.token). Giữ token này để heartbeat/release." }
            }
            'heartbeat' {
                if (-not $SessionId) { throw '-SessionId is required.' }
                $r = Update-RgLeaseHeartbeat -SessionId $SessionId -Token $(if ($Token) { [long]$Token } else { $null })
                Show $r { if ($r.ok) { "Heartbeat ok cho $SessionId." } else { "Không làm mới được: $($r.reason)." } }
                if (-not $r.ok) { exit 1 }
            }
            'release' {
                if (-not $SessionId) { throw '-SessionId is required.' }
                $r = Remove-RgLease -SessionId $SessionId -Token $(if ($Token) { [long]$Token } else { $null })
                Show $r { if ($r.ok) { "Đã trả lease $SessionId." } else { "Không trả được: $($r.reason)." } }
                if (-not $r.ok) { exit 1 }
            }
            default { throw "Unknown lease subcommand '$Sub' (list|acquire|heartbeat|release)." }
        }
    }
    'register' {
        if (-not $ProcessId) { throw '-ProcessId is required.' }
        Register-RgProcess -ProcId $ProcessId -Agent $Agent -Label $Label -OwnerPid $OwnerPid | ConvertTo-Json -Depth 4
    }
    'heartbeat' {   # agent còn sống làm mới hạn đăng ký của process đã register
        if (-not $ProcessId) { throw '-ProcessId is required.' }
        $ok = Update-RgLedgerHeartbeat -ProcId $ProcessId
        Show ([pscustomobject]@{ pid = $ProcessId; heartbeat = $ok }) { if ($ok) { "Heartbeat ok for pid $ProcessId." } else { "pid $ProcessId is not in the ledger." } }
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
            'resume' {   # liệt kê plan bị ngắt giữa chừng; 'cleanup resume PLAN_ID' chạy tiếp (revalidate từng mục, mục đã xoá bị bỏ qua)
                if (-not $Arg) { $rp = @(Get-RgResumablePlans); Show $rp { if ($rp.Count) { $rp | Format-Table -AutoSize | Out-String } else { 'Không có plan nào đang dở.' } } }
                else {
                    if (@(Get-RgResumablePlans | Where-Object { $_.planId -eq $Arg }).Count -eq 0) { throw "Plan $Arg is not in the interrupted ('applying') state." }
                    $r = Invoke-RgApply -PlanId $Arg
                    Show $r { "$($r.message); freed ~$(MB $r.freedBytes) MB"; $r.results | Format-Table -AutoSize -Wrap | Out-String }
                    if ($r.code -ne 0) { exit $r.code }
                    if (-not $r.ok) { exit 1 }
                }
            }
            'apply' {
                $r = Invoke-RgApply -PlanId $Arg -DryRun:$DryRun
                Show $r { "$($r.message); freed ~$(MB $r.freedBytes) MB"; $r.results | Format-Table -AutoSize -Wrap | Out-String }
                if ($r.code -ne 0) { exit $r.code }
                if (-not $r.ok) { exit 1 }
            }
            default { throw "Unknown cleanup subcommand '$Sub' (plan|show|approve|apply|resume)." }
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
    default { throw "Unknown command '$Command' (status|processes|disk|preflight|register|heartbeat|lease|cleanup|serve)." }
}
