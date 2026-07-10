$h = Get-Content 'C:\Users\lduan\sqlcsi-archive\reports\2607030030000843_dump_overall\2607030030000843_overall_report.html' -Raw
Write-Host "bytes            = $($h.Length)"
Write-Host "external .html links (Reports\) = $(([regex]::Matches($h,'href=''[^'']*Reports')).Count)"
Write-Host "any file:// links = $(([regex]::Matches($h,'file://')).Count)"
Write-Host "inline thread <details class='thr' = $(([regex]::Matches($h,"details class='thr'")).Count)"
Write-Host "<pre> stacks     = $(([regex]::Matches($h,'<pre>')).Count)"
Write-Host "category anchors id='thr-<key>- = $(([regex]::Matches($h,"id='thr-[a-z]+-\d+'")).Count)"
Write-Host "table-2 chip links #thr-<key>- = $(([regex]::Matches($h,"href='#thr-[a-z]+-\d+'")).Count)"
Write-Host "old-style anchors id='thr-N' (should be 0) = $(([regex]::Matches($h,"id='thr-\d+'")).Count)"
# verify every chip target exists as an anchor
$targets = [regex]::Matches($h,"href='#(thr-[a-z]+-\d+)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
$anchors = [regex]::Matches($h,"id='(thr-[a-z]+-\d+)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
$missing = $targets | Where-Object { $_ -notin $anchors }
Write-Host "unique chip targets=$($targets.Count) unique anchors=$($anchors.Count) missing targets=$($missing.Count)"
if ($missing) { Write-Host "MISSING: $($missing -join ', ')" }
# duplicate anchor ids?
$allIds = [regex]::Matches($h,"id='(thr-[a-z]+-\d+)'") | ForEach-Object { $_.Groups[1].Value }
$dups = $allIds | Group-Object | Where-Object { $_.Count -gt 1 }
Write-Host "duplicate anchor ids = $($dups.Count)"
