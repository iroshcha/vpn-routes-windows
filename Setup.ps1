param([ValidateSet('Install', 'Uninstall', 'Export')][string]$Mode = 'Install')

$ErrorActionPreference = 'Stop'
$root = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'CodexVpnRouteGuard'
$settingsFile = Join-Path $PSScriptRoot 'VPN-Routes-settings.json'
$markerName = 'vpn-routes.install'
$guardTask = 'VPN Routes - Guard'
$panelTask = 'VPN Routes - Panel'
$powerShell = Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
$userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
$adminsSid = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')
$systemSid = New-Object Security.Principal.SecurityIdentifier('S-1-5-18')
$utf8 = New-Object Text.UTF8Encoding($false)
$appFiles = @('RouteGuard.ps1', 'RouteGuard.Core.ps1', 'RouteGuard.Panel.ps1', 'Open-Panel.ps1', 'RouteGuard.json')
$webFiles = @('index.html', 'app.js', 'app.css', 'favicon.svg')

function Write-JsonFile {
    param($Document, [string]$Path)
    [IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $Document -Depth 12), $utf8)
}

function Read-JsonFile {
    param([string]$Path)
    Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Get-PortableConfig {
    param($Config)
    $alias = [string]$Config.AmneziaAlias
    $pattern = [string]$Config.WorkAdapterPattern
    $gateway = [string]$Config.WorkGateway
    $poll = [int]$Config.PollSeconds
    if ([string]::IsNullOrWhiteSpace($alias) -or [string]::IsNullOrWhiteSpace($pattern) -or $poll -lt 1 -or $poll -gt 300) {
        throw 'Проверьте AmneziaAlias, WorkAdapterPattern и PollSeconds в настройках.'
    }
    $null = [regex]::new($pattern)
    if ($gateway -and -not (Test-GuardUnicastIPv4 $gateway)) { throw 'WorkGateway должен быть IPv4-адресом или пустой строкой.' }
    foreach ($address in @($Config.WorkEndpointIPv4)) {
        if (-not (Test-GuardUnicastIPv4 ([string]$address))) { throw 'В списке адресов настроек найден неверный IPv4-адрес.' }
    }
    foreach ($address in @($Config.DiscoveryIPv4)) {
        if (-not (Test-GuardIPv4Text ([string]$address))) { throw 'В DiscoveryIPv4 найден неверный IPv4-адрес.' }
    }
    [ordered]@{
        AmneziaAlias = $alias
        WorkGateway = $gateway
        WorkAdapterPattern = $pattern
        WorkEndpointIPv4 = @($Config.WorkEndpointIPv4)
        DiscoveryIPv4 = @($Config.DiscoveryIPv4)
        PollSeconds = $poll
    }
}

function Export-Settings {
    if (-not (Test-Path -LiteralPath (Join-Path $root 'RouteGuard.json') -PathType Leaf)) { throw 'Установленная панель не найдена.' }
    if (Test-Path -LiteralPath $settingsFile) { throw 'Файл VPN-Routes-settings.json уже существует. Переименуйте его перед новым экспортом.' }
    . (Join-Path $PSScriptRoot 'app\RouteGuard.Core.ps1')
    $config = Get-PortableConfig (Read-JsonFile (Join-Path $root 'RouteGuard.json'))
    $rulesPath = Join-Path $root 'custom-routes.json'
    $rules = @()
    if (Test-Path -LiteralPath $rulesPath -PathType Leaf) { $rules = @((Read-JsonFile $rulesPath).rules) }
    Write-JsonFile ([ordered]@{ version = 1; config = $config; rules = $rules }) $settingsFile
    Write-Host "Настройки сохранены в $settingsFile"
}

function New-InstallDirectory {
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner($adminsSid)
    foreach ($sid in $adminsSid, $systemSid, $userSid) {
        $rights = 'ReadAndExecute'
        if ($sid -eq $adminsSid -or $sid -eq $systemSid) { $rights = 'FullControl' }
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
            $sid, $rights, 'ContainerInherit, ObjectInherit', 'None', 'Allow')))
    }
    $null = [IO.Directory]::CreateDirectory($root, $acl)
}

function Assert-InstallDirectory {
    $directory = Get-Item -LiteralPath $root -Force
    if (-not $directory.PSIsContainer -or ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'Каталог приложения имеет неожиданный тип.'
    }
    $acl = Get-Acl -LiteralPath $root
    if (-not $acl.AreAccessRulesProtected -or $acl.GetOwner([Security.Principal.SecurityIdentifier]) -ne $adminsSid) {
        throw 'Каталог принадлежит другой установке или его права доступа изменились.'
    }
    foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -eq 'Allow' -and $rule.IdentityReference -notin @($adminsSid, $systemSid)) {
            $allowed = [int][Security.AccessControl.FileSystemRights]::ReadAndExecute -bor [int][Security.AccessControl.FileSystemRights]::Synchronize
            if (([int]$rule.FileSystemRights -band (-bnot $allowed)) -ne 0) { throw 'Права доступа к каталогу приложения изменились.' }
        }
    }
}

