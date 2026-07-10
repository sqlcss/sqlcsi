$p = 'C:\Users\lduan\sqlcsi-archive\reports\2607030030000843_latch_timeout\_dbmap.txt'
$out = 'C:\Users\lduan\sqlcsi-archive\reports\2607030030000843_latch_timeout\_context_snippets.txt'
$lines = @()
$lines += "== BUFFER POOL / CHECKPOINT MESSAGES =="
Select-String -Path $p -Pattern 'Buffer Pool|failed to generate|VMS_scheduler|Long IO|non-yielding|WRITELOG|checkpoint|SchedulerMonitor|Long backup|Wait for buffer' | ForEach-Object {
    $lines += ("L{0}: {1}" -f $_.LineNumber, $_.Line.Trim())
}
$lines += ""
$lines += "== ALL ENTRIES 12:03..12:15 =="
Get-Content $p | ForEach-Object -Begin { $ln=0 } -Process {
    $ln++
    if ($_ -match '2026-07-02 12:(0[3-9]|1[0-5])') {
        $lines += ("L{0}: {1}" -f $ln, $_.Trim())
    }
}
[System.IO.File]::WriteAllLines($out, $lines)
Write-Host "wrote $out"
"lines: $($lines.Count)"
