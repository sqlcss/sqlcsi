$ErrorActionPreference='Stop'
$dump='C:\Temp\2607030030000843\SQLDump0001.mdmp'
$out='C:\Users\lduan\sqlcsi-archive\reports\2607030030000843_dump_overall\txt_detail\2607030030000843_thr324_stack.txt'
$wds=Join-Path $env:TEMP '_thr324.wds'
$appx=Get-AppxPackage *WinDbg* | Sort-Object Version -Descending | Select-Object -First 1
$cdb=Join-Path $appx.InstallLocation 'amd64\cdb.exe'
$body=@(
 ".logopen `"$out`""
 "~324 s"
 ".echo ===STACK==="
 "kn 60"
 ".logclose"
 "q"
) -join "`r`n"
[IO.File]::WriteAllText($wds,$body,(New-Object Text.UTF8Encoding($false)))
& $cdb -y 'srv*C:\Symbols*https://symweb.azurefd.net' -z $dump -c "`$`$><$wds" *> (Join-Path $env:TEMP '_thr324b.console.txt')
Get-Content $out -Raw
