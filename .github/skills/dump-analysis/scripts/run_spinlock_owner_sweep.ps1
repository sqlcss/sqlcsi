# run_spinlock_owner_sweep.ps1
# Conditional Gate C follow-up for Scheduler/non-yield incidents whose current and
# first-detected copied stacks both contain spinlock acquisition/backoff frames.
#
# The sweep:
#   1. Starts cdb.exe, loads mex.dll, and runs `!us -l -i Spinlock` against the
#      dump. Long mode prevents omitted thread IDs; -i includes OS TIDs.
#   2. Supports multiple matching threads, multiple acquire frames per thread,
#      multiple waiters per lock, and multiple distinct lock addresses.
#   3. Dynamically discovers each SpinToAcquire frame and extracts its `this` lock.
#   4. Decodes the raw lock qword, resolves the nominal owner OS TID to a debugger
#      thread, captures the owner stack, and classifies owner confidence.
#   5. For LogInfoIter/LOGLFM, validates CDbVLFTable -> LogInfoIter.m_logmgr ->
#      SQLServerLogMgr.m_lfmAccess address propagation and reports dynamic-type gaps.
#
# It never promotes m_threadId directly to "actual owner". Output distinguishes
# nominal payload owner, resolved OS thread, stack compatibility, and actual holder.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CaseId,
    [Parameter(Mandatory)][string]$Dump,
    [Parameter(Mandatory)][string]$AnalysisDir,
    [Parameter(Mandatory)][string]$MexPath,
    [string]$Findings = '',
    [string]$Ledger = '',
    [string]$Cdb,
    [string]$SymPath = 'srv*C:\Symbols*https://symweb.azurefd.net',
    [string]$OutJson = '',
    [string]$OutHtml = '',
    [int]$TimeoutSec = 1200,
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
if (-not $Findings) { $Findings = Join-Path $AnalysisDir "${CaseId}_non_yield_findings.json" }
if (-not $Ledger) { $Ledger = Join-Path $AnalysisDir "${CaseId}_route_execution_ledger.json" }
if (-not $OutJson) { $OutJson = Join-Path $AnalysisDir "${CaseId}_spinlock_owner_sweep.json" }
if (-not $OutHtml) { $OutHtml = Join-Path $AnalysisDir "${CaseId}_spinlock_owner_sweep.html" }
$overallScripts = Join-Path $PSScriptRoot '..\..\dump-overall\scripts'
$resolveCdb = Join-Path $overallScripts 'resolve_cdb.ps1'
$setCheck = Join-Path $PSScriptRoot 'set_route_execution_check.ps1'
foreach ($path in @($Dump,$AnalysisDir,$MexPath,$Findings,$resolveCdb,$setCheck)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "required path missing: $path" }
}
$mex = Join-Path $MexPath 'mex.dll'
if (-not (Test-Path -LiteralPath $mex -PathType Leaf)) { throw "mex.dll missing: $mex" }
. $resolveCdb
$Cdb = Resolve-CdbPath -Cdb $Cdb -Required