function Get-KnownTask {
    param([string]$Name)
    Get-ScheduledTask -TaskPath '\' -TaskName $Name -ErrorAction SilentlyContinue
}

function Register-AppTask {
    param([string]$Name, [string]$Script)
    $action = New-ScheduledTaskAction -Execute $powerShell -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $root $Script)) -WorkingDirectory $root
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 10 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskPath '\' -TaskName $Name -Action $action -Trigger $trigger -Principal $principal -Settings $settings | Out-Null
}

function Stop-AppTasks {
    param([string[]]$Names)
    foreach ($name in $Names) {
        $task = Get-KnownTask $name
        if ($null -eq $task) { continue }
        Disable-ScheduledTask -InputObject $task | Out-Null
        Stop-ScheduledTask -TaskPath '\' -TaskName $name
    }
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        $running = @($Names | ForEach-Object { Get-KnownTask $_ } | Where-Object State -eq 'Running')
        if ($running.Count -eq 0) { return }
        Start-Sleep -Milliseconds 250
    }
    throw 'Не удалось остановить фоновые задачи. Повторите удаление.'
}

function Remove-AppRoutes {
    . (Join-Path $root 'RouteGuard.Core.ps1')
    $owned = @(foreach ($name in 'owned-routes.json', 'owned-custom.json') {
        Read-GuardRouteFile (Join-Path $root $name)
    })
    if ($owned.Count -eq 0) { return }
    $keys = @($owned | ForEach-Object { Get-GuardRouteKey $_ })
    $matches = @(Get-NetRoute -AddressFamily IPv4 -PolicyStore ActiveStore | Where-Object {
        $_.RouteMetric -eq 1 -and $_.Protocol -eq 'NetMgmt' -and (Get-GuardRouteKey $_) -in $keys
    })
    foreach ($route in $matches) { Remove-NetRoute -InputObject $route -Confirm:$false }
}

function Remove-InstallDirectory {
    Assert-InstallDirectory
    $resolved = (Resolve-Path -LiteralPath $root).ProviderPath
    if ($resolved -ne $root) { throw 'Путь каталога приложения изменился.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}

function Wait-Panel {
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        try {
            $request = [Net.WebRequest]::Create('http://127.0.0.1:47123/favicon.svg')
            $request.Proxy = $null
            $request.AllowAutoRedirect = $false
            $request.Timeout = 500
            $response = $request.GetResponse()
            try {
                if ([int]$response.StatusCode -eq 200 -and $response.Headers['X-VPN-Routes'] -eq '1') { return }
            } finally { $response.Dispose() }
        } catch [Net.WebException] {
            if ($_.Exception.Response) { $_.Exception.Response.Dispose() }
        }
        Start-Sleep -Milliseconds 500
    }
    throw 'Панель не запустилась на порту 47123. Проверьте, свободен ли этот порт.'
}

function Set-AppShortcuts {
    param([switch]$Remove)
    $menu = Join-Path ([Environment]::GetFolderPath('Programs')) 'Маршруты VPN.lnk'
    $desktop = Join-Path ([Environment]::GetFolderPath('DesktopDirectory')) 'Маршруты VPN.lnk'
    $shell = New-Object -ComObject WScript.Shell
    $arguments = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $root 'Open-Panel.ps1')
    foreach ($file in $menu, $desktop) {
        $shortcut = $shell.CreateShortcut($file)
        if (Test-Path -LiteralPath $file) {
            if ($shortcut.TargetPath -ne $powerShell -or $shortcut.Arguments -ne $arguments) { continue }
            if ($Remove) { Remove-Item -LiteralPath $file -Force }
            continue
        }
        if ($Remove) { continue }
        $shortcut.TargetPath = $powerShell
        $shortcut.Arguments = $arguments
        $shortcut.WorkingDirectory = $root
        $shortcut.Description = 'Открыть панель «Маршруты VPN»'
        $shortcut.Save()
    }
}

