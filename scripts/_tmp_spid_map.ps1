$dir  = 'C:\Users\lduan\sqlcsi-archive\reports\2607030030000843_dump_code_analysis'

Write-Host "=== list of SPID: entries in tsqlstack_all.txt ==="
$tsq = Get-Content -LiteralPath (Join-Path $dir '2607030030000843_tsqlstack_all.txt') -Encoding UTF8
for ($i=0; $i -lt $tsq.Count; $i++) {
    if ($tsq[$i] -imatch 'SPID:\s*\d') {
        Write-Host "L$i : $($tsq[$i])"
    }
}

Write-Host ""
Write-Host "=== ALL SPID entries in task_all.console.txt (first 60 lines each match) ==="
$tk = Get-Content -LiteralPath (Join-Path $dir '2607030030000843_task_all.console.txt') -Encoding UTF8
for ($i=0; $i -lt $tk.Count; $i++) {
    if ($tk[$i] -imatch 'SOS_Task\s*:') {
        Write-Host "L$i : $($tk[$i])"
    }
}

Write-Host ""
Write-Host "=== ALL SPID entries in task_all.txt (owner-facing headers) ==="
$tk2 = Get-Content -LiteralPath (Join-Path $dir '2607030030000843_task_all.txt') -Encoding UTF8
for ($i=0; $i -lt $tk2.Count; $i++) {
    if ($tk2[$i] -imatch 'SOS_Task\s*:') {
        Write-Host "L$i : $($tk2[$i])"
    }
}

# Snapshot SPID 98 tsqlstack (find and print full block)
Write-Host ""
Write-Host "=== hunt for spid98 anywhere in tsqlstack (looser) ==="
for ($i=0; $i -lt $tsq.Count; $i++) {
    if ($tsq[$i] -imatch '\b98\b') {
        Write-Host "L$i : $($tsq[$i])"
    }
}

Write-Host ""
Write-Host "=== dump_output.txt (top of first-pass triage) ==="
$do = Get-Content -LiteralPath (Join-Path $dir '2607030030000843_dump_output.txt') -Encoding UTF8
$do | Select-Object -First 60 | ForEach-Object { Write-Host $_ }
