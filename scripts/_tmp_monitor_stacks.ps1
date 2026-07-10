param([string]$Reports = 'C:\Users\lduan\sqlcsi-archive\reports\2607030030000843_dump_overall\dumpviewer_out\Reports')
$td = Get-Content 'C:\Users\lduan\sqlcsi-archive\reports\2607030030000843_dump_overall\parsed\threaddetails.json' -Raw | ConvertFrom-Json
$byId = @{}; foreach ($r in $td.rows) { $byId["$($r.thread_id)"] = $r }
foreach ($id in 6,23,30,47,67,114,123,263,324,122) {
    $r = $byId["$id"]
    Write-Host "==================== tid $id  state=$($r.worker_state) wait=$($r.worker_last_wait) ===================="
    ($r.call_stack -split "`n") | Where-Object { $_ -match '(sql|clr|CLR)' } | Select-Object -First 12 | ForEach-Object { $_.Trim() }
}
