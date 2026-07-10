$el = 'C:\Temp\2607030030000843\ERRORLOG'
$lines = ([System.Text.Encoding]::Unicode.GetString([System.IO.File]::ReadAllBytes($el))) -split "`r?`n"

$out = 'C:\Users\lduan\sqlcsi-archive\reports\2607030030000843_latch_timeout'
New-Item -ItemType Directory -Force -Path $out | Out-Null

# ---- Save full ±80 line window around every buffer-latch timeout ----
$hits = @()
for ($i=0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -imatch 'buffer latch') { $hits += ,$i }
}
Write-Host "buffer-latch hits: $($hits.Count)"

$loMin = ($hits | Measure-Object -Minimum).Minimum
$loMax = ($hits | Measure-Object -Maximum).Maximum
$lo = [Math]::Max(0, $loMin - 20)
$hi = [Math]::Min($lines.Count-1, $loMax + 200)
Write-Host "window: L$lo .. L$hi"
$window = for ($i=$lo; $i -le $hi; $i++) { "L{0,-5} : {1}" -f $i, $lines[$i] }
[System.IO.File]::WriteAllText((Join-Path $out '_errorlog_latch_window.txt'), ($window -join "`r`n"), (New-Object System.Text.UTF8Encoding($false)))

# ---- also probe: what does spid72s do around the crash? ----
Write-Host "--- spid72s activity ±5 min ---"
$c = 0
for ($i=0; $i -lt $lines.Count -and $c -lt 60; $i++) {
    if ($lines[$i] -match '^\S+\s+\S+\s+spid72s\b') { Write-Host "L$i : $($lines[$i])"; $c++ }
}

# ---- probe for other diagnostic lines around 12:08 ----
Write-Host "--- ALL lines 12:08:4x  through 12:09:3x ---"
$c = 0
for ($i=0; $i -lt $lines.Count -and $c -lt 80; $i++) {
    if ($lines[$i] -match '^2026-07-02\s+12:0[89]:') { Write-Host "L$i : $($lines[$i])"; $c++ }
}

# ---- Stack Dump / SQLDump breadcrumb ----
Write-Host "--- SQLDump / stack dump references ---"
for ($i=0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -imatch 'sqldump|stack dump|process/thread|BEGIN STACK DUMP|Latch timeout') {
        Write-Host "L$i : $($lines[$i])"
    }
}
