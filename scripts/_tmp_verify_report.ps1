$f = 'C:\Users\lduan\sqlcsi-archive\reports\2607030030000843_latch_timeout\latch_timeout_report_revised.html'
if (Test-Path $f) {
    $sz = (Get-Item $f).Length
    Write-Host "OK size=$sz bytes"
    $lines = (Get-Content $f).Count
    Write-Host "lines=$lines"
} else {
    Write-Host "MISSING"
}
Get-ChildItem 'C:\Users\lduan\sqlcsi-archive\reports\2607030030000843_latch_timeout\' -Filter '*.html' | Select-Object Name, Length
