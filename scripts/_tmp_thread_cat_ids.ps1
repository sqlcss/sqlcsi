param([string]$Reports = 'C:\Users\lduan\sqlcsi-archive\reports\2607030030000843_dump_overall\dumpviewer_out\Reports')

# Functional buckets (id, call_stack). Order = display order.
$cats = @(
    @{ file='BusyThreads.html';       key='Busy';        label='忙碌线程 (Busy)' }
    @{ file='NonYieldThreads.html';   key='NonYield';    label='未让出调度 (NonYield)' }
    @{ file='LatchThreads.html';      key='Latch';       label='闩锁相关 (Latch)' }
    @{ file='InParallelThreads.html'; key='InParallel';  label='并行执行 (Parallel)' }
    @{ file='FileIOThreads.html';     key='FileIO';      label='文件 I/O (File I/O)' }
    @{ file='NetworkIOThreads.html';  key='NetworkIO';   label='网络 I/O (Network I/O)' }
    @{ file='IOCPThreads.html';       key='IOCP';        label='IOCP 线程' }
    @{ file='BackupThreads.html';     key='Backup';      label='备份操作 (Backup)' }
    @{ file='CheckpointThreads.html'; key='Checkpoint';  label='检查点 (Checkpoint)' }
    @{ file='LazyWriterThreads.html'; key='LazyWriter';  label='惰性写入 (LazyWriter)' }
    @{ file='MonitorThreads.html';    key='Monitor';     label='监视器线程 (Monitor)' }
    @{ file='ExceptionThreads.html';  key='Exception';   label='触发异常 (Exception)' }
)

foreach ($c in $cats) {
    $htmlPath = Join-Path $Reports $c.file
    if (-not (Test-Path $htmlPath)) { Write-Host "$($c.key): HTML MISSING"; continue }
    $html = Get-Content $htmlPath -Raw
    $sc = [regex]::Match($html, "src='([^']*_json\.js)'").Groups[1].Value
    $scPath = Join-Path $Reports $sc
    if (-not $sc -or -not (Test-Path $scPath)) { Write-Host "$($c.key): sidecar MISSING ($sc)"; continue }
    $txt = Get-Content $scPath -Raw
    if ([string]::IsNullOrWhiteSpace($txt)) { Write-Host "$($c.key): sidecar EMPTY"; continue }
    # each data row: ^  [ <id>, "..stack.." ]
    $ids = [regex]::Matches($txt, '(?m)^\s{2}\[\s*(\d+)\s*,') | ForEach-Object { [int]$_.Groups[1].Value }
    $idStr = ($ids | Sort-Object) -join ', '
    Write-Host ("{0,-12} file={1,-22} n={2,-3} ids={3}" -f $c.key, $c.file, $ids.Count, $idStr)
}
