param()
# Opens the RouteGuard web panel in the default browser for the current user.
# Prefers http://vpn.localhost/ and falls back to http://127.0.0.1:47123/.
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
Add-Type -AssemblyName System.Windows.Forms

function Test-PanelHost {
    param([int]$Port, [string]$HostHeader)
    try {
        $request = [Net.WebRequest]::Create("http://127.0.0.1:$Port/favicon.svg")
        $request.Host = $HostHeader
        $request.Proxy = $null
        $request.AllowAutoRedirect = $false
        $request.Timeout = 1000
        $response = $request.GetResponse()
        try { return ([int]$response.StatusCode -eq 200 -and $response.Headers['X-VPN-Routes'] -eq '1') }
        finally { $response.Dispose() }
    } catch [Net.WebException] {
        if ($_.Exception.Response) { $_.Exception.Response.Dispose() }
        return $false
    }
}

try {
    $config = Get-Content -LiteralPath (Join-Path $root 'RouteGuard.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $port = 47123
    if ($null -ne $config.PSObject.Properties['PanelPort']) { $port = [int]$config.PanelPort }
    $panelHost = 'vpn.localhost'
    if ($null -ne $config.PSObject.Properties['PanelHost']) { $panelHost = [string]$config.PanelHost }
    $token = ([string](Get-Content -LiteralPath (Join-Path $root 'panel-token.txt') -Raw)).Trim()
    $url = $null
    for ($i = 0; $i -lt 10 -and -not $url; $i++) {
        if (Test-PanelHost 80 $panelHost) { $url = "http://$panelHost/" }
        elseif (Test-PanelHost $port "127.0.0.1:$port") { $url = "http://127.0.0.1:$port/" }
        else { Start-Sleep -Milliseconds 500 }
    }
    if (-not $url) { throw 'Панель не отвечает. Подождите минуту и снова откройте ярлык.' }
    Start-Process ($url + '#t=' + $token)
} catch {
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Маршруты VPN', 'OK', 'Warning') | Out-Null
    exit 1
}
