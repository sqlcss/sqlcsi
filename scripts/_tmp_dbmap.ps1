$el = 'C:\Temp\2607030030000843\ERRORLOG'
$lines = ([System.Text.Encoding]::Unicode.GetString([System.IO.File]::ReadAllBytes($el))) -split "`r?`n"
Write-Host "== 'Starting up database' events =="
for ($i=0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match 'Starting up database') {
        Write-Host ("L{0} : {1}" -f $i, $lines[$i])
    }
}
Write-Host ""
Write-Host "== 'database ID' / 'dbid' / 'FILE'/'file id' near latch time =="
for ($i=3200; $i -le 3600; $i++) {
    if ($lines[$i] -match 'database|dbid|Alloc.*Unit|allocation|3:819477|819477') {
        Write-Host ("L{0} : {1}" -f $i, $lines[$i])
    }
}
Write-Host ""
Write-Host "== TestSimulation occurrences =="
$c=0
for ($i=0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match 'TestSimulation') {
        Write-Host ("L{0} : {1}" -f $i, $lines[$i]); $c++
        if ($c -ge 10) { break }
    }
}
Write-Host ""
Write-Host "== recovery/DB open lines (first 200 lines of log) =="
for ($i=0; $i -lt 300 -and $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match 'database|db_id|VLF|recovery|Analysis|Starting|Redo') {
        Write-Host ("L{0} : {1}" -f $i, $lines[$i])
    }
}
