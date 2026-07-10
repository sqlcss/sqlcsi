param([string]$Reports = 'C:\Users\lduan\sqlcsi-archive\reports\2607030030000843_dump_overall\dumpviewer_out\Reports')
$rows = @()
Get-ChildItem $Reports -Filter '*hread*.html' | ForEach-Object {
    $html = Get-Content $_.FullName -Raw
    $sc = [regex]::Match($html, "src='([^']*_json\.js)'").Groups[1].Value
    $title = [regex]::Match($html, "font-weight:bold'>([^<]+)<").Groups[1].Value
    $desc = [regex]::Match($html, "<div>([^<]+)</div>").Groups[1].Value
    $n = $null
    $cols = ''
    if ($sc -and (Test-Path (Join-Path $Reports $sc))) {
        $txt = Get-Content (Join-Path $Reports $sc) -Raw
        $n = ([regex]::Matches($txt, "(?m)^\s{2}\[")).Count
        $hdr = [regex]::Matches($txt, '\{"([a-z_]+)":\s*"(?:number|string)"\}')
        $cols = (($hdr | ForEach-Object { $_.Groups[1].Value }) -join ',')
    }
    $rows += [pscustomobject]@{ File = $_.Name; Title = $title; Desc = $desc; Sidecar = $sc; Rows = $n; Cols = $cols }
}
$rows | Sort-Object File | Format-Table File, Title, Rows, Cols -AutoSize -Wrap
