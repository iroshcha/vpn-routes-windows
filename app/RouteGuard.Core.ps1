Set-StrictMode -Version Latest

function Get-GuardPlan {
    param([array]$Adapters, [array]$Routes, $Config)
    $physicalIds = @($Adapters | Where-Object { $_.Status -eq 'Up' -and $_.HardwareInterface } | ForEach-Object { $_.ifIndex })
    $physicalDefault = @($Routes | Where-Object {
        $_.DestinationPrefix -eq '0.0.0.0/0' -and $_.NextHop -ne '0.0.0.0' -and $_.InterfaceIndex -in $physicalIds
    } | Sort-Object @{Expression = { [int]$_.RouteMetric + [int]$_.InterfaceMetric }}, InterfaceIndex | Select-Object -First 1)
    $amneziaIds = @($Adapters | Where-Object { $_.Status -eq 'Up' -and $_.Name -eq $Config.AmneziaAlias } | ForEach-Object { $_.ifIndex })
    $workIds = @($Adapters | Where-Object {
        $_.Status -eq 'Up' -and $_.InterfaceDescription -match $Config.WorkAdapterPattern
    } | ForEach-Object { $_.ifIndex })
    $workGateway = [string]$Config.WorkGateway
    $workCandidates = @($Routes | Where-Object {
        $_.InterfaceIndex -in $workIds -and $_.DestinationPrefix -ne '0.0.0.0/0' -and $_.NextHop -ne '0.0.0.0'
    })
    if (-not $workGateway -and $workIds.Count -eq 1) {
        $nextHops = @($workCandidates | ForEach-Object { $_.NextHop } | Select-Object -Unique)
        if ($nextHops.Count -eq 1) { $workGateway = $nextHops[0] }
    }
    $workRoutes = @($workCandidates | Where-Object NextHop -eq $workGateway)
    $activeWorkIds = @($workRoutes | ForEach-Object { $_.InterfaceIndex } | Select-Object -Unique)
    $connectedRoutes = @($Routes | Where-Object {
        $_.InterfaceIndex -in $activeWorkIds -and $_.NextHop -eq '0.0.0.0' -and
        $_.DestinationPrefix -ne '0.0.0.0/0' -and
        $_.DestinationPrefix -notmatch '^(127\.|169\.254\.)' -and
        [int](($_.DestinationPrefix -split '\.')[0]) -lt 224
    })
    $lanRoutes = @($Routes | Where-Object {
        $_.InterfaceIndex -in $physicalIds -and $_.NextHop -eq '0.0.0.0' -and
        $_.DestinationPrefix -ne '0.0.0.0/0' -and
        $_.DestinationPrefix -notmatch '^(127\.|169\.254\.)' -and
        [int](($_.DestinationPrefix -split '\.')[0]) -lt 224
    })
    $prefixes = @($workRoutes | ForEach-Object { $_.DestinationPrefix }) + @($connectedRoutes | ForEach-Object { $_.DestinationPrefix }) + @($lanRoutes | ForEach-Object { $_.DestinationPrefix })
    $conflicts = @($Routes | Where-Object {
        $_.InterfaceIndex -in $amneziaIds -and $_.NextHop -eq '0.0.0.0' -and $_.DestinationPrefix -in $prefixes
    })
    [pscustomobject]@{
        Gateway = $(if ($physicalDefault.Count) { $physicalDefault[0] } else { $null })
        AmneziaIds = $amneziaIds
        ActiveWorkIds = $activeWorkIds
        WorkPrefixes = @($Routes | Where-Object {
            $_.InterfaceIndex -in $workIds -and $_.DestinationPrefix -ne '0.0.0.0/0'
        } | ForEach-Object { $_.DestinationPrefix })
        WorkGateway = $workGateway
        WorkRouteCount = $workRoutes.Count
        LanRouteCount = $lanRoutes.Count
        Conflicts = $conflicts
    }
}

function Get-GuardRouteKey {
    param($Route)
    return ('{0}|{1}|{2}' -f $Route.DestinationPrefix, $Route.InterfaceIndex, $Route.NextHop)
}

# Windows PowerShell 5.1 may serialize arrays as {"value":[...],"Count":n}; stop that and
# accept both shapes when reading the guard's own state files.
Remove-TypeData -TypeName System.Array -ErrorAction SilentlyContinue