function Install-App {
    if (Test-Path -LiteralPath $root) { throw "Каталог $root уже существует. Для переноса используйте установщик на другом ПК." }
    foreach ($name in $guardTask, $panelTask) {
        if (Get-KnownTask $name) { throw "Задача $name уже существует." }
    }
    $source = Join-Path $PSScriptRoot 'app'
    . (Join-Path $source 'RouteGuard.Core.ps1')
    $config = Get-PortableConfig (Read-JsonFile (Join-Path $source 'RouteGuard.json'))
    $rules = @()
    if (Test-Path -LiteralPath $settingsFile -PathType Leaf) {
        $backup = Read-JsonFile $settingsFile
        if ($backup.version -ne 1 -or $null -eq $backup.config) { throw 'Недопустимый формат VPN-Routes-settings.json.' }
        $config = Get-PortableConfig $backup.config
        $rules = @($backup.rules | Where-Object { $null -ne $_ })
        foreach ($rule in $rules) {
            $null = ConvertTo-GuardRuleTarget ([string]$rule.target)
            if ($rule.via -notin 'work', 'amnezia', 'direct' -or [string]$rule.id -notmatch '^[0-9a-f]{6,32}$') { throw 'В файле настроек найдено некорректное правило маршрутизации.' }
        }
    }

    $registered = @()
    $directoryCreated = $false
    try {
        New-InstallDirectory
        Assert-InstallDirectory
        $directoryCreated = $true
        $panel = Join-Path $root 'panel'
        $null = New-Item -Path $panel -ItemType Directory
        foreach ($file in $appFiles) { Copy-Item -LiteralPath (Join-Path $source $file) -Destination $root }
        foreach ($file in $webFiles) { Copy-Item -LiteralPath (Join-Path $source "panel\$file") -Destination $panel }
        Write-JsonFile $config (Join-Path $root 'RouteGuard.json')
        Write-JsonFile ([ordered]@{ version = 1; rules = $rules }) (Join-Path $root 'custom-routes.json')
        $random = [Security.Cryptography.RandomNumberGenerator]::Create()
        $bytes = New-Object byte[] 32
        try { $random.GetBytes($bytes) } finally { $random.Dispose() }
        $token = [BitConverter]::ToString($bytes).Replace('-', '').ToLowerInvariant()
        [IO.File]::WriteAllText((Join-Path $root 'panel-token.txt'), $token, $utf8)
        [IO.File]::WriteAllText((Join-Path $root $markerName), $userSid.Value, $utf8)

        Register-AppTask $panelTask 'RouteGuard.Panel.ps1'
        $registered += $panelTask
        Register-AppTask $guardTask 'RouteGuard.ps1'
        $registered += $guardTask
        Start-ScheduledTask -TaskPath '\' -TaskName $panelTask
        Wait-Panel
        Set-AppShortcuts
        Start-ScheduledTask -TaskPath '\' -TaskName $guardTask
        Write-Host 'Установка завершена. Откройте «Маршруты VPN» через меню «Пуск» или с рабочего стола.'
    } catch {
        $failure = $_
        if ($directoryCreated) {
            try {
                if ($registered.Count) { Stop-AppTasks $registered }
                Set-AppShortcuts -Remove
                if ($guardTask -in $registered) { Remove-AppRoutes }
                foreach ($name in $registered) { Unregister-ScheduledTask -TaskPath '\' -TaskName $name -Confirm:$false }
                Remove-InstallDirectory
            } catch { Write-Warning "Откат прерван: $($_.Exception.Message). Запустите Uninstall.cmd перед повторной установкой." }
        }
        throw $failure
    }
}

function Uninstall-App {
    Assert-InstallDirectory
    $marker = Join-Path $root $markerName
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) { throw 'Эта копия установлена другим способом.' }
    if ([IO.File]::ReadAllText($marker).Trim() -ne $userSid.Value) { throw 'Запустите удаление из учётной записи, которой установили приложение.' }
    if ((Read-Host 'Удалить приложение и его правила? Введите Y для подтверждения') -ne 'Y') { return }
    Stop-AppTasks @($guardTask, $panelTask)
    Remove-AppRoutes
    foreach ($name in $guardTask, $panelTask) {
        if (Get-KnownTask $name) { Unregister-ScheduledTask -TaskPath '\' -TaskName $name -Confirm:$false }
    }
    Set-AppShortcuts -Remove
    Remove-InstallDirectory
    Write-Host 'Приложение удалено. Переподключите VPN, чтобы клиенты заново создали свои маршруты.'
}

try {
    if ($Mode -eq 'Export') { Export-Settings; exit 0 }
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Mode {1}' -f $PSCommandPath, $Mode
        $elevated = Start-Process -FilePath $powerShell -ArgumentList $arguments -Verb RunAs -PassThru -Wait
        exit $elevated.ExitCode
    }
    if ($Mode -eq 'Install') { Install-App } else { Uninstall-App }
    Start-Sleep -Seconds 3
} catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    if ($Mode -ne 'Export') { $null = Read-Host 'Нажмите Enter, чтобы закрыть окно' }
    exit 1
}
