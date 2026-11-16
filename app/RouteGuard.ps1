param([switch]$Once, [switch]$Audit)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'RouteGuard.Core.ps1')
$config = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'RouteGuard.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$logPath = Join-Path $PSScriptRoot 'route-guard.log'
$statePath = Join-Path $PSScriptRoot 'owned-routes.json'
$customPath = Join-Path $PSScriptRoot 'custom-routes.json'
$customStatePath = Join-Path $PSScriptRoot 'owned-custom.json'
$statusPath = Join-Path $PSScriptRoot 'status.json'
$utf8 = New-Object Text.UTF8Encoding($false)
$isoFormat = 'yyyy-MM-ddTHH:mm:ss.fffzzz'
$owned = @(Read-GuardRouteFile $statePath)
$customOwned = @(Read-GuardRouteFile $customStatePath)
$mutex = New-Object Threading.Mutex($false, 'Global\CodexVpnRouteGuard')
$locked = $false
try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
if (-not $locked) { $mutex.Dispose(); exit 0 }

$script:customRules = @()
$script:customStamp = $null
$script:customLoadError = ''
$script:dnsCache = @{}
$script:customErrors = @{}
$script:removedTotal = 0
$script:lastRemoval = $null
$script:removedThisCycle = @{}
$script:lastStatus = $null
$startedAt = (Get-Date).ToString($isoFormat)

function Write-GuardLog {
    # Logging must never stop the guard: shared append with retries, errors swallowed.
    param([string]$Message)
    $line = $utf8.GetBytes(('{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'), $Message) + "`r`n")
    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        try {
            if ((Test-Path -LiteralPath $logPath) -and (Get-Item -LiteralPath $logPath).Length -gt 2097152) {
                Move-Item -LiteralPath $logPath -Destination ($logPath + '.previous') -Force
            }
            $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
            $stream = New-Object IO.FileStream($logPath, [IO.FileMode]::Append, [IO.FileAccess]::Write, $share)
            try { $stream.Write($line, 0, $line.Length) } finally { $stream.Dispose() }
            return
        } catch { Start-Sleep -Milliseconds (50 * ($attempt + 1)) }
    }
}

function Remove-GuardConflict {
    # One route that vanished on its own (VPN reconnect) must not abort the whole batch.
    param($Route)
    $key = Get-GuardRouteKey $Route
    if ($script:removedThisCycle.ContainsKey($key)) { return }
    $script:removedThisCycle[$key] = $true
    try {
        Remove-NetRoute -AddressFamily IPv4 -PolicyStore ActiveStore -InterfaceIndex $Route.InterfaceIndex -DestinationPrefix $Route.DestinationPrefix -NextHop $Route.NextHop -Confirm:$false -ErrorAction Stop
    } catch {
        $still = @(Get-NetRoute -AddressFamily IPv4 -PolicyStore ActiveStore -InterfaceIndex $Route.InterfaceIndex -DestinationPrefix $Route.DestinationPrefix -ErrorAction SilentlyContinue | Where-Object { $_.NextHop -eq $Route.NextHop })
        if ($still.Count -gt 0) { Write-GuardLog ('Could not remove Amnezia conflict ' + $key + ': ' + $_.Exception.Message) }
        return
    }
    $script:removedTotal++
    $script:lastRemoval = (Get-Date).ToString($isoFormat)
    Write-GuardLog ('Removed Amnezia conflict: ' + $key)
}

function Update-CustomRules {
    if (-not (Test-Path -LiteralPath $customPath)) {
        if ($null -ne $script:customStamp) { $script:customRules = @(); $script:customStamp = $null; Write-GuardLog 'Loaded custom rules: 0' }
        return
    }
    $stamp = (Get-Item -LiteralPath $customPath).LastWriteTimeUtc
    if ($null -ne $script:customStamp -and $stamp -eq $script:customStamp) { return }
    $data = Get-Content -LiteralPath $customPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $list = @()
    if ($null -ne $data -and $null -ne $data.PSObject.Properties['rules']) { $list = @($data.rules | Where-Object { $null -ne $_ }) }
    $script:customRules = $list
    $script:customStamp = $stamp
    Write-GuardLog ('Loaded custom rules: ' + $list.Count)
}

