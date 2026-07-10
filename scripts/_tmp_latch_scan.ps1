$ErrorActionPreference = 'Stop'
$out = 'C:\Users\lduan\sqlcsi-archive\reports\2607030030000843_latch_timeout'
New-Item -ItemType Directory -Force -Path $out | Out-Null

$el = 'C:\Temp\2607030030000843\ERRORLOG'
$b  = [System.IO.File]::ReadAllBytes($el)
$nz = 0; for ($i=1; $i -lt [Math]::Min($b.Length,400); $i+=2) { if ($b[$i] -eq 0) { $nz++ } }
$enc = if ($nz -gt 100) { [System.Text.Encoding]::Unicode } else { [System.Text.Encoding]::UTF8 }
Write-Host "encoding: $($enc.EncodingName)"

$text  = $enc.GetString($b)
$lines = $text -split "`r?`n"
Write-Host "total lines: $($lines.Count)"

$hits = @()
for ($i=0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match 'Timeout occurred while waiting for latch') { $hits += ,$i }
}
Write-Host "latch timeout hits: $($hits.Count)"
if ($hits.Count -eq 0) { return }
Write-Host ("first #{0} at line {1}" -f $hits[0], $hits[0])
Write-Host ("last  #{0} at line {1}" -f $hits[-1], $hits[-1])

$rx = 'Timeout occurred while waiting for latch: class ''([^'']+)'', id ([0-9A-Fa-fxX]+), type (\d+), Task (0x[0-9A-Fa-f]+) : (\d+), waittime (\d+) seconds, flags (0x[0-9A-Fa-f]+), owning task (0x[0-9A-Fa-f]+)'
$recs = @()
foreach ($h in $hits) {
    $ln = $lines[$h]
    # Extract leading timestamp/spid: e.g. "2026-07-02 12:08:50.70 spid87 ..."
    $tsMatch = [regex]::Match($ln, '^(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}(?:\.\d+)?)\s+(\w+)\s+')
    $ts   = if ($tsMatch.Success) { $tsMatch.Groups[1].Value } else { '' }
    $spid = if ($tsMatch.Success) { $tsMatch.Groups[2].Value } else { '' }
    $m = [regex]::Match($ln, $rx)
    if ($m.Success) {
        $recs += ,[pscustomobject]@{
            lineNum      = $h
            timestamp    = $ts
            spidText     = $spid
            latchClass   = $m.Groups[1].Value
            latchId      = $m.Groups[2].Value
            latchType    = [int]$m.Groups[3].Value
            waitingTask  = $m.Groups[4].Value
            threadNumber = [int]$m.Groups[5].Value
            waitTimeSec  = [int]$m.Groups[6].Value
            flags        = $m.Groups[7].Value
            owningTask   = $m.Groups[8].Value
            rawLine      = $ln
        }
    } else {
        $recs += ,[pscustomobject]@{ lineNum=$h; timestamp=$ts; spidText=$spid; parseFailed=$true; rawLine=$ln }
    }
}

$json = $recs | ConvertTo-Json -Depth 5
[System.IO.File]::WriteAllText((Join-Path $out '2607030030000843_latch_timeouts.json'), $json, (New-Object System.Text.UTF8Encoding($false)))

Write-Host "--- first hit raw ---"; Write-Host $lines[$hits[0]]
Write-Host "--- last hit raw ---";  Write-Host $lines[$hits[-1]]

# Aggregates
Write-Host ""
Write-Host "== unique latch class =="
$recs | Group-Object latchClass | Sort-Object Count -Descending | Select Count,Name | Format-Table -AutoSize | Out-String | Write-Host
Write-Host "== unique latch id =="
$recs | Group-Object latchId | Sort-Object Count -Descending | Select Count,Name | Format-Table -AutoSize | Out-String | Write-Host
Write-Host "== unique owning task =="
$recs | Group-Object owningTask | Sort-Object Count -Descending | Select Count,Name | Format-Table -AutoSize | Out-String | Write-Host
Write-Host "== unique spid text =="
$recs | Group-Object spidText | Sort-Object Count -Descending | Select Count,Name | Format-Table -AutoSize | Out-String | Write-Host
Write-Host "== flags distribution =="
$recs | Group-Object flags | Sort-Object Count -Descending | Select Count,Name | Format-Table -AutoSize | Out-String | Write-Host
Write-Host "== waittime distribution =="
$recs | Group-Object waitTimeSec | Sort-Object { [int]$_.Name } | Select Count,Name | Format-Table -AutoSize | Out-String | Write-Host
Write-Host "== timestamps (min/max) =="
$sorted = $recs | Where-Object timestamp | Sort-Object timestamp
if ($sorted) { Write-Host ("min={0}  max={1}" -f $sorted[0].timestamp, $sorted[-1].timestamp) }
Write-Host "== thread numbers (top 20) =="
$recs | Group-Object threadNumber | Sort-Object { [int]$_.Name } | Select -First 20 Count,Name | Format-Table -AutoSize | Out-String | Write-Host

# Also look around the first hit for Input Buffer, dump path etc.
$window = @()
for ($i = [Math]::Max(0,$hits[0]-40); $i -le [Math]::Min($lines.Count-1,$hits[-1]+80); $i++) { $window += ,$lines[$i] }
[System.IO.File]::WriteAllText((Join-Path $out '_errorlog_latch_window.txt'), ($window -join "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
Write-Host "wrote _errorlog_latch_window.txt ($($window.Count) lines)"
