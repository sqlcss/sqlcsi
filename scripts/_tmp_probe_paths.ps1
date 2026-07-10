$paths = @(
    'C:\Users\lduan\tools\DumpViewer\DumpViewer.exe',
    'C:\Temp\2607030030000843',
    'C:\Users\lduan\sqlcsi-archive\reports\2607030030000843_dump_overall',
    'C:\Users\lduan\sqlcsi-archive\reports\2607030030000843_dump_code_analysis'
)

foreach ($p in $paths) {
    Write-Host "=== $p (exists=$(Test-Path $p)) ==="
    if (Test-Path $p) {
        if ((Get-Item $p).PSIsContainer) {
            Get-ChildItem $p -File -ErrorAction SilentlyContinue | Select-Object Name,Length,LastWriteTime | Format-Table -AutoSize | Out-String | Write-Host
            Get-ChildItem $p -Directory -ErrorAction SilentlyContinue | Select-Object Name | Format-Table -AutoSize | Out-String | Write-Host
        } else {
            (Get-Item $p) | Select-Object Name,Length,LastWriteTime | Format-List | Out-String | Write-Host
        }
    }
}

# Also check for any existing DumpViewer report for this dump anywhere.
Write-Host "=== search: DumpViewer reports ==="
$cands = @(
    "C:\Temp\2607030030000843\Reports",
    "C:\Users\lduan\sqlcsi-archive\reports\2607030030000843_dumpviewer",
    "C:\Users\lduan\tools\DumpViewer\Reports",
    "C:\Users\lduan\Downloads\Reports"
)
foreach ($c in $cands) { Write-Host ("{0,-70} {1}" -f $c, (Test-Path $c)) }
