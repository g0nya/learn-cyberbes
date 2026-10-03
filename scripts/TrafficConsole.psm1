function Format-TrafficAmount {
    param([double]$Bytes, [switch]$PerSecond)
    $units = @('Б', 'КиБ', 'МиБ', 'ГиБ', 'ТиБ')
    $index = 0
    while ($Bytes -ge 1024 -and $index -lt $units.Count - 1) {
        $Bytes /= 1024
        $index++
    }
    $suffix = if ($PerSecond) { '/с' } else { '' }
    return ('{0:N2} {1}{2}' -f $Bytes, $units[$index], $suffix)
}

function Test-TrafficStopKey {
    if ([Console]::IsInputRedirected) { return $false }
    while ([Console]::KeyAvailable) {
        $key = [Console]::ReadKey($true)
        if ($key.Key -eq [ConsoleKey]::Q -or $key.Key -eq [ConsoleKey]::Escape) {
            return $true
        }
    }
    return $false
}

function Wait-TrafficInterval {
    param([double]$Seconds)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($timer.Elapsed.TotalSeconds -lt $Seconds) {
        if (Test-TrafficStopKey) { return $true }
        $remaining = ($Seconds - $timer.Elapsed.TotalSeconds) * 1000
        Start-Sleep -Milliseconds ([int][math]::Max(1, [math]::Min(50, $remaining)))
    }
    return (Test-TrafficStopKey)
}

function Get-TrafficDashboardLines {
    param([object[]]$Rows, [string]$CsvPath, [string[]]$Warnings, [double]$IntervalSeconds)
    'СЕТЕВОЙ ТРАФИК  |  {0}' -f (Get-Date -Format 'HH:mm:ss')
    'Q / Esc — вернуться в меню   |   Обновление: {0} с' -f $IntervalSeconds
    'CSV: {0}' -f $(if ($CsvPath) { $CsvPath } else { 'выключен' })
    'Входящий = получено; исходящий = отправлено. Итоги за этот запуск.'
    ''
    if ($Rows.Count -eq 0) { 'Нет выбранных активных адаптеров. Ожидание подключения...' }
    foreach ($row in $Rows) {
        '[{0}]' -f $row.AdapterName
        '  ВХОДЯЩИЙ   {0,-18} Всего: {1}' -f (Format-TrafficAmount $row.ReceivedBytesPerSecond -PerSecond), (Format-TrafficAmount $row.SessionReceivedBytes)
        '  ИСХОДЯЩИЙ  {0,-18} Всего: {1}' -f (Format-TrafficAmount $row.SentBytesPerSecond -PerSecond), (Format-TrafficAmount $row.SessionSentBytes)
        if ($row.CounterReset) { '  Счётчик сброшен; прирост сброшенного направления пропущен.' }
        ''
    }
    foreach ($warning in $Warnings) { 'Предупреждение: {0}' -f $warning }
}

function Show-TrafficScreen {
    param([string[]]$Lines)
    # Clear and redraw a bounded frame; never let long names/paths wrap and scroll.
    Clear-Host
    $width = [math]::Max(10, $Host.UI.RawUI.WindowSize.Width - 1)
    $height = [math]::Max(3, $Host.UI.RawUI.WindowSize.Height - 1)
    $visible = @($Lines | Select-Object -First $height)
    if ($Lines.Count -gt $height) {
        $visible[$height - 1] = '... Увеличьте окно, чтобы видеть все адаптеры.'
    }
    foreach ($line in $visible) {
        if ($line.Length -gt $width) { $line = $line.Substring(0, $width - 1) + '…' }
        Write-Host $line
    }
}

