# =============================================================================
# SQL-CSI: XEL Extractor
# Extracts Extended Events from .xel binary files to JSON using Read-SqlXEvent.
# Auto-installs SqlServer PowerShell module if needed.
#
# Usage:
#   powershell -File extract_xel.ps1 -Path "system_health*.xel" -Output events.json
#   powershell -File extract_xel.ps1 -Path "C:\logs\*.xel" -Days 3
#   powershell -File extract_xel.ps1 -Path "*.xel" -Days 7 -EventName error_reported,wait_info,sp_server_diagnostics_component_result
#   powershell -File extract_xel.ps1 -Path "\\server\share\*.xel" -Output events.json
# =============================================================================

param(
    [Parameter(Mandatory=$true)]
    [string]$Path,

    [Parameter(Mandatory=$false)]
    [string]$Output,

    [Parameter(Mandatory=$false)]
    [int]$Days = 0,

    [Parameter(Mandatory=$false)]
    [string[]]$EventName = @()
)

$ErrorActionPreference = 'Stop'

# -----------------------------------------------------------------------------
# Step 1: Ensure SqlServer module is available
# -----------------------------------------------------------------------------
if (-not (Get-Module -ListAvailable -Name SqlServer)) {
    Write-Host "SqlServer module not found. Installing..." -ForegroundColor Yellow
    try {
        Install-Module SqlServer -Scope CurrentUser -Force -AllowClobber
        Write-Host "SqlServer module installed successfully." -ForegroundColor Green
    } catch {
        Write-Error "Failed to install SqlServer module: $_"
        Write-Error "Run manually: Install-Module SqlServer -Scope CurrentUser -Force"
        exit 1
    }
}

Import-Module SqlServer -ErrorAction Stop

# -----------------------------------------------------------------------------
# Step 2: Resolve file paths
# -----------------------------------------------------------------------------
$resolvedFiles = @()

# Handle glob patterns
if ($Path -match '\*') {
    $dir = Split-Path $Path -Parent
    $filter = Split-Path $Path -Leaf
    if (-not $dir) { $dir = '.' }
    $resolvedFiles = Get-ChildItem -Path $dir -Filter $filter -File | Sort-Object Name
} else {
    if (Test-Path $Path) {
        $resolvedFiles = @(Get-Item $Path)
    } else {
        Write-Error "File not found: $Path"
        exit 1
    }
}

if ($resolvedFiles.Count -eq 0) {
    Write-Error "No .xel files found matching: $Path"
    exit 1
}

Write-Host "Found $($resolvedFiles.Count) XEL file(s):" -ForegroundColor Cyan
foreach ($f in $resolvedFiles) {
    $sizeMB = [math]::Round($f.Length / 1MB, 2)
    Write-Host "  $($f.Name) ($sizeMB MB)"
}

# Build EventName hash set for fast lookup
# Handle comma-separated strings (powershell -File passes "a,b,c" as one string)
$eventFilter = @{}
foreach ($en in $EventName) {
    foreach ($part in ($en -split ',')) {
        $trimmed = $part.Trim()
        if ($trimmed) { $eventFilter[$trimmed] = $true }
    }
}
$hasEventFilter = $eventFilter.Count -gt 0

if ($hasEventFilter) {
    Write-Host "Event filter: $($EventName -join ', ')" -ForegroundColor Cyan
}

# -----------------------------------------------------------------------------
# Step 3: Pre-scan for latest timestamp (if -Days specified)
# -----------------------------------------------------------------------------
$cutoff = $null
if ($Days -gt 0) {
    Write-Host "Pre-scanning for latest timestamp (fast pass)..." -ForegroundColor Cyan
    $latestTs = [DateTimeOffset]::MinValue
    foreach ($xelFile in $resolvedFiles) {
        $events = Read-SqlXEvent -FileName $xelFile.FullName
        foreach ($evt in $events) {
            if ($evt.Timestamp -gt $latestTs) { $latestTs = $evt.Timestamp }
        }
    }
    $cutoff = $latestTs.AddDays(-$Days)
    Write-Host "Latest event: $($latestTs.ToString('yyyy-MM-dd HH:mm:ss.fff zzz'))" -ForegroundColor Cyan
    Write-Host "Cutoff (-$Days d): $($cutoff.ToString('yyyy-MM-dd HH:mm:ss.fff zzz'))" -ForegroundColor Cyan
}

