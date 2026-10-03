#Requires -Version 5.1
<#
.SYNOPSIS
Shows incoming/outgoing adapter traffic on Windows, optionally recording CSV.
.EXAMPLE
.\Watch-NetworkTraffic.ps1 -AdapterName 'Wi-Fi' -IntervalSeconds 1 -SampleCount 10
#>
[CmdletBinding()]
param(
    [string[]]$AdapterName,
    [ValidateRange(0.1, 3600)][double]$IntervalSeconds = 1,
    [ValidateRange(0, 2147483647)][int]$SampleCount = 0,
    [string]$CsvPath
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'TrafficMeasurement.psm1') -Force
foreach ($command in @('Get-NetAdapter', 'Get-NetAdapterStatistics')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "Required Windows command '$command' is unavailable. Run this script on Windows 11."
    }
}

$initialAdapters = @(Get-NetAdapter)
if ($AdapterName) {
    foreach ($name in $AdapterName) {
        if (-not ($initialAdapters | Where-Object { $_.Name -eq $name })) {
            throw "Adapter '$name' was not found. List names with Get-NetAdapter."
        }
    }
}

if ($CsvPath) {
    $CsvPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($CsvPath)
    if (Test-Path -LiteralPath $CsvPath) {
        throw "CSV path already exists: $CsvPath. Choose a new file."
    }
    $parent = Split-Path -Parent $CsvPath
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        throw "CSV directory does not exist: $parent"
    }
}

function Read-AdapterCounters {
    $counters = @{}
    # Discover each time so newly connected adapters join the default view.
    $adapters = @(Get-NetAdapter | Where-Object {
        $_.Status -eq 'Up' -and (-not $AdapterName -or $_.Name -in $AdapterName)
    })
    foreach ($adapter in $adapters) {
        try {
            $stats = $adapter | Get-NetAdapterStatistics
            if ($null -eq $stats.ReceivedBytes -or $null -eq $stats.SentBytes) {
                throw 'Byte counters are missing.'
            }
            $counters[$adapter.Name] = @{
                ReceivedBytes = $stats.ReceivedBytes
                SentBytes = $stats.SentBytes
            }
        }
        catch {
            # An adapter can disappear between discovery and reading counters.
            Write-Warning "Cannot read adapter '$($adapter.Name)': $($_.Exception.Message)"
        }
    }
    return $counters
}

$state = New-TrafficState
$clock = [System.Diagnostics.Stopwatch]::StartNew()
$baseline = Read-AdapterCounters
$null = Update-TrafficMeasurement -State $state -Counters $baseline -ElapsedSeconds $clock.Elapsed.TotalSeconds
$samples = 0
$csvStarted = $false
Write-Host 'Incoming / outgoing adapter traffic. Stop with Ctrl+C. Rates: KiB/s; totals: MiB.'
try {
    while ($SampleCount -eq 0 -or $samples -lt $SampleCount) {
        Start-Sleep -Milliseconds ([int][math]::Round($IntervalSeconds * 1000))
        $counters = Read-AdapterCounters
        $rows = @(Update-TrafficMeasurement -State $state -Counters $counters -ElapsedSeconds $clock.Elapsed.TotalSeconds)
        Write-Host (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        if ($rows.Count -eq 0) {
            Write-Host 'No selected adapters are currently Up.'
        }
        else {
            $display = $rows | Select-Object AdapterName,
                @{Name = 'In KiB/s'; Expression = { [math]::Round($_.ReceivedBytesPerSecond / 1KB, 2) }},
                @{Name = 'Out KiB/s'; Expression = { [math]::Round($_.SentBytesPerSecond / 1KB, 2) }},
                @{Name = 'In MiB'; Expression = { [math]::Round($_.SessionReceivedBytes / 1MB, 3) }},
                @{Name = 'Out MiB'; Expression = { [math]::Round($_.SessionSentBytes / 1MB, 3) }}, CounterReset
            Write-Host ($display | Format-Table -AutoSize | Out-String)
            if ($CsvPath) {
                if ($csvStarted) {
                    $rows | Export-Csv -LiteralPath $CsvPath -NoTypeInformation -Encoding UTF8 -Append
                }
                else {
                    $rows | Export-Csv -LiteralPath $CsvPath -NoTypeInformation -Encoding UTF8
                    $csvStarted = $true
                }
            }
        }
        $samples++
    }
}
finally {
    $clock.Stop()
}