function ConvertTo-GuardRouteList {
    param($Data)
    $result = @()
    foreach ($item in @($Data)) {
        if ($null -eq $item) { continue }
        if ($null -ne $item.PSObject.Properties['DestinationPrefix']) { $result += $item; continue }
        if ($null -ne $item.PSObject.Properties['value']) { $result += @(ConvertTo-GuardRouteList $item.value) }
    }
    return $result
}

function Read-GuardRouteFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    try {
        $text = Get-Content -LiteralPath $Path -Raw
        if ([string]::IsNullOrWhiteSpace($text)) { return @() }
        return @(ConvertTo-GuardRouteList ($text | ConvertFrom-Json))
    } catch { return @() }
}

# ---- Custom rules (added by the web panel) ----------------------------------

$script:GuardVias = @('work', 'amnezia', 'direct')

function Get-GuardValue {
    param($Object, [string]$Name, $Default)
    if ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $Default
}

function ConvertTo-GuardUInt32 {
    param([string]$Address)
    [uint64]$value = 0
    foreach ($octet in $Address.Split('.')) { $value = $value * 256 + [uint64]$octet }
    return $value
}

function ConvertFrom-GuardUInt32 {
    param([uint64]$Value)
    return ('{0}.{1}.{2}.{3}' -f (($Value -shr 24) -band 255), (($Value -shr 16) -band 255), (($Value -shr 8) -band 255), ($Value -band 255))
}