function Get-CustomResolved {
    $result = @{}
    foreach ($rule in @($script:customRules)) {
        if (-not (Get-GuardValue $rule 'enabled' $true)) { continue }
        try { $target = ConvertTo-GuardRuleTarget ([string](Get-GuardValue $rule 'target' '')) } catch { continue }
        if ($target.Kind -ne 'host') { continue }
        $entry = $script:dnsCache[$target.Value]
        if ($null -eq $entry -or ((Get-Date) - $entry.At).TotalSeconds -ge 300) {
            $previous = @()
            if ($null -ne $entry) { $previous = @($entry.Ips) }
            try {
                $ips = @(Resolve-DnsName -Name $target.Value -Type A -QuickTimeout -ErrorAction Stop |
                    Where-Object { $_.Type -eq 'A' } | ForEach-Object { [string]$_.IPAddress } |
                    Where-Object { Test-GuardUnicastIPv4 $_ } | Select-Object -Unique | Select-Object -First 16)
                $entry = @{ Ips = $ips; At = Get-Date; Error = '' }
                if ($ips.Count -eq 0) { $entry.At = (Get-Date).AddSeconds(-270); $entry.Ips = $previous; $entry.Error = 'No A records' }
            } catch {
                # Retry a failed name in ~30 seconds, keep the last good addresses meanwhile.
                $entry = @{ Ips = $previous; At = (Get-Date).AddSeconds(-270); Error = $_.Exception.Message }
            }
            $script:dnsCache[$target.Value] = $entry
        }
        $result[$target.Value] = @($entry.Ips)
    }
    return $result
}

