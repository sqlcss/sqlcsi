$dir  = 'C:\Users\lduan\sqlcsi-archive\reports\2607030030000843_dump_code_analysis'
$dvOverall = 'C:\Users\lduan\sqlcsi-archive\reports\2607030030000843_dump_overall'
$owner  = '25D5588BC28'
$waiter = '37A62DC4108'

foreach ($needle in @($owner, $waiter)) {
    Write-Host "==================== '$needle' ===================="
    foreach ($d in @($dir, $dvOverall)) {
        Get-ChildItem $d -File -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                $sr = Select-String -Path $_.FullName -Pattern $needle -SimpleMatch -CaseSensitive:$false -ErrorAction SilentlyContinue
                if ($sr) {
                    Write-Host "[$($_.Name)] $($sr.Count) hits"
                    $sr | Select-Object -First 4 | ForEach-Object {
                        $ln = $_.Line
                        if ($ln.Length -gt 260) { $ln = $ln.Substring(0,260) + '...' }
                        Write-Host ("  L{0} : {1}" -f $_.LineNumber, $ln)
                    }
                }
            } catch {}
        }
    }
    Write-Host ""
}
