# =============================================================================
# SQL-CSI: XEL Extractor
# Extracts Extended Events from .xel binary files to JSON using Read-SqlXEvent.
# Auto-installs SqlServer PowerShell module if needed.
#
# Usage:
#   powershell -File extract_xel.ps1 -Path "system_health*.xel" -Output events.json
#   powershell -File extract_xel.ps1 -Path "C:\logs\*.xel" -Days 3
#   powershell -File extract_xel.ps1 -Path "\\server\share\*.xel" -Output events.json
# =============================================================================

param(
    [Parameter(Mandatory=$true)]
    [string]$Path,

    [Parameter(Mandatory=$false)]
    [string]$Output,

    [Parameter(Mandatory=$false)]
    [int]$Days = 0
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

# -----------------------------------------------------------------------------
# Step 3: Read XEL events
# -----------------------------------------------------------------------------
$allEvents = @()
$sourceFiles = @()

foreach ($xelFile in $resolvedFiles) {
    Write-Host "Reading $($xelFile.Name)..." -NoNewline
    $sourceFiles += $xelFile.Name

    try {
        $events = Read-SqlXEvent -FileName $xelFile.FullName
        $count = 0

        foreach ($evt in $events) {
            $count++

            # Build fields hashtable
            $fields = @{}
            foreach ($key in $evt.Fields.Keys) {
                $val = $evt.Fields[$key]
                # Convert to simple types for JSON serialization
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

            $allEvents += $eventObj
        }

        Write-Host " $count events" -ForegroundColor Green
    } catch {
        Write-Host " ERROR: $_" -ForegroundColor Red
    }
}

# -----------------------------------------------------------------------------
# Step 4: Apply time filter
# -----------------------------------------------------------------------------
if ($Days -gt 0 -and $allEvents.Count -gt 0) {
    # Find latest timestamp
    $latestStr = ($allEvents | Sort-Object { [DateTimeOffset]::Parse($_.timestamp) } | Select-Object -Last 1).timestamp
    $latest = [DateTimeOffset]::Parse($latestStr)
    $cutoff = $latest.AddDays(-$Days)

    $beforeCount = $allEvents.Count
    $allEvents = $allEvents | Where-Object {
        [DateTimeOffset]::Parse($_.timestamp) -ge $cutoff
    }

    Write-Host "Time filter: last $Days days (from $($cutoff.ToString('yyyy-MM-dd HH:mm:ss')))" -ForegroundColor Cyan
    Write-Host "Filtered: $beforeCount -> $($allEvents.Count) events" -ForegroundColor Cyan
}

# Sort by timestamp
$allEvents = $allEvents | Sort-Object { [DateTimeOffset]::Parse($_.timestamp) }

# -----------------------------------------------------------------------------
# Step 5: Build output JSON
# -----------------------------------------------------------------------------
$result = [PSCustomObject]@{
    extraction_date = (Get-Date).ToString('o')
    source_files    = $sourceFiles
    total_events    = $allEvents.Count
    events          = $allEvents
}

$json = $result | ConvertTo-Json -Depth 10 -Compress:$false

if ($Output) {
    $json | Set-Content -Path $Output -Encoding UTF8
    Write-Host "JSON output saved to $Output ($($allEvents.Count) events)" -ForegroundColor Green
} else {
    # Auto-generate output name
    $autoName = "xevent_extract_$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
    $json | Set-Content -Path $autoName -Encoding UTF8
    Write-Host "JSON output saved to $autoName ($($allEvents.Count) events)" -ForegroundColor Green
}

# Print summary
Write-Host "`n=== Event Type Summary ===" -ForegroundColor Cyan
$allEvents | Group-Object -Property name | Sort-Object Count -Descending | Format-Table Name, Count -AutoSize
