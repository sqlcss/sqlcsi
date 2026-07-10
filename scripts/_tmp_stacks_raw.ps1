$el = 'C:\Temp\2607030030000843\ERRORLOG'
$lines = ([System.Text.Encoding]::Unicode.GetString([System.IO.File]::ReadAllBytes($el))) -split "`r?`n"
# Print raw window around L3282 for stacks
Write-Host "== raw ERRORLOG lines 3282..3402 (waiter timeout + stacks) =="
for ($i=3282; $i -le 3402 -and $i -lt $lines.Count; $i++) {
    Write-Host ("L{0} : {1}" -f $i, $lines[$i])
}