$lastErrorText = ''
$lastErrorTime = [datetime]::MinValue
try {
    if (-not $Audit) { Write-GuardLog "Started; polling active IPv4 routes every $([int]$config.PollSeconds) seconds." }
    do {
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $script:removedThisCycle = @{}
        try {
            $adapters = @(Get-NetAdapter -ErrorAction Stop)
            $routes = @(Get-NetRoute -AddressFamily IPv4 -PolicyStore ActiveStore -ErrorAction Stop)
            $plan = Get-GuardPlan -Adapters $adapters -Routes $routes -Config $config
            if ($Audit) {
                [pscustomobject]@{
                    PhysicalGateway=($plan.Gateway | Select-Object InterfaceIndex,InterfaceAlias,NextHop)
                    AmneziaIds=$plan.AmneziaIds
                    WorkRouteCount=$plan.WorkRouteCount
                    LanRouteCount=$plan.LanRouteCount
                    Conflicts=@($plan.Conflicts | Select-Object DestinationPrefix,InterfaceIndex,NextHop)
                } | ConvertTo-Json -Depth 4
                break
            }
            $routeKeys = @{}
            foreach ($route in $routes) { $routeKeys[(Get-GuardRouteKey $route)] = $true }
            $stateChanged = $false
            $desiredKeys = @()
            # Keep work VPN endpoints reachable even before the work tunnel is up.
            if ($null -ne $plan.Gateway -and $plan.AmneziaIds.Count -gt 0) {
                $desiredRoutes = @()
                foreach ($endpoint in $config.WorkEndpointIPv4) {
                    $desiredRoutes += [pscustomobject]@{DestinationPrefix="$endpoint/32";InterfaceIndex=[int]$plan.Gateway.InterfaceIndex;NextHop=$plan.Gateway.NextHop;RouteMetric=1}
                }
                foreach ($discovery in $config.DiscoveryIPv4) {
                    $desiredRoutes += [pscustomobject]@{DestinationPrefix="$discovery/32";InterfaceIndex=[int]$plan.Gateway.InterfaceIndex;NextHop='0.0.0.0';RouteMetric=1}
                }
                $desiredKeys = @($desiredRoutes | ForEach-Object { Get-GuardRouteKey $_ })
                foreach ($wanted in $desiredRoutes) {
                    $prefix = $wanted.DestinationPrefix
                    $wantedKey = Get-GuardRouteKey $wanted
                    if (-not $routeKeys.ContainsKey($wantedKey)) {
                        New-NetRoute -AddressFamily IPv4 -PolicyStore ActiveStore -DestinationPrefix $prefix -InterfaceIndex $wanted.InterfaceIndex -NextHop $wanted.NextHop -RouteMetric 1 | Out-Null
                        $routeKeys[$wantedKey] = $true
                        if (@($owned | Where-Object { (Get-GuardRouteKey $_) -eq $wantedKey }).Count -eq 0) { $owned += $wanted; $stateChanged = $true }
                        Write-GuardLog ('Created direct endpoint/discovery route: ' + $wantedKey)
                    }
                    # Never remove the VPN copy before its physical route exists.
                    foreach ($duplicate in @($routes | Where-Object { $_.InterfaceIndex -in $plan.AmneziaIds -and $_.DestinationPrefix -eq $prefix -and $_.NextHop -eq '0.0.0.0' })) {
                        Remove-GuardConflict $duplicate
                    }
                }
                # Remove only endpoint routes this guard created on an old physical network.
                $keepOwned = @()
                foreach ($old in $owned) {
                    if ((Get-GuardRouteKey $old) -in $desiredKeys) { $keepOwned += $old; continue }
                    $oldKey = Get-GuardRouteKey $old
                    $stillThere = @($routes | Where-Object { (Get-GuardRouteKey $_) -eq $oldKey -and $_.RouteMetric -eq 1 })
                    foreach ($oldRoute in $stillThere) {
                        Remove-NetRoute -AddressFamily IPv4 -PolicyStore ActiveStore -InterfaceIndex $oldRoute.InterfaceIndex -DestinationPrefix $oldRoute.DestinationPrefix -NextHop $oldRoute.NextHop -Confirm:$false
                        Write-GuardLog ('Removed old managed endpoint route: ' + $oldKey)
                    }
                    $stateChanged = $true
                }
                $owned = $keepOwned
            }
            if ($stateChanged) { ConvertTo-Json -InputObject @($owned) -Depth 4 | Set-Content -LiteralPath $statePath -Encoding UTF8 }

            # ---- Custom rules from the web panel ----
            try {
                Update-CustomRules
                $script:customLoadError = ''
            } catch {
                if ($script:customLoadError -ne $_.Exception.Message) { Write-GuardLog ('Custom rules file is invalid, keeping previous rules: ' + $_.Exception.Message) }
                $script:customLoadError = $_.Exception.Message
            }
            $resolved = Get-CustomResolved
            $custom = Get-CustomRoutePlan -Rules $script:customRules -Resolved $resolved -Plan $plan -Config $config
            $customKeys = @($custom.Desired | ForEach-Object { Get-GuardRouteKey $_ })
            $customChanged = $false
            $ruleErrors = @{}
            foreach ($wanted in $custom.Desired) {
                $wantedKey = Get-GuardRouteKey $wanted
                try {
                    if (-not $routeKeys.ContainsKey($wantedKey)) {
                        New-NetRoute -AddressFamily IPv4 -PolicyStore ActiveStore -DestinationPrefix $wanted.DestinationPrefix -InterfaceIndex $wanted.InterfaceIndex -NextHop $wanted.NextHop -RouteMetric 1 | Out-Null
                        $routeKeys[$wantedKey] = $true
                        if (@($customOwned | Where-Object { (Get-GuardRouteKey $_) -eq $wantedKey }).Count -eq 0) {
                            $customOwned += [pscustomobject]@{ DestinationPrefix = $wanted.DestinationPrefix; InterfaceIndex = $wanted.InterfaceIndex; NextHop = $wanted.NextHop; RouteMetric = 1 }
                            $customChanged = $true
                        }
                        Write-GuardLog ('Created custom route via ' + $wanted.Via + ': ' + $wantedKey)
                    }
                    if ($wanted.Via -ne 'amnezia') {
                        foreach ($duplicate in @($routes | Where-Object { $_.InterfaceIndex -in $plan.AmneziaIds -and $_.DestinationPrefix -eq $wanted.DestinationPrefix -and $_.NextHop -eq '0.0.0.0' })) {
                            Remove-GuardConflict $duplicate
                        }
                    }
                    $script:customErrors.Remove($wantedKey)
                } catch {
                    $message = $_.Exception.Message
                    $ruleErrors[$wanted.RuleId] = $message
                    if ($script:customErrors[$wantedKey] -ne $message) { Write-GuardLog ('Custom route failed: ' + $wantedKey + ' - ' + $message) }
                    $script:customErrors[$wantedKey] = $message
                }
            }
            $keepCustom = @()
            foreach ($old in $customOwned) {
                $oldKey = Get-GuardRouteKey $old
                if ($oldKey -in $customKeys) { $keepCustom += $old; continue }
                $customChanged = $true
                if ($oldKey -in $desiredKeys) { continue }
                foreach ($oldRoute in @($routes | Where-Object { (Get-GuardRouteKey $_) -eq $oldKey -and $_.RouteMetric -eq 1 })) {
                    Remove-NetRoute -AddressFamily IPv4 -PolicyStore ActiveStore -InterfaceIndex $oldRoute.InterfaceIndex -DestinationPrefix $oldRoute.DestinationPrefix -NextHop $oldRoute.NextHop -Confirm:$false -ErrorAction SilentlyContinue
                    Write-GuardLog ('Removed custom route: ' + $oldKey)
                }
            }
            $customOwned = $keepCustom
            if ($customChanged) { ConvertTo-Json -InputObject @($customOwned) -Depth 4 | Set-Content -LiteralPath $customStatePath -Encoding UTF8 }

            # Amnezia routes the user explicitly asked for are not conflicts.
            $exempt = @($custom.Desired | Where-Object { $_.Via -eq 'amnezia' } | ForEach-Object { $_.DestinationPrefix })
            foreach ($conflict in @($plan.Conflicts | Where-Object { $_.DestinationPrefix -notin $exempt })) { Remove-GuardConflict $conflict }

            $states = @(foreach ($state in $custom.States) {
                if ($ruleErrors.ContainsKey($state.id)) { $state.state = 'error'; $state.reason = $ruleErrors[$state.id] }
                $state
            })
            # Snapshot for the web panel, taken after this cycle's fixes.
            $snapRoutes = @(Get-NetRoute -AddressFamily IPv4 -PolicyStore ActiveStore -ErrorAction SilentlyContinue)
            $snapAddresses = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue)
            $snapshot = [ordered]@{
                adapters = @($adapters | ForEach-Object { [ordered]@{ ifIndex = [int]$_.ifIndex; Name = [string]$_.Name; InterfaceDescription = [string]$_.InterfaceDescription; Status = [string]$_.Status; HardwareInterface = [bool]$_.HardwareInterface } })
                routes = @($snapRoutes | ForEach-Object { [ordered]@{ DestinationPrefix = [string]$_.DestinationPrefix; NextHop = [string]$_.NextHop; InterfaceIndex = [int]$_.InterfaceIndex; InterfaceAlias = [string]$_.InterfaceAlias; RouteMetric = [int]$_.RouteMetric; InterfaceMetric = [int]$_.InterfaceMetric; Protocol = [string]$_.Protocol } })
                addresses = @($snapAddresses | ForEach-Object { [ordered]@{ InterfaceIndex = [int]$_.InterfaceIndex; IPAddress = [string]$_.IPAddress } })
            }
            $dnsInfo = @(foreach ($name in @($script:dnsCache.Keys)) {
                $entry = $script:dnsCache[$name]
                [ordered]@{ host = $name; ips = @($entry.Ips); error = [string]$entry.Error }
            })
            $status = [ordered]@{
                time = (Get-Date).ToString($isoFormat)
                startedAt = $startedAt
                pollSeconds = [int]$config.PollSeconds
                cycleMs = 0
                gateway = $(if ($null -ne $plan.Gateway) { [ordered]@{ ifIndex = [int]$plan.Gateway.InterfaceIndex; alias = [string]$plan.Gateway.InterfaceAlias; nextHop = [string]$plan.Gateway.NextHop } } else { $null })
                amneziaIds = @($plan.AmneziaIds)
                activeWorkIds = @($plan.ActiveWorkIds)
                workRouteCount = $plan.WorkRouteCount
                lanRouteCount = $plan.LanRouteCount
                conflictsSeen = @($plan.Conflicts).Count
                removedTotal = $script:removedTotal
                lastRemoval = $script:lastRemoval
                rules = $states
                dns = $dnsInfo
                customLoadError = $script:customLoadError
                lastError = ''
                snapshot = $snapshot
            }
            $status.cycleMs = [int]$watch.ElapsedMilliseconds
            try { [IO.File]::WriteAllText($statusPath, (ConvertTo-Json -InputObject $status -Depth 6 -Compress), $utf8) } catch { }
            $script:lastStatus = $status
            $lastErrorText = ''
        } catch {
            # Nothing in here may throw: the guard must survive any single bad cycle.
            $errorText = 'unknown error'
            try { $errorText = [string]$_.Exception.Message } catch { }
            if ($errorText -ne $lastErrorText -or ((Get-Date) - $lastErrorTime).TotalSeconds -ge 60) {
                Write-GuardLog ('Retry next cycle: ' + $errorText)
                $lastErrorText = $errorText
                $lastErrorTime = Get-Date
            }
            # Heartbeat with the error, so the panel shows "alive but failing" rather than "silent".
            try {
                if ($null -ne $script:lastStatus) {
                    $script:lastStatus.time = (Get-Date).ToString($isoFormat)
                    $script:lastStatus.lastError = $errorText
                    [IO.File]::WriteAllText($statusPath, (ConvertTo-Json -InputObject $script:lastStatus -Depth 6 -Compress), $utf8)
                }
            } catch { }
            if ($Once) { throw }
        }
        if (-not $Once) { try { Start-Sleep -Seconds ([int]$config.PollSeconds) } catch { Start-Sleep -Seconds 3 } }
    } while (-not $Once)
} finally {
    if ($locked) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
