$ErrorActionPreference = 'Continue'
$outDir = 'C:\Users\lduan\sqlcsi-archive\reports\2607030030000843_latch_timeout'
$dump   = 'C:\Temp\2607030030000843\SQLDump0001.mdmp'
$cdb    = 'C:\Program Files\WindowsApps\Microsoft.WinDbg.Slow_1.2606.22001.1_x64__8wekyb3d8bbwe\amd64\cdb.exe'
Write-Host "cdb = $cdb"
if (-not (Test-Path -LiteralPath $cdb)) { Write-Host "cdb.exe NOT FOUND"; exit 1 }
if (-not (Test-Path -LiteralPath $dump)) { Write-Host "dump NOT FOUND"; exit 1 }

# Frame addresses (raw addresses from ERRORLOG). Waiter frames 00-20, Owner frames 00-39.
$waiter = @(
    '0x7FFE9E2633A5','0x7FFE9E26289D','0x7FFE9CDB96F9','0x7FFE9CDBB710','0x7FFE9CF5C6E8',
    '0x7FFE9CF5CBB3','0x7FFE9CF5D5D7','0x7FFE9E0DF9AB','0x7FFE9E0E1686','0x7FFE9E0E20C7',
    '0x7FFE9E0DDE2A','0x7FFE9E0E326C','0x7FFE99897DAB','0x7FFE99897AA5','0x7FFE99897804',
    '0x7FFE998B8023','0x7FFE998B80CC','0x7FFE998B8632','0x7FFE998B8376','0x7FFEC3807AC4',
    '0x7FFEC5C8A8C1'
)
$owner = @(
    '0x7FFEC5CD03F4','0x7FFEC1CAA24D','0x7FFE9CDD56CE','0x7FFE9CDD54FE','0x7FFE9CDD5C9A',
    '0x7FFE9CDD592A','0x7FFE9CDDDB49','0x7FFE9E62CE55','0x7FFE9CDCE506','0x7FFE9CDCF100',
    '0x7FFE9CDEF8C0','0x7FFE9CDEDBA4','0x7FFE9CE23B78','0x7FFE9CDF61BD','0x7FFE9CDF2043',
    '0x7FFE9E34221F','0x7FFE9E3416A0','0x7FFE9E341783','0x7FFE9E32750F','0x7FFE9E324FFD',
    '0x7FFE9DD956AB','0x7FFE9CDED25D','0x7FFE9CDECBC1','0x7FFE9CDF0177','0x7FFE9CDD4551',
    '0x7FFE9CDD3E1E','0x7FFE9CDD21C2','0x7FFE9CDE1249','0x7FFE9FFD3487','0x7FFE9CDE34D0',
    '0x7FFE9CDA7E39','0x7FFE9CDA7E39','0x7FFE9CDC0DFF','0x7FFE99EBD79D','0x7FFE99ED81FC',
    '0x7FFE99ED7F5A','0x7FFE99EB6D7F','0x7FFE99EB71CC','0x7FFE9ED9C03F'
)
$shortStack = @(
    '0x7FFEC1CC1B39','0x7FFE9B1EECBE','0x7FFE9B1F2CE5','0x7FFE9E264827','0x7FFE9E2634DF'
)

$cmds = @()
$cmds += '.sympath srv*C:\Symbols*https://symweb.azurefd.net'
$cmds += '.symfix+ C:\Symbols'
$cmds += '.reload'
$cmds += '.echo === MODULES ==='
$cmds += 'lm m sqlmin'
$cmds += 'lm m sqllang'
$cmds += 'lm m SqlDK'
$cmds += 'lm m SqlTsEs'
$cmds += 'lm m sqlservr'
$cmds += 'lm m kernelbase'
$cmds += 'lm m ntdll'
$cmds += '.echo === WAITER STACK (spid72s task 0x37A62DC4108) ==='
for ($i=0; $i -lt $waiter.Count; $i++) { $cmds += ('.echo -- W{0:D2} --' -f $i); $cmds += ('ln ' + $waiter[$i]) }
$cmds += '.echo === OWNER STACK (task 0x25D5588BC28 / SPID 98) ==='
for ($i=0; $i -lt $owner.Count; $i++) { $cmds += ('.echo -- O{0:D2} --' -f $i); $cmds += ('ln ' + $owner[$i]) }
$cmds += '.echo === SHORT STACK (dumper) ==='
for ($i=0; $i -lt $shortStack.Count; $i++) { $cmds += ('.echo -- S{0:D2} --' -f $i); $cmds += ('ln ' + $shortStack[$i]) }
$cmds += 'q'

$cmdFile = Join-Path $outDir '_symbolize.cdb'
Set-Content -LiteralPath $cmdFile -Value ($cmds -join "`r`n") -Encoding ASCII
Write-Host "Wrote command file: $cmdFile"

$logFile = Join-Path $outDir '_symbolize.log'
if (Test-Path $logFile) { Remove-Item $logFile -Force }

$arglist = @('-z', $dump, '-lines', '-logo', $logFile, '-cf', $cmdFile)
Write-Host "Running: cdb $($arglist -join ' ')"
& $cdb @arglist 2>&1 | Out-Null
Write-Host "== log length: $((Get-Item $logFile).Length) bytes =="
