# Pure counter accounting, separate from Windows adapter discovery and display.
function New-TrafficState {
    [CmdletBinding()]
    param()
    return @{ Adapters = @{} }
}

function Update-TrafficMeasurement {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$State,
        [Parameter(Mandatory = $true)][hashtable]$Counters,
        [Parameter(Mandatory = $true)][double]$ElapsedSeconds,
        [datetime]$Timestamp = (Get-Date)
    )

    foreach ($name in @($State.Adapters.Keys)) {
        if (-not $Counters.ContainsKey($name)) {
            # Keep totals but discard the baseline across a disconnect.
            $State.Adapters[$name].HasBaseline = $false
        }
    }

    foreach ($name in @($Counters.Keys | Sort-Object)) {
        $received = [decimal]$Counters[$name].ReceivedBytes
        $sent = [decimal]$Counters[$name].SentBytes
        if ($received -lt 0 -or $sent -lt 0) {
            throw "Adapter '$name' returned a negative byte counter."
        }
        if (-not $State.Adapters.ContainsKey($name)) {
            $State.Adapters[$name] = @{
                HasBaseline = $false
                ReceivedTotal = [decimal]0
                SentTotal = [decimal]0
            }
        }
        $previous = $State.Adapters[$name]
        $receivedDelta = [decimal]0
        $sentDelta = [decimal]0
        $receivedRate = [double]0
        $sentRate = [double]0
        $reset = $false
        if ($previous.HasBaseline) {
            $interval = $ElapsedSeconds - $previous.ElapsedSeconds
            if ($interval -le 0) {
                throw 'ElapsedSeconds must increase between samples.'
            }
            $reset = ($received -lt $previous.ReceivedBytes -or $sent -lt $previous.SentBytes)
            # A decreased counter has no trustworthy delta for this interval.
            if ($received -ge $previous.ReceivedBytes) {
                $receivedDelta = $received - $previous.ReceivedBytes
            }
            if ($sent -ge $previous.SentBytes) {
                $sentDelta = $sent - $previous.SentBytes
            }
            $receivedRate = [double]$receivedDelta / $interval
            $sentRate = [double]$sentDelta / $interval
        }
        $previous.ReceivedTotal += $receivedDelta
        $previous.SentTotal += $sentDelta
        $previous.ReceivedBytes = $received
        $previous.SentBytes = $sent
        $previous.ElapsedSeconds = $ElapsedSeconds
        $previous.HasBaseline = $true

        [pscustomobject][ordered]@{
            Timestamp = $Timestamp.ToString('o')
            AdapterName = $name
            ReceivedBytesPerSecond = $receivedRate
            SentBytesPerSecond = $sentRate
            SessionReceivedBytes = $previous.ReceivedTotal
            SessionSentBytes = $previous.SentTotal
            ReceivedDeltaBytes = $receivedDelta
            SentDeltaBytes = $sentDelta
            CounterReset = $reset
        }
    }
}

Export-ModuleMember -Function New-TrafficState, Update-TrafficMeasurement
