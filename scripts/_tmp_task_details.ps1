$owner  = '25D5588BC28'
$dir    = 'C:\Users\lduan\sqlcsi-archive\reports\2607030030000843_dump_code_analysis'

# 1. Owner (SPID 98) — its tsqlstack + task_all detail
Write-Host "=== SPID 98 owner task in tsqlstack_all.txt ==="
$tsq = Get-Content -LiteralPath (Join-Path $dir '2607030030000843_tsqlstack_all.txt') -Encoding UTF8
$hit = 0
for ($i=0; $i -lt $tsq.Count; $i++) {
    if ($tsq[$i] -match 'SPID.*98\b|0x25D5588BC28|spid[= ]98\b') {
        $lo = [Math]::Max(0,$i-2); $hi = [Math]::Min($tsq.Count-1,$i+40)
        Write-Host "-- L$i .."
        for ($j=$lo; $j -le $hi; $j++) { Write-Host "L$j : $($tsq[$j])" }
        $hit++
        if ($hit -ge 3) { break }
    }
}
Write-Host ""
Write-Host "=== SPID 98 in task_all.console.txt ==="
$tk = Get-Content -LiteralPath (Join-Path $dir '2607030030000843_task_all.console.txt') -Encoding UTF8
for ($i=0; $i -lt $tk.Count; $i++) {
    if ($tk[$i] -match '(?<!\d)98\b.*Wrk|0x25D5588BC28|SPID:98') {
        $lo = [Math]::Max(0,$i-1); $hi = [Math]::Min($tk.Count-1,$i+8)
        for ($j=$lo; $j -le $hi; $j++) { Write-Host "L$j : $($tk[$j])" }
        Write-Host "---"
    }
}

Write-Host ""
Write-Host "=== search tasks_enumerate.txt for owner + waiter ==="
$te = Get-Content -LiteralPath (Join-Path $dir '2607030030000843_tasks_enumerate.txt') -Encoding UTF8
foreach ($needle in @('25D5588BC28','37A62DC4108')) {
    Write-Host "-- $needle --"
    for ($i=0; $i -lt $te.Count; $i++) {
        if ($te[$i] -imatch $needle) {
            Write-Host "L$i : $($te[$i])"
        }
    }
}

Write-Host ""
Write-Host "=== search us.txt for spid72s / 0x37A62DC4108 ==="
$us = Get-Content -LiteralPath (Join-Path $dir '2607030030000843_us.txt') -Encoding UTF8
$hits = 0
for ($i=0; $i -lt $us.Count; $i++) {
    if ($us[$i] -match '(?i)37A62DC4108|SPID.*72\b|spid[= ]72\b|72s|SystemThread') {
        Write-Host "L$i : $($us[$i])"
        $hits++
        if ($hits -ge 40) { break }
    }
}