function Start-TrafficMenu {
    param([scriptblock]$OnMonitor)
    $settings = @{ AdapterName = @(); IntervalSeconds = 1.0; CsvPath = $null }
    while ($true) {
        Clear-Host
        Write-Host 'СЕТЕВОЙ ТРАФИК — главное меню' -ForegroundColor Cyan
        Write-Host ''
        $names = if ($settings.AdapterName.Count) { $settings.AdapterName -join ', ' } else { 'все активные' }
        Write-Host "Адаптеры: $names"
        Write-Host "Интервал: $($settings.IntervalSeconds) с"
        $csvLabel = if ($settings.CsvPath) { $settings.CsvPath } else { 'выключен' }
        Write-Host "CSV: $csvLabel"
        Write-Host ''
        Write-Host '1  Начать мониторинг'
        Write-Host '2  Выбрать адаптеры'
        Write-Host '3  Настроить интервал'
        Write-Host '4  Запись CSV: включить / выключить'
        Write-Host '5  Справка'
        Write-Host '0  Выход'
        try {
            $choice = Read-Host 'Ваш выбор'
            switch ($choice) {
                '0' { return }
                '1' { & $OnMonitor $settings }
                '2' {
                    $adapters = @(Get-NetAdapter | Sort-Object Name)
                    Write-Host '0  Все активные адаптеры'
                    for ($i = 0; $i -lt $adapters.Count; $i++) {
                        Write-Host ('{0}  {1} ({2})' -f ($i + 1), $adapters[$i].Name, $adapters[$i].Status)
                    }
                    $answer = Read-Host 'Номера через запятую; Enter — отмена'
                    if ([string]::IsNullOrWhiteSpace($answer)) { break }
                    if ($answer.Trim() -eq '0') { $settings.AdapterName = @(); break }
                    $selected = @()
                    foreach ($part in ($answer -split ',')) {
                        $number = 0
                        if (-not [int]::TryParse($part.Trim(), [ref]$number) -or $number -lt 1 -or $number -gt $adapters.Count) {
                            throw 'Выберите номера из списка.'
                        }
                        $selected += $adapters[$number - 1].Name
                    }
                    $settings.AdapterName = @($selected | Select-Object -Unique)
                }
                '3' {
                    $answer = Read-Host 'Интервал от 0,1 до 3600 с; Enter — отмена'
                    if ([string]::IsNullOrWhiteSpace($answer)) { break }
                    $interval = 0.0
                    $normalized = $answer.Trim().Replace(',', '.')
                    if (-not [double]::TryParse($normalized, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$interval) -or [double]::IsNaN($interval) -or $interval -lt 0.1 -or $interval -gt 3600) {
                        throw 'Укажите число от 0,1 до 3600.'
                    }
                    $settings.IntervalSeconds = $interval
                }
                '4' {
                    if ($settings.CsvPath) { $settings.CsvPath = $null; break }
                    $answer = Read-Host 'Путь к новому CSV; Enter — отмена'
                    if (-not [string]::IsNullOrWhiteSpace($answer)) {
                        $path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($answer.Trim())
                        if (Test-Path -LiteralPath $path) { throw 'Файл уже существует. Укажите новое имя.' }
                        if (-not (Test-Path -LiteralPath (Split-Path -Parent $path) -PathType Container)) { throw 'Каталог не существует.' }
                        $settings.CsvPath = $path
                    }
                }
                '5' {
                    Write-Host 'Монитор читает системные счётчики активных сетевых адаптеров.'
                    Write-Host 'Скорость: Б/с, КиБ/с, МиБ/с; объём — с начала текущего запуска.'
                    Write-Host 'Q или Esc возвращает в меню. Каждый старт обнуляет итоги.'
                    Write-Host 'CSV: байты и байты/с. Для повторной записи укажите новый файл.'
                    Write-Host 'Это весь трафик интерфейса, включая локальную сеть; без разбивки по процессам.'
                    Write-Host 'Виртуальные интерфейсы могут учитывать один поток повторно.'
                    $null = Read-Host 'Enter — вернуться'
                }
                default { throw 'Выберите пункт от 0 до 5.' }
            }
        }
        catch {
            Write-Host ("Ошибка: {0}" -f $_.Exception.Message) -ForegroundColor Red
            $null = Read-Host 'Enter — вернуться в меню'
        }
    }
}

Export-ModuleMember -Function Format-TrafficAmount, Test-TrafficStopKey, Wait-TrafficInterval, Get-TrafficDashboardLines, Show-TrafficScreen, Start-TrafficMenu
