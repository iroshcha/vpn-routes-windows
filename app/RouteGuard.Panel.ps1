param()
# Local web panel for RouteGuard. Runs as SYSTEM, listens on 127.0.0.1 only,
# every /api call must carry the per-install token from panel-token.txt.
# The request loop never calls CIM/network cmdlets directly: live data comes from
# the guard's status.json snapshot, and traces run in a separate runspace with a timeout.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'RouteGuard.Core.ps1')
$root = $PSScriptRoot
$config = Get-Content -LiteralPath (Join-Path $root 'RouteGuard.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$port = [int](Get-GuardValue $config 'PanelPort' 47123)
$token = ([string](Get-Content -LiteralPath (Join-Path $root 'panel-token.txt') -Raw)).Trim()
if ($token.Length -lt 32) { throw 'Panel token is missing or too short.' }
$rulesPath = Join-Path $root 'custom-routes.json'
$statusPath = Join-Path $root 'status.json'
$logPath = Join-Path $root 'route-guard.log'
$panelLogPath = Join-Path $root 'panel.log'
$utf8 = New-Object Text.UTF8Encoding($false)
$isoFormat = 'yyyy-MM-ddTHH:mm:ss.fffzzz'
$panelHost = ([string](Get-GuardValue $config 'PanelHost' 'vpn.localhost')).ToLowerInvariant()
if ($panelHost -notmatch '^[a-z0-9-]+(\.[a-z0-9-]+)*\.localhost$') { $panelHost = 'vpn.localhost' }
# Browsers resolve *.localhost to this machine by themselves; requests from other machines are refused below.
$allowedHosts = @("127.0.0.1:$port", "${panelHost}:$port", $panelHost, "${panelHost}:80")
$allowedOrigins = @("http://127.0.0.1:$port", "http://${panelHost}:$port", "http://$panelHost")
$static = @{
    '/'            = @('index.html', 'text/html; charset=utf-8')
    '/index.html'  = @('index.html', 'text/html; charset=utf-8')
    '/app.js'      = @('app.js', 'text/javascript; charset=utf-8')
    '/app.css'     = @('app.css', 'text/css; charset=utf-8')
    '/favicon.svg' = @('favicon.svg', 'image/svg+xml')
}

$mutex = New-Object Threading.Mutex($false, 'Global\CodexVpnRoutePanel')
$locked = $false
try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
if (-not $locked) { $mutex.Dispose(); exit 0 }

function Write-PanelLog {
    param([string]$Message)
    try {
        if ((Test-Path -LiteralPath $panelLogPath) -and (Get-Item -LiteralPath $panelLogPath).Length -gt 524288) {
            Move-Item -LiteralPath $panelLogPath -Destination ($panelLogPath + '.previous') -Force
        }
        [IO.File]::AppendAllText($panelLogPath, ('{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Message) + "`r`n", $utf8)
    } catch { }
}

function New-PanelError {
    param([int]$Status, [string]$Message)
    $exception = New-Object Exception($Message)
    $exception.Data['status'] = $Status
    return $exception
}

function Send-PanelBytes {
    param($Context, [int]$Status, [string]$ContentType, [byte[]]$Bytes)
    $response = $Context.Response
    $response.StatusCode = $Status
    $response.ContentType = $ContentType
    $response.KeepAlive = $false
    $response.AddHeader('X-VPN-Routes', '1')
    $response.AddHeader('X-Content-Type-Options', 'nosniff')
    $response.AddHeader('Cache-Control', 'no-store')
    $response.AddHeader('Referrer-Policy', 'no-referrer')
    $response.AddHeader('X-Frame-Options', 'DENY')
    $response.AddHeader('Content-Security-Policy', "default-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'")
    $response.ContentLength64 = $Bytes.Length
    $response.OutputStream.Write($Bytes, 0, $Bytes.Length)
}

function Send-PanelJson {
    param($Context, [int]$Status, $Object)
    $json = ConvertTo-Json -InputObject $Object -Depth 8 -Compress
    Send-PanelBytes $Context $Status 'application/json; charset=utf-8' ($utf8.GetBytes($json))
}

function Test-PanelToken {
    param([string]$Value)
    if ([string]::IsNullOrEmpty($Value) -or $Value.Length -ne $token.Length) { return $false }
    $diff = 0
    for ($i = 0; $i -lt $token.Length; $i++) { $diff = $diff -bor ([int][char]$Value[$i] -bxor [int][char]$token[$i]) }
    return ($diff -eq 0)
}

function Read-PanelBody {
    param($Request)
    if ($Request.ContentLength64 -gt 16384) { throw (New-PanelError 413 'Слишком большой запрос.') }
    $reader = New-Object IO.StreamReader($Request.InputStream, $utf8)
    try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
    if ([string]::IsNullOrWhiteSpace($text)) { return [pscustomobject]@{} }
    try { return ($text | ConvertFrom-Json) } catch { throw (New-PanelError 400 'Некорректный JSON.') }
}

function Read-PanelText {
    # Shared read: never blocks on a file the guard is writing.
    param([string]$Path, [int]$MaxBytes = 0)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
    $stream = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
    try {
        $start = 0
        if ($MaxBytes -gt 0 -and $stream.Length -gt $MaxBytes) { $start = $stream.Length - $MaxBytes }
        $stream.Position = $start
        $buffer = New-Object byte[] ([int]($stream.Length - $start))
        $read = 0
        while ($read -lt $buffer.Length) {
            $n = $stream.Read($buffer, $read, $buffer.Length - $read)
            if ($n -le 0) { break }
            $read += $n
        }
    } finally { $stream.Dispose() }
    $text = $utf8.GetString($buffer, 0, $read).TrimStart([char]0xFEFF)
    if ($start -gt 0) { $cut = $text.IndexOf("`n"); if ($cut -ge 0) { $text = $text.Substring($cut + 1) } }
    return $text
}

function Read-PanelJsonFile {
    param([string]$Path)
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        try {
            $text = Read-PanelText $Path
            if ([string]::IsNullOrWhiteSpace($text)) { return $null }
            return ($text | ConvertFrom-Json)
        } catch { Start-Sleep -Milliseconds 40 }
    }
    return $null
}

function Get-PanelRules {
    $data = Read-PanelJsonFile $rulesPath
    if ($null -eq $data -or $null -eq $data.PSObject.Properties['rules']) { return @() }
    return @($data.rules | Where-Object { $null -ne $_ })
}

function Save-PanelRules {
    param([array]$Rules)
    $json = ConvertTo-Json -InputObject ([ordered]@{ version = 1; rules = @($Rules) }) -Depth 6
    [IO.File]::WriteAllText($rulesPath, $json, $utf8)
}

function Get-OwnedKeySet {
    param([string]$Path)
    $set = @{}
    foreach ($item in @(ConvertTo-GuardRouteList (Read-PanelJsonFile $Path))) { $set[(Get-GuardRouteKey $item)] = $true }
    return $set
}

function Get-PathKind {
    param($Adapter)
    if ($null -eq $Adapter) { return 'system' }
    if ($Adapter.Name -eq $config.AmneziaAlias) { return 'amnezia' }
    if ($Adapter.InterfaceDescription -match $config.WorkAdapterPattern) { return 'work' }
    if ($Adapter.HardwareInterface) { return 'direct' }
    return 'other'
}

function Get-PanelSnapshot {
    $status = Read-PanelJsonFile $statusPath
    $snapshot = Get-GuardValue $status 'snapshot' $null
    $adapters = @()
    $routes = @()
    $addresses = @()
    if ($null -ne $snapshot) {
        $adapters = @(Get-GuardValue $snapshot 'adapters' @() | Where-Object { $null -ne $_ })
        $routes = @(Get-GuardValue $snapshot 'routes' @() | Where-Object { $null -ne $_ })
        $addresses = @(Get-GuardValue $snapshot 'addresses' @() | Where-Object { $null -ne $_ })
        $status.PSObject.Properties.Remove('snapshot')
    }
    $byIndex = @{}
    foreach ($adapter in $adapters) { $byIndex[[int]$adapter.ifIndex] = $adapter }
    return [pscustomobject]@{ Status = $status; Adapters = $adapters; Routes = $routes; Addresses = $addresses; ByIndex = $byIndex }
}

function Get-PanelState {
    $snap = Get-PanelSnapshot
    $plan = Get-GuardPlan -Adapters $snap.Adapters -Routes $snap.Routes -Config $config
    $localIps = @{}
    foreach ($address in $snap.Addresses) { $localIps[[string]$address.IPAddress] = $true }
    $conflictKeys = @{}
    foreach ($conflict in @($plan.Conflicts)) { $conflictKeys[(Get-GuardRouteKey $conflict)] = $true }
    $guardKeys = Get-OwnedKeySet (Join-Path $root 'owned-routes.json')
    $ruleKeys = Get-OwnedKeySet (Join-Path $root 'owned-custom.json')

    $routeList = @(foreach ($route in $snap.Routes) {
        $index = [int]$route.InterfaceIndex
        $prefix = [string]$route.DestinationPrefix
        $hop = [string]$route.NextHop
        $key = Get-GuardRouteKey $route
        $ip = $prefix.Split('/')[0]
        $kind = Get-PathKind $snap.ByIndex[$index]
        $noise = ($kind -eq 'system') -or ($prefix -match '^(127\.|169\.254\.|22[4-9]\.|23\d\.|255\.)') -or
            ($prefix.EndsWith('/32') -and $hop -eq '0.0.0.0' -and ($localIps.ContainsKey($ip) -or $ip.EndsWith('.255')))
        $managed = ''
        if ($ruleKeys.ContainsKey($key)) { $managed = 'rule' } elseif ($guardKeys.ContainsKey($key)) { $managed = 'guard' }
        [ordered]@{
            prefix = $prefix
            nextHop = $hop
            ifIndex = $index
            alias = [string]$route.InterfaceAlias
            kind = $kind
            metric = [int]$route.RouteMetric + [int]$route.InterfaceMetric
            protocol = [string]$route.Protocol
            conflict = $conflictKeys.ContainsKey($key)
            managed = $managed
            noise = [bool]$noise
        }
    })
    $interfaces = @(foreach ($adapter in $snap.Adapters) {
        [ordered]@{
            ifIndex = [int]$adapter.ifIndex
            name = [string]$adapter.Name
            description = [string]$adapter.InterfaceDescription
            status = [string]$adapter.Status
            kind = Get-PathKind $adapter
            ipv4 = @($snap.Addresses | Where-Object { [int]$_.InterfaceIndex -eq [int]$adapter.ifIndex } | ForEach-Object { [string]$_.IPAddress })
        }
    })
    [ordered]@{
        now = (Get-Date).ToString($isoFormat)
        computer = $env:COMPUTERNAME
        config = [ordered]@{
            amneziaAlias = [string]$config.AmneziaAlias
            workGateway = [string]$plan.WorkGateway
            workEndpoints = @($config.WorkEndpointIPv4)
            pollSeconds = [int]$config.PollSeconds
        }
        gateway = $(if ($null -ne $plan.Gateway) { [ordered]@{ ifIndex = [int]$plan.Gateway.InterfaceIndex; alias = [string]$plan.Gateway.InterfaceAlias; nextHop = [string]$plan.Gateway.NextHop } } else { $null })
        amneziaIds = @($plan.AmneziaIds | ForEach-Object { [int]$_ })
        activeWorkIds = @($plan.ActiveWorkIds | ForEach-Object { [int]$_ })
        workRouteCount = $plan.WorkRouteCount
        lanRouteCount = $plan.LanRouteCount
        conflicts = @($plan.Conflicts).Count
        interfaces = $interfaces
        routes = $routeList
        rules = @(Get-PanelRules)
        guard = [ordered]@{ task = 'unknown'; status = $snap.Status }
    }
}

function Get-PanelLog {
    $lines = @()
    foreach ($path in @(($logPath + '.previous'), $logPath)) {
        $text = Read-PanelText $path 98304
        if ($text) { $lines += @($text -split "`r?`n" | Where-Object { $_ }) }
    }
    if ($lines.Count -gt 600) { $lines = $lines[($lines.Count - 600)..($lines.Count - 1)] }
    return [ordered]@{ lines = @($lines) }
}

# ---- network lookups isolated from the request loop ----
$script:workerRunspace = $null
function Invoke-PanelWorker {
    param([string]$Script, [object[]]$Arguments, [int]$TimeoutMs = 8000)
    if ($null -eq $script:workerRunspace -or $script:workerRunspace.RunspaceStateInfo.State -ne 'Opened' -or $script:workerRunspace.RunspaceAvailability -ne 'Available') {
        $script:workerRunspace = [runspacefactory]::CreateRunspace()
        $script:workerRunspace.Open()
    }
    $ps = [powershell]::Create()
    $ps.Runspace = $script:workerRunspace
    [void]$ps.AddScript($Script)
    foreach ($argument in $Arguments) { [void]$ps.AddArgument($argument) }
    $async = $ps.BeginInvoke()
    if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs)) {
        try { [void]$ps.BeginStop($null, $null) } catch { }
        $script:workerRunspace = $null
        Write-PanelLog "Worker timed out after $TimeoutMs ms"
        throw (New-PanelError 504 'Windows не ответила вовремя. Попробуйте ещё раз.')
    }
    try {
        $output = @($ps.EndInvoke($async))
        if ($ps.Streams.Error.Count -gt 0) { throw $ps.Streams.Error[0].Exception }
        return $output
    } finally { $ps.Dispose() }
}

