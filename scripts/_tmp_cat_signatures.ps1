param([string]$Reports = 'C:\Users\lduan\sqlcsi-archive\reports\2607030030000843_dump_overall\dumpviewer_out\Reports')

$cats = 'BusyThreads','NonYieldThreads','LatchThreads','InParallelThreads','FileIOThreads',
        'NetworkIOThreads','IOCPThreads','BackupThreads','CheckpointThreads','LazyWriterThreads',
        'MonitorThreads','ExceptionThreads'

foreach ($cat in $cats) {
    $htmlPath = Join-Path $Reports "$cat.html"
    if (-not (Test-Path $htmlPath)) { continue }
    $sc = [regex]::Match((Get-Content $htmlPath -Raw), "src='([^']*_json\.js)'").Groups[1].Value
    $scPath = Join-Path $Reports $sc
    Write-Host "==================== $cat ===================="
    if (-not (Test-Path $scPath)) { Write-Host "(no sidecar)"; continue }
    $txt = Get-Content $scPath -Raw
    if ([string]::IsNullOrWhiteSpace($txt)) { Write-Host "(empty)"; continue }
    # each data row: [ id, "stack..." ]  — capture id + stack
    $rowsM = [regex]::Matches($txt, '(?ms)^\s{2}\[\s*(\d+)\s*,\s*"(.*?)"\]\s*,?\s*$')
    # frequency of mod!func frames across this category
    $freq = @{}
    foreach ($rm in $rowsM) {
        $stack = $rm.Groups[2].Value
        $frames = [regex]::Matches($stack, '([A-Za-z0-9_]+![A-Za-z0-9_:~<>]+)')
        $seen = @{}
        foreach ($fm in $frames) {
            $f = $fm.Groups[1].Value
            if ($seen.ContainsKey($f)) { continue }; $seen[$f]=$true
            if ($freq.ContainsKey($f)) { $freq[$f]++ } else { $freq[$f]=1 }
        }
    }
    $nrows = $rowsM.Count
    Write-Host "rows=$nrows  ids=$((@($rowsM | ForEach-Object { $_.Groups[1].Value })) -join ',')"
    # frames present in ALL or most rows, excluding generic boilerplate
    $boiler = 'ntdll|KERNELBASE|kernel32|sechost|msvcrt|ucrtbase|sqldk!SOS_Scheduler|sqldk!SOS_Task|sqldk!Worker|sqldk!ThreadScheduler|sqldk!SystemThreadDispatcher|sqldk!SchedulerManager|sqldk!SOS_DispatcherPool|sqldk!Dispatcher'
    $freq.GetEnumerator() | Where-Object { $_.Value -ge [math]::Ceiling($nrows/2) -and $_.Key -notmatch $boiler } |
        Sort-Object Value -Descending | Select-Object -First 8 |
        ForEach-Object { "   {0,3}/{1}  {2}" -f $_.Value, $nrows, $_.Key }
}