# -----------------------------------------------------------------------------
# Step 4: Read XEL events with early filtering
# -----------------------------------------------------------------------------
$allEvents = [System.Collections.Generic.List[PSCustomObject]]::new()
$sourceFiles = @()
$totalRead = 0
$totalSkipped = 0

foreach ($xelFile in $resolvedFiles) {
    Write-Host "Reading $($xelFile.Name)..." -NoNewline
    $sourceFiles += $xelFile.Name
    $fileKept = 0
    $fileSkipped = 0

    try {
        $events = Read-SqlXEvent -FileName $xelFile.FullName

        foreach ($evt in $events) {
            $totalRead++

            # --- Early filter: event name ---
            if ($hasEventFilter -and -not $eventFilter.ContainsKey($evt.Name)) {
                $fileSkipped++; $totalSkipped++; continue
            }

            # --- Early filter: time cutoff ---
            if ($null -ne $cutoff -and $evt.Timestamp -lt $cutoff) {
                $fileSkipped++; $totalSkipped++; continue
            }

            # --- Build fields hashtable (only for kept events) ---
            $fields = @{}
            foreach ($key in $evt.Fields.Keys) {
                $val = $evt.Fields[$key]
                if ($val -is [System.DateTimeOffset]) {
                    $fields[$key] = $val.ToString('o')
                } elseif ($val -is [System.DateTime]) {
                    $fields[$key] = $val.ToString('o')
                } elseif ($val -is [byte[]]) {
                    $fields[$key] = [Convert]::ToBase64String($val)
                } else {
                    $fields[$key] = $val
                }
            }

            # Build actions hashtable
            $actions = @{}
            foreach ($key in $evt.Actions.Keys) {
                $val = $evt.Actions[$key]
                if ($val -is [System.DateTimeOffset]) {
                    $actions[$key] = $val.ToString('o')
                } elseif ($val -is [System.DateTime]) {
                    $actions[$key] = $val.ToString('o')
                } elseif ($val -is [byte[]]) {
                    $actions[$key] = [Convert]::ToBase64String($val)
                } else {
                    $actions[$key] = $val
                }
            }

            $eventObj = [PSCustomObject]@{
                name      = $evt.Name
                timestamp = $evt.Timestamp.ToString('o')
                fields    = $fields
                actions   = $actions
            }

            $allEvents.Add($eventObj)
            $fileKept++
        }

        Write-Host " $fileKept kept, $fileSkipped skipped" -ForegroundColor Green
    } catch {
        Write-Host " ERROR: $_" -ForegroundColor Red
    }
}

Write-Host "`nTotal: $totalRead read, $totalSkipped skipped, $($allEvents.Count) kept" -ForegroundColor Cyan

# Sort by timestamp
$sorted = $allEvents | Sort-Object { [DateTimeOffset]::Parse($_.timestamp) }

# -----------------------------------------------------------------------------
# Step 5: Build output JSON
# -----------------------------------------------------------------------------
$result = [PSCustomObject]@{
    extraction_date = (Get-Date).ToString('o')
    source_files    = $sourceFiles
    total_events    = @($sorted).Count
    events          = @($sorted)
}

$json = $result | ConvertTo-Json -Depth 10 -Compress:$false

if ($Output) {
    $json | Set-Content -Path $Output -Encoding UTF8
    Write-Host "JSON output saved to $Output ($(@($sorted).Count) events)" -ForegroundColor Green
} else {
    # Auto-generate output name
    $autoName = "xevent_extract_$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
    $json | Set-Content -Path $autoName -Encoding UTF8
    Write-Host "JSON output saved to $autoName ($(@($sorted).Count) events)" -ForegroundColor Green
}

# Print summary
Write-Host "`n=== Event Type Summary ===" -ForegroundColor Cyan
$allEvents | Group-Object -Property name | Sort-Object Count -Descending | Format-Table Name, Count -AutoSize