$resolveScript = @'
param($Name)
Resolve-DnsName -Name $Name -Type A -QuickTimeout -ErrorAction Stop | Where-Object { $_.Type -eq 'A' } |
    ForEach-Object { [string]$_.IPAddress } | Select-Object -Unique | Select-Object -First 8
'@
$findRouteScript = @'
param($Address)
$found = @(Find-NetRoute -RemoteIPAddress $Address -ErrorAction Stop)
$route = $found | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_NetRoute' } | Select-Object -First 1
$source = $found | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_NetIPAddress' } | Select-Object -First 1
$result = @{ prefix = ''; nextHop = ''; ifIndex = 0; alias = ''; source = '' }
if ($null -ne $route) {
    $result.prefix = [string]$route.DestinationPrefix
    $result.nextHop = [string]$route.NextHop
    $result.ifIndex = [int]$route.InterfaceIndex
    $result.alias = [string]$route.InterfaceAlias
}
if ($null -ne $source) { $result.source = [string]$source.IPAddress }
$result
'@

function Invoke-PanelTrace {
    param([string]$Query)
    $text = ([string]$Query).Trim()
    if ($text.Length -eq 0 -or $text.Length -gt 300) { throw (New-PanelError 400 'Введите IP-адрес, домен или ссылку.') }
    $hostName = $null
    $ips = @()
    $plain = $text.ToLowerInvariant()
    if ($plain -match '^[a-z][a-z0-9+.-]*://([^/:?#]+)') { $plain = $Matches[1] }
    $plain = $plain.Split('/')[0]
    if ($plain -match '^\d{1,3}(\.\d{1,3}){3}:\d+$') { $plain = $plain.Split(':')[0] }
    if (Test-GuardIPv4Text $plain) { $ips = @($plain) }
    else {
        try { $target = ConvertTo-GuardRuleTarget $plain } catch { throw (New-PanelError 400 $_.Exception.Message) }
        $hostName = $target.Value
        try { $ips = @(Invoke-PanelWorker $resolveScript @($hostName) 8000 | Where-Object { $_ }) }
        catch {
            if ($_.Exception.Data.Contains('status')) { throw }
            throw (New-PanelError 404 "Имя $hostName не найдено в DNS (или DNS сейчас недоступен).")
        }
        if ($ips.Count -eq 0) { throw (New-PanelError 404 "У имени $hostName нет IPv4-адресов.") }
    }
    $snap = Get-PanelSnapshot
    $rules = @(Get-PanelRules)
    $results = @(foreach ($ip in $ips) {
        $item = [ordered]@{ ip = $ip; prefix = ''; nextHop = ''; ifIndex = 0; alias = ''; kind = 'none'; source = ''; rule = $null; error = '' }
        try {
            $found = @(Invoke-PanelWorker $findRouteScript @($ip) 6000) | Select-Object -Last 1
            if ($null -ne $found -and $found.prefix) {
                $item.prefix = $found.prefix
                $item.nextHop = $found.nextHop
                $item.ifIndex = [int]$found.ifIndex
                $item.alias = $found.alias
                $item.source = $found.source
                $item.kind = Get-PathKind $snap.ByIndex[[int]$found.ifIndex]
            }
        } catch { $item.error = $_.Exception.Message }
        foreach ($rule in $rules) {
            $ruleTarget = [string](Get-GuardValue $rule 'target' '')
            $matched = $false
            if ($ruleTarget -match '/') { try { $matched = Test-GuardPrefixContains $ruleTarget $ip } catch { } }
            elseif ($null -ne $hostName -and $ruleTarget -eq $hostName) { $matched = $true }
            elseif ($null -ne $snap.Status) {
                foreach ($state in @(Get-GuardValue $snap.Status 'rules' @())) {
                    if ($null -ne $state -and [string]$state.id -eq [string]$rule.id -and (@($state.prefixes) -contains "$ip/32")) { $matched = $true }
                }
            }
            if ($matched) { $item.rule = [ordered]@{ id = [string]$rule.id; target = $ruleTarget; via = [string]$rule.via; enabled = [bool](Get-GuardValue $rule 'enabled' $true) }; break }
        }
        $item
    })
    return [ordered]@{ query = $text; host = $hostName; results = $results }
}

