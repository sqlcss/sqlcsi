$el = 'C:\Temp\2607030030000843\ERRORLOG'
$b  = [System.IO.File]::ReadAllBytes($el)
$text = [System.Text.Encoding]::Unicode.GetString($b)
$lines = $text -split "`r?`n"
Write-Host "total lines: $($lines.Count)"

$patterns = @('latch','Timeout occurred','buffer latch','SQLDump','Non-yielding','A time-out','buflatch','BUFLATCH')
foreach ($p in $patterns) {
    $c = 0; foreach ($ln in $lines) { if ($ln -imatch [regex]::Escape($p)) { $c++ } }
    Write-Host ("{0,-30} {1}" -f $p, $c)
}
Write-Host "--- first 40 lines matching /latch/i ---"
$n=0
for ($i=0; $i -lt $lines.Count -and $n -lt 40; $i++) {
    if ($lines[$i] -imatch 'latch') { Write-Host "L$i : $($lines[$i])"; $n++ }
}