function Write-Utf8([string]$Path,[string]$Text) {
    [IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($false))
}
function Write-AtomicJson([string]$Path,$Object) {
    $temp = "$Path.tmp"
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
    Write-Utf8 $temp ($Object | ConvertTo-Json -Depth 40)
    [IO.File]::Move($temp,$Path,$true)
}
function Rel([string]$Path) { return [IO.Path]::GetRelativePath($AnalysisDir,$Path).Replace('\','/') }
function HE([string]$Value) { if ($null -eq $Value) { return '' }; return [Net.WebUtility]::HtmlEncode($Value) }
function Normalize-Hex([string]$Value) {
    if (-not $Value) { return $null }
    return (($Value -replace '^0x','' -replace '`','').ToLowerInvariant().TrimStart('0')).PadLeft(1,'0')
}
function Hex-U64([string]$Value) {
    $normalized = Normalize-Hex $Value
    if (-not $normalized) { return [uint64]0 }
    return [Convert]::ToUInt64($normalized,16)
}
function Hex-I32([string]$Value) { return [Convert]::ToInt32((Normalize-Hex $Value),16) }
function Hex-Text([uint64]$Value,[int]$Digits = 0) {
    $format = if ($Digits -gt 0) { 'x' + $Digits } else { 'x' }
    return '0x' + $Value.ToString($format)
}
function Get-Block([string]$Text,[string]$Start,[string]$End) {
    $s = $Text.IndexOf($Start,[StringComparison]::Ordinal)
    if ($s -lt 0) { return '' }
    $s += $Start.Length
    $e = $Text.IndexOf($End,$s,[StringComparison]::Ordinal)
    if ($e -lt 0) { $e = $Text.Length }
    return $Text.Substring($s,$e-$s).Trim()
}
function Stack-Functions([string]$Block) {
    return @([regex]::Matches($Block,'(?m)(?:^|\s)([A-Za-z0-9_.<>:$~]+![A-Za-z0-9_<>:$~?,]+)(?:\+0x[0-9a-f]+)?','IgnoreCase') |
        ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
}
function Invoke-Cdb([string]$Batch,[string]$Log,[int]$Timeout) {
    if (Test-Path -LiteralPath $Log) { Remove-Item -LiteralPath $Log -Force }
    $proc = Start-Process -FilePath $Cdb -ArgumentList @('-y',$SymPath,'-z',$Dump,'-cf',$Batch,'-logo',$Log,'-G','-lines') -PassThru -WindowStyle Hidden
    if (-not $proc.WaitForExit($Timeout * 1000)) {
        try { $proc.Kill() } catch {}
        throw "cdb timed out after ${Timeout}s: $Batch"
    }
    if ($proc.ExitCode -ne 0) { throw "cdb exit $($proc.ExitCode): $Batch" }
    if (-not (Test-Path -LiteralPath $Log -PathType Leaf) -or (Get-Item -LiteralPath $Log).Length -eq 0) {
        throw "cdb log missing/empty: $Log"
    }
}
function Ensure-SchedulerChecks {
    if (-not (Test-Path -LiteralPath $Ledger -PathType Leaf)) { return }
    $doc = Get-Content -LiteralPath $Ledger -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not ($doc.routes.PSObject.Properties.Name -contains 'scheduler_non_yield')) { return }
    $route = $doc.routes.scheduler_non_yield
    $changed = $false
    $specs = [ordered]@{
        spinlock_thread_inventory = [ordered]@{
            required=$false;status='pending';description='When current and copied stacks are both on spinlock paths, enumerate every dump thread and count all current call stacks containing Spinlock.'
            action='Run !us -l -i Spinlock directly under cdb/MEX; list every matching debugger/OS thread and stack; reconcile MEX group counts.';evidence=@();note=''
        }
        spinlock_owner_validation = [ordered]@{
            required=$false;status='pending';description='For every spinlock waiter, extract the lock address, decode nominal owner TID, resolve owner thread/stack, and validate owner confidence.'
            action='Discover SpinToAcquire frame; read this/lock qword; group waiters by lock; map m_threadId to OS/debugger thread; capture owner stack; validate LOGLFM parent address chain when applicable.';evidence=@();note=''
        }
    }
    foreach ($entry in $specs.GetEnumerator()) {
        if (-not ($route.checks.PSObject.Properties.Name -contains $entry.Key)) {
            $route.checks | Add-Member -NotePropertyName $entry.Key -NotePropertyValue ([pscustomobject]$entry.Value)
            $changed = $true
        } elseif ([bool]$route.checks.($entry.Key).required) {
            $route.checks.($entry.Key).required = $false
            $changed = $true
        }
    }
    if ($changed) { Write-AtomicJson $Ledger $doc }
}
function Set-RouteCheck([string]$Name,[string]$Status,[string[]]$Evidence,[string]$Note) {
    if (-not (Test-Path -LiteralPath $Ledger -PathType Leaf)) { return }
    $doc = Get-Content -LiteralPath $Ledger -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not ($doc.routes.PSObject.Properties.Name -contains 'scheduler_non_yield')) { return }
    if (-not ($doc.routes.scheduler_non_yield.checks.PSObject.Properties.Name -contains $Name)) { return }
    & $setCheck -Ledger $Ledger -Route 'scheduler_non_yield' -Check $Name -Status $Status -Evidence $Evidence -Note $Note
    if ($LASTEXITCODE -ne 0) { throw "failed to update Scheduler route check: $Name" }
}
function Set-FindingsSweepHandoff($Payload) {
    $findingsDoc | Add-Member -NotePropertyName spinlockOwnerSweep -NotePropertyValue ([pscustomobject]$Payload) -Force
    Write-AtomicJson $Findings $findingsDoc
}

function Get-ThreadInventory {
    $batch = Join-Path $AnalysisDir "${CaseId}_us_spinlock.cdb"
    $log = Join-Path $AnalysisDir "${CaseId}_us_spinlock.txt"
    $commands = @"
.sympath $SymPath
.reload /f
.load $mex
.echo ===== US_SPINLOCK_BEGIN =====
!us -l -i Spinlock
.echo ===== US_SPINLOCK_END =====
q
"@
    Write-Utf8 $batch $commands
    Invoke-Cdb $batch $log $TimeoutSec
    $text = Get-Content -LiteralPath $log -Raw -Encoding UTF8
    $block = Get-Block $text '===== US_SPINLOCK_BEGIN =====' '===== US_SPINLOCK_END ====='
    if (-not $block) { throw "!us -l -i Spinlock output marker block missing: $log" }

    $groups = [Collections.Generic.List[object]]::new()
    $current = $null
    foreach ($line in ($block -split "`r?`n")) {
        if ($line -match '^(\d+)\s+threads?\s+\[stats\]:\s*(.*)$') {
            if ($current) { $groups.Add($current) | Out-Null }
            $current = [pscustomobject]@{
                Count=[int]$Matches[1];Header=[Collections.Generic.List[string]]::new();Frames=[Collections.Generic.List[string]]::new()
            }
            $current.Header.Add($Matches[2]) | Out-Null
        } elseif ($current -and $line -match '\[!mex\.t\s+\d+\]') {
            # Long mode normally emits one physical line, but retain wrapped ID
            # continuations so a large same-stack waiter group cannot be truncated.
            $current.Header.Add($line.Trim()) | Out-Null
        } elseif ($current -and $line -match '^\s+(?:[0-9a-fA-F`]{6,}|\(Inline\))') {
            $current.Frames.Add($line.TrimEnd()) | Out-Null
        }
    }
    if ($current) { $groups.Add($current) | Out-Null }
    $summary = [regex]::Match($block,'Threads matching filter:\s*(\d+)\s+out of\s+(\d+)','IgnoreCase')
    if (-not $summary.Success) { throw "!us -l -i Spinlock summary could not be parsed: $log" }
    $filterCandidateCount = [int]$summary.Groups[1].Value
    $totalThreads = [int]$summary.Groups[2].Value
    if ((($groups | Measure-Object Count -Sum).Sum) -ne $filterCandidateCount) {
        throw "!us Spinlock group count does not match summary: groups=$(($groups|Measure-Object Count -Sum).Sum), summary=$filterCandidateCount"
    }

    # Keep a semantic second check even with the narrower Spinlock filter.
    $strictPattern = '(?i)(?:[!:\s])Spinlock(?:Base|<|::)|SpinToAcquire'
    $strictGroups = @($groups | Where-Object { ($_.Frames -join "`n") -match $strictPattern })
    foreach ($group in $strictGroups) {
        $pairs = @([regex]::Matches(($group.Header -join ' '),'(\d+)\[!mex\.t\s+\d+\]\s+\[([0-9a-f]+)\]','IgnoreCase'))
        if ($pairs.Count -ne $group.Count) {
            throw "matching !us Spinlock group did not expose every debugger/OS thread pair ($($pairs.Count)/$($group.Count)); refusing to undercount"
        }
        $group | Add-Member -NotePropertyName ThreadPairs -NotePropertyValue @($pairs | ForEach-Object {
            [pscustomobject]@{debuggerId=[int]$_.Groups[1].Value;osTid=[Convert]::ToUInt32($_.Groups[2].Value,16)}
        })
    }
    $rows = foreach ($group in $strictGroups) {
        foreach ($pair in $group.ThreadPairs) {
            [pscustomobject]@{debuggerId=$pair.debuggerId;schedulerId=$null;worker='';workerState='';task='';osTid=[uint32]$pair.osTid;stack=($group.Frames -join "`n")}
        }
    }
    return [pscustomobject]@{
        source=$log;batch=$batch;sourceKind='direct cdb + MEX !us -l -i Spinlock';rows=@($rows);totalThreads=$totalThreads
        totalStackGroups=$groups.Count;filterCandidateCount=$filterCandidateCount;strictSpinlockGroupCount=$strictGroups.Count
        semanticRejectCount=($filterCandidateCount-@($rows).Count)
    }
}

New-Item -ItemType Directory -Path $AnalysisDir -Force | Out-Null
Ensure-SchedulerChecks
$findingsDoc = Get-Content -LiteralPath $Findings -Raw -Encoding UTF8 | ConvertFrom-Json
$currentHasSpin = @($findingsDoc.currentStack.functions | Where-Object { [string]$_ -match '(?i)Spinlock' }).Count -gt 0
$copiedHasSpin = @($findingsDoc.copiedStack.functions | Where-Object { [string]$_ -match '(?i)Spinlock' }).Count -gt 0
$precondition = $currentHasSpin -and $copiedHasSpin

$inventory = Get-ThreadInventory
$spinThreads = @($inventory.rows | Where-Object { [string]$_.stack -match '(?i)Spinlock' } | Sort-Object debuggerId)
$waiterThreads = @($spinThreads | Where-Object { [string]$_.stack -match '(?i)SpinToAcquire|SpinlockBase::Backoff|SpinlockBase::Sleep' })

if (-not $precondition -and -not $Force) {
    $minimal = [ordered]@{
        caseId=$CaseId;status='not-applicable';generatedAt=(Get-Date).ToString('o')
        precondition=[ordered]@{currentStackHasSpinlock=$currentHasSpin;copiedStackHasSpinlock=$copiedHasSpin;met=$false}
        inventory=[ordered]@{source=(Rel $inventory.source);sourceKind=$inventory.sourceKind;totalThreads=$inventory.totalThreads;spinlockThreadCount=$spinThreads.Count;spinlockDebuggerIds=@($spinThreads.debuggerId)}
        waiters=@();locks=@();limitations=@('Current and copied stacks were not both on Spinlock paths; owner sweep was not required.')
    }
    Write-AtomicJson $OutJson $minimal
    $html = "<!DOCTYPE html><html><head><meta charset='utf-8'><title>Spinlock owner sweep · $(HE $CaseId)</title></head><body><h1>Spinlock owner sweep · $(HE $CaseId)</h1><p>Not applicable: current and copied stacks are not both on Spinlock paths.</p></body></html>"
    Write-Utf8 $OutHtml $html
    Set-FindingsSweepHandoff ([ordered]@{
        status='not-applicable';command='!us -l -i Spinlock';preconditionMet=$false
        totalThreads=$inventory.totalThreads;spinlockThreadCount=$spinThreads.Count;waiterCandidateThreadCount=$waiterThreads.Count
        uniqueLockCount=0;report=(Rel $OutHtml);json=(Rel $OutJson);locks=@()
    })
    $evidence = @((Rel $OutJson),(Rel $OutHtml),(Rel $inventory.source))
    Set-RouteCheck 'spinlock_thread_inventory' 'completed' $evidence "condition false; inventory still found $($spinThreads.Count) Spinlock thread(s)"
    Set-RouteCheck 'spinlock_owner_validation' 'completed' $evidence 'conditional owner validation was not required'
    Write-Host "[run_spinlock_owner_sweep] not applicable -> $OutJson" -ForegroundColor Yellow
    exit 0
}

# Phase 1: discover every relevant frame dynamically for every matching thread.
$frameBatch = Join-Path $AnalysisDir "${CaseId}_spinlock_waiter_frames.cdb"
$frameLog = Join-Path $AnalysisDir "${CaseId}_spinlock_waiter_frames.txt"
$sb = [Text.StringBuilder]::new()
[void]$sb.AppendLine(".sympath $SymPath")
[void]$sb.AppendLine('.reload /f')
foreach ($thread in $waiterThreads) {
    [void]$sb.AppendLine(".echo ===== SPIN_WAITER_BEGIN $($thread.debuggerId) =====")
    [void]$sb.AppendLine("~$($thread.debuggerId)s")
    [void]$sb.AppendLine('dx -r1 @$curthread.Stack.Frames')
    [void]$sb.AppendLine(".echo ===== SPIN_WAITER_END $($thread.debuggerId) =====")
}
[void]$sb.AppendLine('q')
Write-Utf8 $frameBatch $sb.ToString()
Invoke-Cdb $frameBatch $frameLog $TimeoutSec
$frameText = Get-Content -LiteralPath $frameLog -Raw -Encoding UTF8

$waiterFrames = [Collections.Generic.List[object]]::new()
foreach ($thread in $waiterThreads) {
    $block = Get-Block $frameText "===== SPIN_WAITER_BEGIN $($thread.debuggerId) =====" "===== SPIN_WAITER_END $($thread.debuggerId) ====="
    $matches = @([regex]::Matches($block,'\[(0x[0-9a-f]+)\]\s*:\s*([^\r\n]*SpinToAcquire[^\r\n]*)','IgnoreCase'))
    if ($matches.Count -eq 0) {
        $matches = @([regex]::Matches($block,'\[(0x[0-9a-f]+)\]\s*:\s*([^\r\n]*SpinlockBase::(?:Backoff|Sleep)[^\r\n]*)','IgnoreCase') | Select-Object -First 1)
    }
    foreach ($match in $matches) {
        $frameIndex = $match.Groups[1].Value
        $frameSymbol = $match.Groups[2].Value.Trim()
        $caller = [regex]::Match($block,'\[(0x[0-9a-f]+)\]\s*:\s*([^\r\n]*CDbVLFTable::InternalGetRow[^\r\n]*)','IgnoreCase')
        $waiterFrames.Add([pscustomobject]@{
            debuggerId=$thread.debuggerId;osTid=$thread.osTid;schedulerId=$thread.schedulerId;worker=$thread.worker;task=$thread.task
            stack=$thread.stack;frameIndex=$frameIndex;frameSymbol=$frameSymbol
            callerFrame=if($caller.Success){$caller.Groups[1].Value}else{$null}
            callerSymbol=if($caller.Success){$caller.Groups[2].Value.Trim()}else{$null}
            frameDiscovery=$block
        }) | Out-Null
    }
}

# Phase 2: extract lock `this`, waiter ID, and per-acquisition SpinInfo for every frame.
$localsBatch = Join-Path $AnalysisDir "${CaseId}_spinlock_waiter_locals.cdb"
$localsLog = Join-Path $AnalysisDir "${CaseId}_spinlock_waiter_locals.txt"
$sb.Clear() | Out-Null
[void]$sb.AppendLine(".sympath $SymPath")
[void]$sb.AppendLine('.reload /f')
foreach ($frame in $waiterFrames) {
    [void]$sb.AppendLine(".echo ===== SPIN_LOCAL_BEGIN $($frame.debuggerId) $($frame.frameIndex) =====")
    [void]$sb.AppendLine("~$($frame.debuggerId)s")
    [void]$sb.AppendLine("dx @`$curthread.Stack.Frames[$($frame.frameIndex)].SwitchTo()")
    [void]$sb.AppendLine('dv /t /v')
    [void]$sb.AppendLine('dx -r1 spinInfo')
    [void]$sb.AppendLine(".echo ===== SPIN_LOCAL_END $($frame.debuggerId) $($frame.frameIndex) =====")
}
[void]$sb.AppendLine('q')
Write-Utf8 $localsBatch $sb.ToString()
Invoke-Cdb $localsBatch $localsLog $TimeoutSec
$localsText = Get-Content -LiteralPath $localsLog -Raw -Encoding UTF8

$waiters = [Collections.Generic.List[object]]::new()
foreach ($frame in $waiterFrames) {
    $block = Get-Block $localsText "===== SPIN_LOCAL_BEGIN $($frame.debuggerId) $($frame.frameIndex) =====" "===== SPIN_LOCAL_END $($frame.debuggerId) $($frame.frameIndex) ====="
    $lockMatch = [regex]::Match($block,'(?im)(?:class\s+)?(?:[A-Za-z0-9_]+!)?Spinlock(?:<[^>]+>)?\s*\*\s*this\s*=\s*(0x[0-9a-f`]+)')
    if (-not $lockMatch.Success) { $lockMatch = [regex]::Match($block,'(?im)SpinlockBase\s*\*\s*this\s*=\s*(0x[0-9a-f`]+)') }
    $idMatch = [regex]::Match($block,'(?im)unsigned (?:int64|__int64)\s+Id\s*=\s*(0x[0-9a-f`]+)')
    $backoffMatch = [regex]::Match($block,'(?im)m_backoffs\s*:\s*(0x[0-9a-f]+|\d+)')
    $templateMatch = [regex]::Match($frame.frameSymbol,'(?i)([A-Za-z0-9_]+)!Spinlock(<[^>]+>)?::(SpinToAcquire[^\s+]*)')
    $waiters.Add([pscustomobject]@{
        debuggerId=$frame.debuggerId;osTid=$frame.osTid;schedulerId=$frame.schedulerId;worker=$frame.worker;task=$frame.task
        stack=$frame.stack;frameIndex=$frame.frameIndex;frameSymbol=$frame.frameSymbol
        module=if($templateMatch.Success){$templateMatch.Groups[1].Value}else{'sqldk'}
        spinlockTemplate=if($templateMatch.Success){$templateMatch.Groups[2].Value}else{''}
        acquireMethod=if($templateMatch.Success){$templateMatch.Groups[3].Value}else{''}
        lockAddress=if($lockMatch.Success){'0x'+(Normalize-Hex $lockMatch.Groups[1].Value)}else{$null}
        waiterIdLocal=if($idMatch.Success){'0x'+(Normalize-Hex $idMatch.Groups[1].Value)}else{$null}
        backoffs=if($backoffMatch.Success){if($backoffMatch.Groups[1].Value-match'^0x'){[long](Hex-U64 $backoffMatch.Groups[1].Value)}else{[long]$backoffMatch.Groups[1].Value}}else{$null}
        callerFrame=$frame.callerFrame;callerSymbol=$frame.callerSymbol;locals=$block
    }) | Out-Null
}

$resolvedWaiters = @($waiters | Where-Object { $_.lockAddress })
$lockGroups = @($resolvedWaiters | Group-Object { Normalize-Hex $_.lockAddress })

# Phase 3: decode every distinct raw lock word.
$lockBatch = Join-Path $AnalysisDir "${CaseId}_spinlock_lock_words.cdb"
$lockLog = Join-Path $AnalysisDir "${CaseId}_spinlock_lock_words.txt"
$sb.Clear() | Out-Null
[void]$sb.AppendLine(".sympath $SymPath")
[void]$sb.AppendLine('.reload /f')
foreach ($group in $lockGroups) {
    $address = '0x' + $group.Name
    $module = [string]$group.Group[0].module
    [void]$sb.AppendLine(".echo ===== SPIN_LOCK_BEGIN $address =====")
    [void]$sb.AppendLine("dq $address L2")
    [void]$sb.AppendLine("dt ${module}!SpinlockBase::Lock $address")
    [void]$sb.AppendLine(".echo ===== SPIN_LOCK_END $address =====")
}
[void]$sb.AppendLine('q')
Write-Utf8 $lockBatch $sb.ToString()
Invoke-Cdb $lockBatch $lockLog $TimeoutSec
$lockText = Get-Content -LiteralPath $lockLog -Raw -Encoding UTF8

$locks = [Collections.Generic.List[object]]::new()
foreach ($group in $lockGroups) {
    $address = '0x' + $group.Name
    $block = Get-Block $lockText "===== SPIN_LOCK_BEGIN $address =====" "===== SPIN_LOCK_END $address ====="
    $qwordMatch = [regex]::Match($block,'(?im)^[0-9a-f`]+\s+([0-9a-f]{8}`[0-9a-f]{8})')
    $qword = if($qwordMatch.Success){Hex-U64 $qwordMatch.Groups[1].Value}else{[uint64]0}
    $lowDwordMask = [uint64]4294967295
    $ownerTid = [uint32]($qword -band $lowDwordMask)
    $miscInfo = [uint32](($qword -shr 32) -band $lowDwordMask)
    $locks.Add([pscustomobject]@{
        address=$address;qword=if($qwordMatch.Success){Hex-Text $qword 16}else{$null};ownerTid=[uint32]$ownerTid;ownerTidHex=Hex-Text $ownerTid
        miscInfo=[uint32]$miscInfo;miscInfoHex=Hex-Text $miscInfo;raw=$block
        waiterDebuggerIds=@($group.Group.debuggerId|Sort-Object -Unique);waiterOsTids=@($group.Group.osTid|Sort-Object -Unique)
        typeSymbols=@($group.Group.frameSymbol|Sort-Object -Unique);templates=@($group.Group.spinlockTemplate|Sort-Object -Unique)
        owner=$null;parentValidations=@()
    }) | Out-Null
}

# Phase 4: ask cdb to resolve each distinct nominal owner directly by OS TID,
# then capture its debugger ID, creation time, and stack. This deliberately does
# not depend on a prior all-thread inventory.
$ownerTids = @($locks | Where-Object { $_.ownerTid -ne 0 } | ForEach-Object { [uint32]$_.ownerTid } | Sort-Object -Unique)
$ownerBatch = Join-Path $AnalysisDir "${CaseId}_spinlock_owner_threads.cdb"
$ownerLog = Join-Path $AnalysisDir "${CaseId}_spinlock_owner_threads.txt"
$ownerText = ''
if ($ownerTids.Count -gt 0) {
    $sb.Clear() | Out-Null
    [void]$sb.AppendLine(".sympath $SymPath")
    [void]$sb.AppendLine('.reload /f')
    [void]$sb.AppendLine(".load $mex")
    foreach ($ownerTid in $ownerTids) {
        $ownerTidHex = ([uint32]$ownerTid).ToString('x')
        [void]$sb.AppendLine(".echo ===== SPIN_OWNER_BEGIN $ownerTid =====")
        [void]$sb.AppendLine("~~[$ownerTidHex]s")
        [void]$sb.AppendLine('!mex.t')
        [void]$sb.AppendLine('kv')
        [void]$sb.AppendLine(".echo ===== SPIN_OWNER_END $ownerTid =====")
    }
    [void]$sb.AppendLine('q')
    Write-Utf8 $ownerBatch $sb.ToString()
    Invoke-Cdb $ownerBatch $ownerLog $TimeoutSec
    $ownerText = Get-Content -LiteralPath $ownerLog -Raw -Encoding UTF8
} else {
    Write-Utf8 $ownerBatch "* No resolved nominal owner threads.`r`n"
    Write-Utf8 $ownerLog "No resolved nominal owner threads.`r`n"
}

foreach ($lock in $locks) {
    if ($lock.ownerTid -eq 0) {
        $lock.owner = [pscustomobject]@{resolution='unowned-word';debuggerId=$null;osTid=0;stack=@();stackText='';createTime=$null;stackCompatibility='not-applicable';actualHolderStatus='unresolved'}
        continue
    }
    $block = Get-Block $ownerText "===== SPIN_OWNER_BEGIN $([uint32]$lock.ownerTid) =====" "===== SPIN_OWNER_END $([uint32]$lock.ownerTid) ====="
    $identityMatches = @([regex]::Matches($block,'(?im)^\s*(\d+)\[!mex\.t\s+\d+\]\s+([0-9a-f]+)\s+\(0n(\d+)\).*?(\d{2}/\d{2}/\d{4}\s+\d{2}:\d{2}:\d{2}(?:\.\d+)?\s+[AP]M)'))
    $identity = @($identityMatches | Where-Object { [uint32]($_.Groups[3].Value) -eq [uint32]$lock.ownerTid } | Select-Object -First 1)
    if ($identity.Count -eq 0) {
        $lock.owner = [pscustomobject]@{resolution='nominal-owner-not-present';debuggerId=$null;osTid=$lock.ownerTid;stack=@();stackText=$block;createTime=$null;stackCompatibility='unavailable';actualHolderStatus='unresolved'}
        continue
    }
    $ownerDebuggerId = [int]$identity[0].Groups[1].Value
    $functions = Stack-Functions $block
    $isSelf = @($lock.waiterOsTids | Where-Object { [uint32]$_ -eq [uint32]$lock.ownerTid }).Count -gt 0
    $isLogLfm = @($lock.templates | Where-Object { [string]$_ -match '<160,5,258>' }).Count -gt 0 -or @($resolvedWaiters | Where-Object { (Normalize-Hex $_.lockAddress) -eq (Normalize-Hex $lock.address) -and [string]$_.stack -match 'LogInfoIter::GetNext' }).Count -gt 0
    $compatible = $null
    if ($isLogLfm) { $compatible = $block -match '(?i)SQLServerLogMgr::|\bLogMgr::|\bLFCB\b|HadrRbIoLogAccept|RecoveryUnit::|SwitchLC|AcceptLogBlocks|LogWriter|LogFlush|Shrink|Backup' }
    $compatibility = if($isSelf){'self-owner-match'}elseif($null-eq$compatible){'not-automatically-classified'}elseif($compatible){'source-family-compatible'}else{'outside-source-established-LOGLFM-region'}
    $status = if($isSelf){'validated-self-owner'}elseif($compatible-eq$true){'nominal-owner-resolved-stack-compatible'}else{'nominal-owner-resolved-not-validated'}
    $lock.owner = [pscustomobject]@{
        resolution='nominal-owner-thread-resolved';debuggerId=$ownerDebuggerId;osTid=[uint32]$lock.ownerTid
        stack=@($functions);stackText=$block;createTime=$identity[0].Groups[4].Value
        stackCompatibility=$compatibility;actualHolderStatus=$status;isWaiterOnSameLock=$isSelf
    }
}

# Phase 5a: for LOGLFM waiters, recover CDbVLFTable `this` and symbol offsets.
$logWaiters = @($resolvedWaiters | Where-Object { [string]$_.stack -match 'LogInfoIter::GetNext' -and $_.callerFrame })
$parentBatch = Join-Path $AnalysisDir "${CaseId}_spinlock_parent_objects.cdb"
$parentLog = Join-Path $AnalysisDir "${CaseId}_spinlock_parent_objects.txt"
$parentText = ''
$parentMemoryBatch = Join-Path $AnalysisDir "${CaseId}_spinlock_parent_memory.cdb"
$parentMemoryLog = Join-Path $AnalysisDir "${CaseId}_spinlock_parent_memory.txt"
$parentMemoryText = ''
if ($logWaiters.Count -gt 0) {
    $sb.Clear() | Out-Null
    [void]$sb.AppendLine(".sympath $SymPath")
    [void]$sb.AppendLine('.reload /f')
    [void]$sb.AppendLine('.echo ===== SPIN_PARENT_LAYOUT_BEGIN =====')
    [void]$sb.AppendLine('dt sqlmin!CDbVLFTable m_LogInfoIter')
    [void]$sb.AppendLine('dt sqlmin!LogInfoIter m_logmgr')
    [void]$sb.AppendLine('dt sqlmin!SQLServerLogMgr m_lfmAccess')
    [void]$sb.AppendLine('.echo ===== SPIN_PARENT_LAYOUT_END =====')
    foreach ($waiter in $logWaiters) {
        [void]$sb.AppendLine(".echo ===== SPIN_PARENT_BEGIN $($waiter.debuggerId) $($waiter.frameIndex) =====")
        [void]$sb.AppendLine("~$($waiter.debuggerId)s")
        [void]$sb.AppendLine("dx @`$curthread.Stack.Frames[$($waiter.callerFrame)].SwitchTo()")
        [void]$sb.AppendLine('dv /t /v')
        [void]$sb.AppendLine(".echo ===== SPIN_PARENT_END $($waiter.debuggerId) $($waiter.frameIndex) =====")
    }
    [void]$sb.AppendLine('q')
    Write-Utf8 $parentBatch $sb.ToString()
    Invoke-Cdb $parentBatch $parentLog $TimeoutSec
    $parentText = Get-Content -LiteralPath $parentLog -Raw -Encoding UTF8
    $layout = Get-Block $parentText '===== SPIN_PARENT_LAYOUT_BEGIN =====' '===== SPIN_PARENT_LAYOUT_END ====='
    $tableOffsetMatch = [regex]::Match($layout,'(?im)\+(0x[0-9a-f]+)\s+m_LogInfoIter')
    $logMgrOffsetMatch = [regex]::Match($layout,'(?im)\+(0x[0-9a-f]+)\s+m_logmgr')
    $lfmOffsetMatch = [regex]::Match($layout,'(?im)\+(0x[0-9a-f]+)\s+m_lfmAccess')
    if ($tableOffsetMatch.Success -and $logMgrOffsetMatch.Success -and $lfmOffsetMatch.Success) {
        $tableOffset = Hex-U64 $tableOffsetMatch.Groups[1].Value
        $logMgrOffset = Hex-U64 $logMgrOffsetMatch.Groups[1].Value
        $lfmOffset = Hex-U64 $lfmOffsetMatch.Groups[1].Value
        $parentRequests = [Collections.Generic.List[object]]::new()
        foreach ($waiter in $logWaiters) {
            $block = Get-Block $parentText "===== SPIN_PARENT_BEGIN $($waiter.debuggerId) $($waiter.frameIndex) =====" "===== SPIN_PARENT_END $($waiter.debuggerId) $($waiter.frameIndex) ====="
            $tableMatch = [regex]::Match($block,'(?im)(?:class\s+)?CDbVLFTable\s*\*\s*this\s*=\s*(0x[0-9a-f`]+)')
            if ($tableMatch.Success) {
                $tableAddress = Hex-U64 $tableMatch.Groups[1].Value
                $iterAddress = $tableAddress + $tableOffset
                $parentRequests.Add([pscustomobject]@{waiter=$waiter;tableAddress=$tableAddress;iterAddress=$iterAddress;logMgrOffset=$logMgrOffset;lfmOffset=$lfmOffset;locals=$block}) | Out-Null
            }
        }
        if ($parentRequests.Count -gt 0) {
            $sb.Clear() | Out-Null
            [void]$sb.AppendLine(".sympath $SymPath")
            [void]$sb.AppendLine('.reload /f')
            foreach ($request in $parentRequests) {
                $iterText = Hex-Text $request.iterAddress
                [void]$sb.AppendLine(".echo ===== SPIN_PARENT_MEMORY_BEGIN $($request.waiter.debuggerId) $($request.waiter.frameIndex) =====")
                [void]$sb.AppendLine("dq $iterText L3")
                [void]$sb.AppendLine(".echo ===== SPIN_PARENT_MEMORY_END $($request.waiter.debuggerId) $($request.waiter.frameIndex) =====")
            }
            [void]$sb.AppendLine('q')
            Write-Utf8 $parentMemoryBatch $sb.ToString()
            Invoke-Cdb $parentMemoryBatch $parentMemoryLog $TimeoutSec
            $parentMemoryText = Get-Content -LiteralPath $parentMemoryLog -Raw -Encoding UTF8
            foreach ($request in $parentRequests) {
                $block = Get-Block $parentMemoryText "===== SPIN_PARENT_MEMORY_BEGIN $($request.waiter.debuggerId) $($request.waiter.frameIndex) =====" "===== SPIN_PARENT_MEMORY_END $($request.waiter.debuggerId) $($request.waiter.frameIndex) ====="
                $qwords = @([regex]::Matches($block,'(?im)^[0-9a-f`]+\s+([0-9a-f]{8}`[0-9a-f]{8})\s+([0-9a-f]{8}`[0-9a-f]{8})') | Select-Object -First 1)
                $fileMgr = $null; $logMgr = $null
                if ($qwords.Count -gt 0) {
                    $fileMgr = Hex-U64 $qwords[0].Groups[1].Value
                    $logMgr = Hex-U64 $qwords[0].Groups[2].Value
                }
                $computedLock = if($logMgr){$logMgr + $request.lfmOffset}else{[uint64]0}
                $validation = [pscustomobject]@{
                    waiterDebuggerId=$request.waiter.debuggerId;tableAddress=Hex-Text $request.tableAddress;logInfoIterAddress=Hex-Text $request.iterAddress
                    fileMgr=if($fileMgr){Hex-Text $fileMgr}else{$null};logMgr=if($logMgr){Hex-Text $logMgr}else{$null};lfmOffset=Hex-Text $request.lfmOffset
                    computedLock=if($computedLock){Hex-Text $computedLock}else{$null};observedLock=$request.waiter.lockAddress
                    addressChainCoherent=($computedLock-ne0-and(Normalize-Hex (Hex-Text $computedLock))-eq(Normalize-Hex $request.waiter.lockAddress))
                    runtimeDynamicTypeVerified=$false;dynamicTypeEvidence='LogMgr vtable page is not required for address-chain validation and may be absent in a minidump.'
                    raw=$block
                }
                $targetLock = @($locks | Where-Object { (Normalize-Hex $_.address) -eq (Normalize-Hex $request.waiter.lockAddress) } | Select-Object -First 1)
                if ($targetLock.Count -gt 0) { $targetLock[0].parentValidations += $validation }
            }
        } else {
            Write-Utf8 $parentMemoryBatch "* No parent memory requests could be formed.`r`n"
            Write-Utf8 $parentMemoryLog "No parent memory requests could be formed.`r`n"
        }
    } else {
        Write-Utf8 $parentMemoryBatch "* Parent type offsets unavailable.`r`n"
        Write-Utf8 $parentMemoryLog "Parent type offsets unavailable.`r`n"
    }
} else {
    Write-Utf8 $parentBatch "* No LogInfoIter/LOGLFM waiters.`r`n"
    Write-Utf8 $parentLog "No LogInfoIter/LOGLFM waiters.`r`n"
    Write-Utf8 $parentMemoryBatch "* No LogInfoIter/LOGLFM waiters.`r`n"
    Write-Utf8 $parentMemoryLog "No LogInfoIter/LOGLFM waiters.`r`n"
}

$limitations = [Collections.Generic.List[string]]::new()
if ($spinThreads.Count -eq 0) { $limitations.Add('No current thread stack contains Spinlock.') }
if ($waiterFrames.Count -lt $waiterThreads.Count) { $limitations.Add("Spinlock frame discovery succeeded for $($waiterFrames.Count)/$($waiterThreads.Count) matching waiter threads.") }
if ($resolvedWaiters.Count -lt $waiterFrames.Count) { $limitations.Add("Lock address extraction succeeded for $($resolvedWaiters.Count)/$($waiterFrames.Count) acquire frames.") }
if (@($locks | Where-Object { $_.owner.actualHolderStatus -eq 'unresolved' }).Count -gt 0) { $limitations.Add('One or more lock words did not resolve to a present owner thread.') }
if (@($locks.parentValidations | Where-Object { -not $_.runtimeDynamicTypeVerified }).Count -gt 0) { $limitations.Add('Parent address propagation may be coherent while runtime LogMgr dynamic type remains unverified in a filtered minidump.') }

$result = [ordered]@{
    caseId=$CaseId;status='completed';generatedAt=(Get-Date).ToString('o')
    precondition=[ordered]@{currentStackHasSpinlock=$currentHasSpin;copiedStackHasSpinlock=$copiedHasSpin;met=$precondition;forced=[bool]$Force}
    inventory=[ordered]@{
        source=(Rel $inventory.source);sourceKind=$inventory.sourceKind;totalThreads=$inventory.totalThreads;totalStackGroups=$inventory.totalStackGroups
        spinlockThreadCount=$spinThreads.Count;spinlockDebuggerIds=@($spinThreads.debuggerId);spinlockOsTids=@($spinThreads.osTid)
        waiterCandidateThreadCount=$waiterThreads.Count
    }
    spinlockThreads=@($spinThreads | ForEach-Object { [ordered]@{debuggerId=$_.debuggerId;osTid=$_.osTid;schedulerId=$_.schedulerId;worker=$_.worker;task=$_.task;stack=$_.stack} })
    waiters=@($waiters)
    locks=@($locks)
    summary=[ordered]@{
        uniqueLockCount=$locks.Count
        resolvedNominalOwnerCount=@($locks | Where-Object { $_.owner.resolution -eq 'nominal-owner-thread-resolved' }).Count
        validatedSelfOwnerCount=@($locks | Where-Object { $_.owner.actualHolderStatus -eq 'validated-self-owner' }).Count
        stackIncompatibleNominalOwnerCount=@($locks | Where-Object { $_.owner.stackCompatibility -match 'outside-source-established' }).Count
        actualHolderUnresolvedCount=@($locks | Where-Object { $_.owner.actualHolderStatus -ne 'validated-self-owner' }).Count
    }
    evidence=[ordered]@{
        threadInventory=(Rel $inventory.source);frameDiscovery=(Rel $frameLog);waiterLocals=(Rel $localsLog);lockWords=(Rel $lockLog)
        ownerThreads=(Rel $ownerLog);parentObjects=(Rel $parentLog);parentMemory=(Rel $parentMemoryLog)
    }
    limitations=@($limitations)
}
Write-AtomicJson $OutJson $result

$handoffLocks = @($locks | ForEach-Object {
    [ordered]@{
        address=$_.address;qword=$_.qword;waiterDebuggerIds=@($_.waiterDebuggerIds);waiterOsTids=@($_.waiterOsTids)
        nominalOwnerTid=$_.ownerTidHex;resolvedOwnerDebuggerId=$_.owner.debuggerId
        ownerStackCompatibility=$_.owner.stackCompatibility;actualHolderStatus=$_.owner.actualHolderStatus
        parentAddressChainCoherent=(@($_.parentValidations | Where-Object addressChainCoherent).Count -gt 0)
    }
})
Set-FindingsSweepHandoff ([ordered]@{
    status='completed';command='!us -l -i Spinlock';preconditionMet=$precondition
    totalThreads=$inventory.totalThreads;matchingStackGroups=$inventory.totalStackGroups
    spinlockThreadCount=$spinThreads.Count;spinlockDebuggerIds=@($spinThreads.debuggerId);spinlockOsTids=@($spinThreads.osTid)
    waiterCandidateThreadCount=$waiterThreads.Count;uniqueLockCount=$locks.Count
    resolvedNominalOwnerCount=$result.summary.resolvedNominalOwnerCount;actualHolderUnresolvedCount=$result.summary.actualHolderUnresolvedCount
    report=(Rel $OutHtml);json=(Rel $OutJson);locks=$handoffLocks
})

# Render a standalone evidence report.
$threadRows = [Text.StringBuilder]::new()
foreach ($thread in $spinThreads) {
    [void]$threadRows.Append("<tr><td>$($thread.debuggerId)</td><td class='mono'>0x$(([uint32]$thread.osTid).ToString('x'))</td><td>$([int]$thread.schedulerId)</td><td class='mono'>$(HE $thread.worker)</td><td><pre>$(HE $thread.stack)</pre></td></tr>")
}
$lockRows = [Text.StringBuilder]::new()
$lockDetails = [Text.StringBuilder]::new()
foreach ($lock in $locks) {
    $ownerDebugger = if($null-ne$lock.owner.debuggerId){[string]$lock.owner.debuggerId}else{'unresolved'}
    $parentCoherent = @($lock.parentValidations | Where-Object addressChainCoherent).Count -gt 0
    [void]$lockRows.Append("<tr><td class='mono'>$(HE $lock.address)</td><td class='mono'>$(HE $lock.qword)</td><td class='mono'>$(HE $lock.ownerTidHex)</td><td>$ownerDebugger</td><td>$(HE $lock.owner.stackCompatibility)</td><td>$(HE $lock.owner.actualHolderStatus)</td><td>$parentCoherent</td><td>$(HE (@($lock.waiterDebuggerIds)-join ', '))</td></tr>")
    [void]$lockDetails.Append("<h3>Lock <span class='mono'>$(HE $lock.address)</span></h3><div class='cards'><div><b>Nominal owner</b>$(HE $lock.ownerTidHex)</div><div><b>Resolved debugger thread</b>$ownerDebugger</div><div><b>Actual holder status</b>$(HE $lock.owner.actualHolderStatus)</div></div><h4>Nominal owner stack</h4><pre>$(HE $lock.owner.stackText)</pre>")
    foreach($pv in @($lock.parentValidations)){[void]$lockDetails.Append("<h4>LOGLFM parent-address validation</h4><table><tr><th>CDbVLFTable</th><td class='mono'>$(HE $pv.tableAddress)</td></tr><tr><th>LogInfoIter</th><td class='mono'>$(HE $pv.logInfoIterAddress)</td></tr><tr><th>m_logmgr</th><td class='mono'>$(HE $pv.logMgr)</td></tr><tr><th>Computed lock</th><td class='mono'>$(HE $pv.computedLock)</td></tr><tr><th>Observed lock</th><td class='mono'>$(HE $pv.observedLock)</td></tr><tr><th>Address chain coherent</th><td>$($pv.addressChainCoherent)</td></tr><tr><th>Runtime dynamic type verified</th><td>$($pv.runtimeDynamicTypeVerified)</td></tr></table>")}
}
$limitationItems = @($limitations | ForEach-Object { '<li>' + (HE $_) + '</li>' }) -join ''
$css = @'
:root{--bg:#1e1e2e;--surface:#252538;--border:#3a3a55;--text:#cdd6f4;--dim:#a6adc8;--accent:#89b4fa;--green:#a6e3a1;--yellow:#f9e2af;--teal:#94e2d5;--mauve:#cba6f7}*{box-sizing:border-box}body{margin:0;padding:28px;background:var(--bg);color:var(--text);font:14px/1.55 'Segoe UI',sans-serif}main{max-width:1400px;margin:auto}h1{color:var(--accent)}h2{color:var(--mauve);border-bottom:1px solid var(--border);padding-bottom:6px}h3,h4{color:var(--teal)}a{color:var(--accent)}table{border-collapse:collapse;width:100%;display:block;overflow-x:auto;margin:12px 0}th,td{border:1px solid var(--border);padding:7px 9px;vertical-align:top}th{background:#2b2b40;color:var(--accent);text-align:left}.mono,pre{font-family:'Cascadia Code',Consolas,monospace}pre{white-space:pre-wrap;word-break:break-word;background:#181825;border:1px solid var(--border);border-radius:6px;padding:10px;max-height:480px;overflow:auto}.cards{display:flex;gap:10px;flex-wrap:wrap}.cards>div{background:var(--surface);border:1px solid var(--border);border-radius:7px;padding:8px 12px}.cards b{display:block;color:var(--accent)}.note{background:#181825;border-left:3px solid var(--yellow);padding:10px 12px;color:var(--dim)}
'@
$html = "<!DOCTYPE html><html lang='en'><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'><title>Spinlock owner sweep · $(HE $CaseId)</title><style>$css</style></head><body><main><h1>Gate C · Spinlock Thread and Nominal Owner Sweep</h1><div class='cards'><div><b>Total dump threads</b>$($inventory.totalThreads)</div><div><b>Spinlock stacks</b>$($spinThreads.Count)</div><div><b>Acquire/backoff candidates</b>$($waiterThreads.Count)</div><div><b>Unique lock addresses</b>$($locks.Count)</div></div><p class='note'>m_threadId is reported as the <b>nominal payload owner</b>. It is promoted to a validated actual holder only when owner identity and evidence are coherent; a resolved TID alone is insufficient.</p><h2>Threads whose current stack contains Spinlock</h2><table><thead><tr><th>Debugger ID</th><th>OS TID</th><th>Scheduler</th><th>Worker</th><th>Current stack</th></tr></thead><tbody>$($threadRows.ToString())</tbody></table><h2>Lock and owner summary</h2><table><thead><tr><th>Lock</th><th>Raw qword</th><th>Nominal owner TID</th><th>Debugger owner</th><th>Owner-stack compatibility</th><th>Actual-holder status</th><th>Parent chain coherent</th><th>Waiters</th></tr></thead><tbody>$($lockRows.ToString())</tbody></table><h2>Owner details</h2>$($lockDetails.ToString())<h2>Limitations</h2><ul>$limitationItems</ul><h2>Raw evidence</h2><ul><li><a href='$(HE ([IO.Path]::GetFileName($frameLog)))'>frame discovery</a></li><li><a href='$(HE ([IO.Path]::GetFileName($localsLog)))'>waiter locals</a></li><li><a href='$(HE ([IO.Path]::GetFileName($lockLog)))'>lock words</a></li><li><a href='$(HE ([IO.Path]::GetFileName($ownerLog)))'>owner threads</a></li><li><a href='$(HE ([IO.Path]::GetFileName($parentMemoryLog)))'>parent memory</a></li><li><a href='$(HE ([IO.Path]::GetFileName($OutJson)))'>structured JSON</a></li></ul></main></body></html>"
Write-Utf8 $OutHtml $html

$evidence = @((Rel $OutJson),(Rel $OutHtml),(Rel $inventory.source),(Rel $frameLog),(Rel $localsLog))
Set-RouteCheck 'spinlock_thread_inventory' 'completed' $evidence "enumerated $($inventory.totalThreads) threads; Spinlock current stacks=$($spinThreads.Count); debugger IDs=$(@($spinThreads.debuggerId)-join ',')"
$ownerEvidence = @((Rel $OutJson),(Rel $OutHtml),(Rel $lockLog),(Rel $ownerLog),(Rel $parentLog),(Rel $parentMemoryLog))
if ($waiterFrames.Count -gt 0 -and $resolvedWaiters.Count -eq 0) {
    Set-RouteCheck 'spinlock_owner_validation' 'unavailable-with-evidence' $ownerEvidence 'Spinlock frames were found but no lock address could be extracted.'
} else {
    Set-RouteCheck 'spinlock_owner_validation' 'completed' $ownerEvidence "unique locks=$($locks.Count); nominal owners resolved=$($result.summary.resolvedNominalOwnerCount); actual holders unresolved=$($result.summary.actualHolderUnresolvedCount)"
}
Write-Host "[run_spinlock_owner_sweep] PASS: threads=$($inventory.totalThreads) spinlock=$($spinThreads.Count) locks=$($locks.Count) -> $OutJson" -ForegroundColor Green
exit 0