function Add-PanelRule {
    param($Body)
    try { $target = ConvertTo-GuardRuleTarget ([string](Get-GuardValue $Body 'target' '')) } catch { throw (New-PanelError 400 $_.Exception.Message) }
    $via = [string](Get-GuardValue $Body 'via' '')
    if ($via -notin $script:GuardVias) { throw (New-PanelError 400 'Выберите путь: работа, Amnezia или напрямую.') }
    $note = ([string](Get-GuardValue $Body 'note' '')).Trim()
    if ($note.Length -gt 80) { $note = $note.Substring(0, 80) }
    $rules = @(Get-PanelRules)
    if ($rules.Count -ge 200) { throw (New-PanelError 400 'Достигнут предел: 200 правил.') }
    if (@($rules | Where-Object { [string]$_.target -eq $target.Value }).Count -gt 0) { throw (New-PanelError 409 "Правило для $($target.Value) уже есть.") }
    $rule = [pscustomobject]@{
        id = ([guid]::NewGuid().ToString('N')).Substring(0, 10)
        target = $target.Value
        kind = $target.Kind
        via = $via
        enabled = $true
        note = $note
        created = (Get-Date).ToString($isoFormat)
    }
    Save-PanelRules (@($rules) + @($rule))
    Write-PanelLog "Rule added: $($rule.target) via $via"
    return $rule
}