function Test-GuardIPv4Text {
    param([string]$Address)
    if ($Address -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { return $false }
    foreach ($octet in $Address.Split('.')) { if ([int]$octet -gt 255) { return $false } }
    return $true
}

function Test-GuardUnicastIPv4 {
    param([string]$Address)
    if (-not (Test-GuardIPv4Text $Address)) { return $false }
    $first = [int]$Address.Split('.')[0]
    return ($first -ne 0 -and $first -ne 127 -and $first -lt 224)
}

function ConvertTo-GuardRuleTarget {
    # Returns @{Kind='prefix'|'host'; Value=normalized}. Throws a readable message on bad input.
    param([string]$Target)
    $text = ([string]$Target).Trim().ToLowerInvariant()
    if ($text -match '^[a-z][a-z0-9+.-]*://([^/:?#]+)') { $text = $Matches[1] }
    if ($text -match '^(\d{1,3}(?:\.\d{1,3}){3})(?:/(\d{1,2}))?$') {
        $address = $Matches[1]
        $length = 32
        if ($Matches.Count -gt 2 -and $Matches[2]) { $length = [int]$Matches[2] }
        if (-not (Test-GuardIPv4Text $address)) { throw "Некорректный IPv4-адрес: $address" }
        if ($length -lt 1 -or $length -gt 32) { throw 'Длина маски должна быть от 1 до 32.' }
        if (-not (Test-GuardUnicastIPv4 $address)) { throw 'Нельзя: адреса 0.x, 127.x и multicast/служебные диапазоны.' }
        [uint64]$mask = ([uint64]4294967295 -shl (32 - $length)) -band [uint64]4294967295
        $network = ConvertFrom-GuardUInt32 ((ConvertTo-GuardUInt32 $address) -band $mask)
        return [pscustomobject]@{ Kind = 'prefix'; Value = "$network/$length" }
    }
    $hostName = $text.TrimEnd('.')
    if ($hostName.Length -le 253 -and $hostName -match '^([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9][a-z0-9-]{0,61}[a-z0-9]$' -and $hostName -notmatch '^[\d.]+$') {
        return [pscustomobject]@{ Kind = 'host'; Value = $hostName }
    }
    throw 'Укажите IPv4-адрес, подсеть вида 10.20.0.0/16 или доменное имя.'
}

function Test-GuardPrefixContains {
    param([string]$Prefix, [string]$Address)
    $parts = $Prefix.Split('/')
    $length = [int]$parts[1]
    [uint64]$mask = ([uint64]4294967295 -shl (32 - $length)) -band [uint64]4294967295
    return (((ConvertTo-GuardUInt32 $Address) -band $mask) -eq ((ConvertTo-GuardUInt32 $parts[0]) -band $mask))
}

function Get-CustomRoutePlan {
    # Pure function: turns user rules into the exact routes the guard must keep.
    param([array]$Rules, [hashtable]$Resolved, $Plan, $Config)
    $desired = @()
    $states = @()
    $taken = @{}
    foreach ($rule in @($Rules)) {
        if ($null -eq $rule) { continue }
        $id = [string](Get-GuardValue $rule 'id' '')
        $via = [string](Get-GuardValue $rule 'via' '')
        if (-not (Get-GuardValue $rule 'enabled' $true)) {
            $states += [pscustomobject]@{ id = $id; via = $via; state = 'off'; reason = 'Правило выключено'; prefixes = @() }
            continue
        }
        try { $target = ConvertTo-GuardRuleTarget ([string](Get-GuardValue $rule 'target' '')) }
        catch { $states += [pscustomobject]@{ id = $id; via = $via; state = 'error'; reason = $_.Exception.Message; prefixes = @() }; continue }
        $importedDirect = $via -eq 'direct' -and (Get-GuardValue $rule 'importedDirect' $false)
        $prefixes = @()
        if ($target.Kind -eq 'prefix') { $prefixes = @($target.Value) }
        elseif ($null -ne $Resolved -and $Resolved.ContainsKey($target.Value)) { $prefixes = @(@($Resolved[$target.Value]) | Where-Object { $_ } | ForEach-Object { "$_/32" }) }
        if ($importedDirect -and $target.Kind -eq 'host') {
            $prefixes = @($prefixes | Where-Object { $_ -notmatch '^(10\.|169\.254\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)' })
        }
        if ($prefixes.Count -eq 0) {
            $states += [pscustomobject]@{ id = $id; via = $via; state = 'waiting'; reason = 'Имя пока не разрешилось в IPv4-адрес'; prefixes = @() }
            continue
        }
        $hop = $null
        $reason = ''
        switch ($via) {
            'work' {
                if (@($Plan.ActiveWorkIds).Count -gt 0) { $hop = @{ Index = [int]@($Plan.ActiveWorkIds)[0]; NextHop = [string]$Plan.WorkGateway } }
                else { $reason = 'Рабочий OpenVPN не подключён' }
            }
            'direct' {
                if ($importedDirect -and @($Plan.AmneziaIds).Count -eq 0) { $reason = 'AmneziaVPN не подключён' }
                elseif ($null -ne $Plan.Gateway) { $hop = @{ Index = [int]$Plan.Gateway.InterfaceIndex; NextHop = [string]$Plan.Gateway.NextHop } }
                else { $reason = 'Нет активного Wi-Fi/Ethernet со шлюзом' }
            }
            'amnezia' {
                if (@($Plan.AmneziaIds).Count -gt 0) { $hop = @{ Index = [int]@($Plan.AmneziaIds)[0]; NextHop = '0.0.0.0' } }
                else { $reason = 'AmneziaVPN не подключён' }
            }
            default { $reason = "Неизвестный путь: $via" }
        }
        if ($null -eq $hop) {
            $states += [pscustomobject]@{ id = $id; via = $via; state = 'waiting'; reason = $reason; prefixes = $prefixes }
            continue
        }
        $applied = @()
        $shadowed = @()
        $workPrefixes = @()
        if ($importedDirect) { $workPrefixes = @(Get-GuardValue $Plan 'WorkPrefixes' @()) }
        $skippedWorkPrefix = $false
        foreach ($prefix in $prefixes) {
            if ($workPrefixes.Count -gt 0) {
                $address, $length = $prefix.Split('/')
                $coveredByWork = $workPrefixes | Where-Object {
                    [int]($_.Split('/')[1]) -le [int]$length -and (Test-GuardPrefixContains $_ $address)
                } | Select-Object -First 1
                if ($coveredByWork) { $skippedWorkPrefix = $true; continue }
            }
            if ($taken.ContainsKey($prefix)) { $shadowed += $prefix; continue }
            $taken[$prefix] = $id
            $applied += $prefix
            $desired += [pscustomobject]@{ DestinationPrefix = $prefix; InterfaceIndex = $hop.Index; NextHop = $hop.NextHop; RouteMetric = 1; RuleId = $id; Via = $via }
        }
        $note = ''
        if ($skippedWorkPrefix) { $note = 'Маршруты рабочего OpenVPN имеют приоритет' }
        if ($shadowed.Count -gt 0) { $note = 'Часть адресов уже занята правилом выше: ' + ($shadowed -join ', ') }
        $states += [pscustomobject]@{ id = $id; via = $via; state = $(if ($applied.Count) { 'applied' } elseif ($skippedWorkPrefix) { 'waiting' } else { 'error' }); reason = $note; prefixes = $prefixes }
    }
    [pscustomobject]@{ Desired = $desired; States = $states }
}
