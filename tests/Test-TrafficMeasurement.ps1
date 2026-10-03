#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\scripts\TrafficMeasurement.psm1') -Force

function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ($Actual -ne $Expected) {
        throw "$Message`: expected '$Expected', got '$Actual'."
    }
}

$state = New-TrafficState
$rows = @(Update-TrafficMeasurement $state @{
    Ethernet = @{ ReceivedBytes = 1000; SentBytes = 2000 }
    'Wi-Fi' = @{ ReceivedBytes = 500; SentBytes = 800 }
} 0)
Assert-Equal $rows.Count 2 'One row per adapter'
Assert-Equal $rows[0].SessionReceivedBytes 0 'Initial counters are not session traffic'

$rows = @(Update-TrafficMeasurement $state @{
    Ethernet = @{ ReceivedBytes = 1500; SentBytes = 2250 }
    'Wi-Fi' = @{ ReceivedBytes = 1500; SentBytes = 1300 }
} 2.5)
Assert-Equal $rows[0].ReceivedBytesPerSecond 200 'Rate uses actual elapsed time'
Assert-Equal $rows[0].SentBytesPerSecond 100 'Outgoing rate'
Assert-Equal $rows[1].SessionReceivedBytes 1000 'Independent adapter totals'

$rows = @(Update-TrafficMeasurement $state @{
    Ethernet = @{ ReceivedBytes = 20; SentBytes = 2450 }
} 3.5)
Assert-Equal $rows[0].CounterReset $true 'Reset is flagged'
Assert-Equal $rows[0].ReceivedBytesPerSecond 0 'Reset never produces negative or inflated traffic'
Assert-Equal $rows[0].SessionReceivedBytes 500 'Reset preserves accumulated totals'
Assert-Equal $rows[0].SentBytesPerSecond 200 'Unaffected counter still contributes'

$rows = @(Update-TrafficMeasurement $state @{} 4.5)
Assert-Equal $rows.Count 0 'No rows for disconnected adapters'
$rows = @(Update-TrafficMeasurement $state @{
    Ethernet = @{ ReceivedBytes = 9000; SentBytes = 9000 }
    'Wi-Fi' = @{ ReceivedBytes = 9000; SentBytes = 9000 }
} 5.5)
Assert-Equal $rows[0].ReceivedBytesPerSecond 0 'Reconnect establishes a fresh baseline'
Assert-Equal $rows[0].SessionReceivedBytes 500 'Reconnect keeps session totals'
Assert-Equal $rows[1].SessionReceivedBytes 1000 'Missing adapter keeps its totals'

$rows = @(Update-TrafficMeasurement $state @{
    Ethernet = @{ ReceivedBytes = 9125; SentBytes = 9250 }
    'Wi-Fi' = @{ ReceivedBytes = 9500; SentBytes = 9100 }
} 6.75)
Assert-Equal $rows[0].ReceivedBytesPerSecond 100 'Rates resume after reconnect'
Assert-Equal $rows[0].SessionReceivedBytes 625 'Session total is cumulative'

$largeState = New-TrafficState
$null = Update-TrafficMeasurement $largeState @{ Big = @{ ReceivedBytes = [decimal]'9007199254740993'; SentBytes = 0 } } 0
$row = Update-TrafficMeasurement $largeState @{ Big = @{ ReceivedBytes = [decimal]'9007199254740994'; SentBytes = 1 } } 1
Assert-Equal $row.ReceivedDeltaBytes 1 'Large counters retain exact byte differences'

$rejected = $false
try {
    $null = Update-TrafficMeasurement $largeState @{ Big = @{ ReceivedBytes = 1; SentBytes = 1 } } 1
}
catch { $rejected = $true }
Assert-Equal $rejected $true 'Non-increasing elapsed time is rejected'
Write-Host 'PASS: deterministic traffic accounting tests.'