function Update-PanelRule {
    param([string]$Id, $Body)
    $rules = @(Get-PanelRules)
    $rule = @($rules | Where-Object { [string]$_.id -eq $Id }) | Select-Object -First 1
    if ($null -eq $rule) { throw (New-PanelError 404 'Правило не найдено.') }
    if ($null -ne $Body.PSObject.Properties['via']) {
        if ([string]$Body.via -notin $script:GuardVias) { throw (New-PanelError 400 'Неизвестный путь.') }
        $rule.via = [string]$Body.via
    }
    if ($null -ne $Body.PSObject.Properties['enabled']) {
        if ($null -eq $rule.PSObject.Properties['enabled']) { $rule | Add-Member -NotePropertyName enabled -NotePropertyValue $true }
        $rule.enabled = [bool]$Body.enabled
    }
    if ($null -ne $Body.PSObject.Properties['note']) {
        $note = ([string]$Body.note).Trim()
        if ($note.Length -gt 80) { $note = $note.Substring(0, 80) }
        if ($null -eq $rule.PSObject.Properties['note']) { $rule | Add-Member -NotePropertyName note -NotePropertyValue '' }
        $rule.note = $note
    }
    Save-PanelRules $rules
    Write-PanelLog "Rule updated: $($rule.target) via $($rule.via) enabled $($rule.enabled)"
    return $rule
}

