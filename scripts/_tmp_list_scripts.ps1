$ErrorActionPreference = 'Stop'
$dll = 'C:\Temp\2606250030005483\Log\LOG\SqlCsScripts.dll'
Add-Type -Path 'C:\Users\lduan\tools\DumpViewer\CsDebugScript.Engine.dll' -ErrorAction SilentlyContinue

# Resolve sibling deps (SqlDebugTypes.dll, CsDebugScript.*) from these dirs
$probe = @('C:\Temp\2606250030005483\Log\LOG', 'C:\Users\lduan\tools\DumpViewer')
$onResolve = {
    param($s, $e)
    $name = (New-Object System.Reflection.AssemblyName($e.Name)).Name
    foreach ($d in $probe) {
        foreach ($ext in @('.dll', '.exe')) {
            $p = Join-Path $d ($name + $ext)
            if (Test-Path $p) { return [System.Reflection.Assembly]::LoadFrom($p) }
        }
    }
    return $null
}
[System.AppDomain]::CurrentDomain.add_AssemblyResolve($onResolve)

$asm = [System.Reflection.Assembly]::LoadFrom($dll)
$flags = [System.Reflection.BindingFlags]::Public -bor [System.Reflection.BindingFlags]::Static

$rows = New-Object System.Collections.Generic.List[object]
foreach ($t in $asm.GetTypes()) {
    if (-not $t.IsClass) { continue }
    $methods = $t.GetMethods($flags) | Where-Object {
        $_.GetParameters().Count -eq 0 -and -not $_.IsSpecialName -and $_.DeclaringType -eq $t
    }
    foreach ($m in $methods) {
        $rows.Add([pscustomobject]@{
            Class  = $t.Name
            Method = $m.Name
            Ret    = $m.ReturnType.Name
        })
    }
}

$rows | Sort-Object Class, Method | Group-Object Class | ForEach-Object {
    Write-Host ""
    Write-Host ("=== " + $_.Name + " ===") -ForegroundColor Cyan
    $_.Group | ForEach-Object { Write-Host ("  {0}.{1}   -> {2}" -f $_.Class, $_.Method, $_.Ret) }
}
Write-Host ""
Write-Host ("TOTAL runnable Class.Method: " + $rows.Count) -ForegroundColor Green
