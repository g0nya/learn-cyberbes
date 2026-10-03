#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\scripts\TrafficConsole.psm1') -Force

if ((Format-TrafficAmount 1024 -PerSecond) -notmatch '1.+КиБ/с$') { throw 'KiB/s formatting failed.' }
if ((Format-TrafficAmount 1048576) -notmatch '1.+МиБ$') { throw 'MiB formatting failed.' }
if ((Format-TrafficAmount 0) -notmatch 'Б$') { throw 'Zero-byte formatting failed.' }
$rows = @([pscustomobject]@{
    AdapterName = 'Тест'; ReceivedBytesPerSecond = 2048; SentBytesPerSecond = 1048576
    SessionReceivedBytes = 4096; SessionSentBytes = 1073741824; CounterReset = $true
})
$frame = (Get-TrafficDashboardLines -Rows $rows -IntervalSeconds 1) -join "`n"
foreach ($text in @('Тест', 'ВХОДЯЩИЙ', 'ИСХОДЯЩИЙ', 'Всего:', 'КиБ/с', 'МиБ/с', 'ГиБ', 'сброшен', 'Q / Esc')) {
    if (-not $frame.Contains($text)) { throw "Dashboard is missing '$text'." }
}
$emptyFrame = (Get-TrafficDashboardLines -Rows @() -IntervalSeconds 1) -join "`n"
if (-not $emptyFrame.Contains('Ожидание подключения')) { throw 'Disconnected state is missing.' }

$testCsv = Join-Path ([IO.Path]::GetTempPath()) ('traffic-menu-test-' + [guid]::NewGuid().ToString('N') + '.csv')
& (Get-Module TrafficConsole) {
    param($testCsv)
    # Module-local mocks exercise the real menu loop without changing the console.
    $script:Answers = New-Object 'Collections.Generic.Queue[string]'
    foreach ($answer in @('2', '2', '3', 'bad', '', '3', '0,25', '4', $testCsv, '1', '4', '2', '0', '1', '5', '', '0')) {
        $script:Answers.Enqueue($answer)
    }
    $script:Snapshots = @()
    $script:Messages = @()
    function script:Read-Host {
        param([string]$Prompt)
        if ($script:Answers.Count -eq 0) { throw 'Unexpected additional prompt.' }
        return $script:Answers.Dequeue()
    }
    function script:Clear-Host {}
    function script:Write-Host {
        param($Object, $ForegroundColor)
        $script:Messages += [string]$Object
    }
    function script:Get-NetAdapter {
        [pscustomobject]@{ Name = 'Ethernet'; Status = 'Up' }
        [pscustomobject]@{ Name = 'Wi-Fi'; Status = 'Down' }
    }
    Start-TrafficMenu -OnMonitor {
        param($settings)
        $script:Snapshots += [pscustomobject]@{
            AdapterName = @($settings.AdapterName)
            IntervalSeconds = $settings.IntervalSeconds
            CsvPath = $settings.CsvPath
        }
    }
    if ($script:Answers.Count -ne 0 -or $script:Snapshots.Count -ne 2) { throw 'Menu start/exit navigation failed.' }
    if ($script:Snapshots[0].AdapterName[0] -ne 'Wi-Fi') { throw 'Adapter selection failed.' }
    if ($script:Snapshots[0].IntervalSeconds -ne 0.25) { throw 'Russian decimal interval failed.' }
    if ($script:Snapshots[0].CsvPath -ne $testCsv) { throw 'CSV enable failed.' }
    if ($script:Snapshots[1].AdapterName.Count -ne 0 -or $script:Snapshots[1].CsvPath) { throw 'All adapters / CSV disable failed.' }
    if (-not (($script:Messages -join "`n").Contains('Ошибка:'))) { throw 'Invalid input was not shown safely.' }
    if (-not (($script:Messages -join "`n").Contains('без разбивки по процессам'))) { throw 'Help navigation failed.' }
    function script:Test-TrafficStopKey { return $true }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    if (-not (Wait-TrafficInterval 3600) -or $timer.Elapsed.TotalSeconds -gt 0.2) { throw 'Stop key does not interrupt a long interval.' }
} $testCsv
# Discard all module-local mocks.
Remove-Module TrafficConsole
Write-Host 'PASS: console formatting, menu navigation/settings/errors/help, responsive wait.'