function Remove-PanelRule {
    param([string]$Id)
    $rules = @(Get-PanelRules)
    $left = @($rules | Where-Object { [string]$_.id -ne $Id })
    if ($left.Count -eq $rules.Count) { throw (New-PanelError 404 'Правило не найдено.') }
    Save-PanelRules $left
    Write-PanelLog "Rule removed: $Id"
    return [ordered]@{ removed = $Id }
}

function Invoke-PanelRequest {
    param($Context)
    $request = $Context.Request
    if (-not [Net.IPAddress]::IsLoopback($request.RemoteEndPoint.Address)) { throw (New-PanelError 403 'Only local access.') }
    if (([string]$request.Headers['Host']).ToLowerInvariant() -notin $allowedHosts) { throw (New-PanelError 421 'Wrong host.') }
    $origin = [string]$request.Headers['Origin']
    if ($origin -and $origin.ToLowerInvariant() -notin $allowedOrigins) { throw (New-PanelError 403 'Wrong origin.') }
    $path = $request.Url.AbsolutePath
    $method = $request.HttpMethod.ToUpperInvariant()

    if (-not $path.StartsWith('/api/')) {
        if ($method -ne 'GET' -or -not $static.ContainsKey($path)) { throw (New-PanelError 404 'Not found.') }
        $entry = $static[$path]
        $file = Join-Path (Join-Path $root 'panel') $entry[0]
        Send-PanelBytes $Context 200 $entry[1] ([IO.File]::ReadAllBytes($file))
        return
    }
    if (-not (Test-PanelToken ([string]$request.Headers['X-Guard-Token']))) { throw (New-PanelError 401 'Нужен ключ панели. Откройте её через ярлык «Маршруты VPN».') }
    # Only calls that carry a body must be JSON; DELETE has no body.
    if ($method -in @('POST', 'PATCH') -and -not ([string]$request.ContentType).StartsWith('application/json')) { throw (New-PanelError 415 'Expected JSON.') }

    if ($method -eq 'GET' -and $path -eq '/api/state') { Send-PanelJson $Context 200 (Get-PanelState); return }
    if ($method -eq 'GET' -and $path -eq '/api/log') { Send-PanelJson $Context 200 (Get-PanelLog); return }
    if ($method -eq 'POST' -and $path -eq '/api/trace') { $body = Read-PanelBody $request; Send-PanelJson $Context 200 (Invoke-PanelTrace ([string](Get-GuardValue $body 'target' ''))); return }
    if ($method -eq 'POST' -and $path -eq '/api/rules') { Send-PanelJson $Context 201 (Add-PanelRule (Read-PanelBody $request)); return }
    if ($path -match '^/api/rules/([0-9a-f]{6,32})$') {
        $id = $Matches[1]
        if ($method -eq 'PATCH') { Send-PanelJson $Context 200 (Update-PanelRule $id (Read-PanelBody $request)); return }
        if ($method -eq 'DELETE') { Send-PanelJson $Context 200 (Remove-PanelRule $id); return }
    }
    throw (New-PanelError 404 'Unknown API call.')
}

