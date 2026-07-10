$f = 'C:\Users\lduan\sqlcsi-archive\reports\2607030030000843_dump_code_analysis\2607030030000843_tsqlstack_all.txt'
Write-Host ("length: {0}" -f (Get-Item $f).Length)
Write-Host "== first 60 lines =="
$c = Get-Content -LiteralPath $f -Encoding UTF8
$c | Select-Object -First 60 | ForEach-Object { Write-Host $_ }
Write-Host "== count of ===TASK_=="
($c | Where-Object { $_ -match '===TASK_' }).Count
Write-Host "== first 5 ===TASK_ lines =="
$c | Where-Object { $_ -match '===TASK_' } | Select-Object -First 5 | ForEach-Object { Write-Host $_ }
Write-Host ""
Write-Host "== overall_report.html (relevant sections) =="
$html = Get-Content 'C:\Users\lduan\sqlcsi-archive\reports\2607030030000843_dump_overall\2607030030000843_overall_report.html' -Encoding UTF8
# Extract text (crude) — print lines with meaningful content
$strip = $html | ForEach-Object { $_ -replace '<[^>]+>','' } | Where-Object { $_ -match '\S' -and $_ -notmatch '^\s*[{;.,]' }
$strip | Select-Object -First 120 | ForEach-Object { Write-Host $_ }