function New-PanelListener {
    param([bool]$WithPort80)
    $l = New-Object Net.HttpListener
    $l.Prefixes.Add("http://127.0.0.1:$port/")
    $l.Prefixes.Add("http://${panelHost}:$port/")
    if ($WithPort80) { $l.Prefixes.Add("http://${panelHost}:80/") }
    $l.IgnoreWriteExceptions = $true
    try { $l.Start() } catch { $l.Close(); throw }
    return $l
}

$listener = $null
try {
    try {
        $listener = New-PanelListener $true
        Write-PanelLog "Panel started: http://$panelHost/ and http://127.0.0.1:$port/ (pid $PID)"
    } catch {
        # Port 80 taken by another program: keep the panel alive on its own port.
        Write-PanelLog ("Port 80 unavailable, using only port ${port}: " + $_.Exception.Message)
        $listener = New-PanelListener $false
        Write-PanelLog "Panel started: http://${panelHost}:$port/ and http://127.0.0.1:$port/ (pid $PID)"
    }
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $status = 200
        try {
            Invoke-PanelRequest $context
        } catch {
            $status = 500
            $exception = $_.Exception
            while ($null -ne $exception -and -not $exception.Data.Contains('status') -and $null -ne $exception.InnerException) { $exception = $exception.InnerException }
            if ($null -ne $exception -and $exception.Data.Contains('status')) { $status = [int]$exception.Data['status'] } else { $exception = $_.Exception }
            if ($status -ge 500) { Write-PanelLog ("Error {0} {1}: {2}" -f $context.Request.HttpMethod, $context.Request.Url.AbsolutePath, $_.Exception.ToString()) }
            try { Send-PanelJson $context $status ([ordered]@{ error = $exception.Message }) } catch { }
        } finally {
            try { $context.Response.Close() } catch { }
        }
        if ($watch.ElapsedMilliseconds -gt 1500) { Write-PanelLog ("Slow request {0} {1}: {2} ms, status {3}" -f $context.Request.HttpMethod, $context.Request.Url.AbsolutePath, $watch.ElapsedMilliseconds, $status) }
    }
} catch {
    Write-PanelLog ('Panel stopped: ' + $_.Exception.ToString())
    throw
} finally {
    try { if ($null -ne $listener) { $listener.Stop(); $listener.Close() } } catch { }
    if ($locked) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
