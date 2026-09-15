@echo off
chcp 65001 >nul
setlocal EnableExtensions

rem ===================================== rem
rem Поисковик рандомного свободного порта rem
rem ===================================== rem

set "KEENETIC_SCHEME=http"
set "KEENETIC_HOST=192.168.1.1"
set "KEENETIC_PORT=80"
set "KEENETIC_USER=admin"
set "KEENETIC_PASSWORD=admin"

rem Диапазон подбора
set "PORT_MIN=1024"
set "PORT_MAX=65535"

rem Исключения. Например:
rem set "EXTRA_EXCLUDE=10000,12000-12100,25000"
set "EXTRA_EXCLUDE="

rem Проверять динамические UPnP пробросы: 1 = да, 0 = нет
set "CHECK_UPNP=1"

rem Разрешить кросс-подписанный HTTPS сертификат: 1 = да, 0 = нет
set "ALLOW_INSECURE_HTTPS=0"

rem Отладка: 1 = да, 0 = нет
set "DEBUG=0"

rem Пауза при ошибке: 1 = да, 0 = нет
set "PAUSE_AFTER=1"

set "SELF=%~f0"

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop';$raw=[IO.File]::ReadAllText($env:SELF,[Text.Encoding]::ASCII);$m=[regex]::Match($raw,'(?m)^#__POWERSHELL__\r?$');if(-not $m.Success){throw 'Embedded PowerShell block not found.'};$code=$raw.Substring($m.Index+$m.Length);& ([scriptblock]::Create($code))"
set "RC=%ERRORLEVEL%"

echo.
if "%PAUSE_AFTER%"=="1" pause
endlocal & exit /b %RC%

#__POWERSHELL__
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList @($false)

function U([string]$B64) {
    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($B64))
}

function Status-Log([string]$Text) {
    [Console]::Error.WriteLine($Text)
}

function Debug-Log([string]$Text) {
    if ($env:DEBUG -eq '1') {
        [Console]::Error.WriteLine('DEBUG: ' + $Text)
    }
}

function Fail([string]$Message) {
    [Console]::Error.WriteLine(((U '0J7QqNCY0JHQmtCQOiB7MH0=') -f $Message))
    exit 1
}

function Get-EnvInt([string]$Name, [int]$Default) {
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $Default
    }

    $n = 0
    if (-not [int]::TryParse($value, [ref]$n)) {
        Fail ($Name + ' must be an integer.')
    }
    return $n
}

function Get-HexHash([string]$Algorithm, [string]$Text) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)

    if ($Algorithm -eq 'MD5') {
        $hash = [Security.Cryptography.MD5]::Create()
    }
    elseif ($Algorithm -eq 'SHA256') {
        $hash = [Security.Cryptography.SHA256]::Create()
    }
    else {
        throw ('Unsupported hash algorithm: ' + $Algorithm)
    }

    try {
        return -join ($hash.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') })
    }
    finally {
        $hash.Dispose()
    }
}

function Get-Header($Response, [string]$Name) {
    foreach ($header in $Response.Headers) {
        if ($header.Key -ieq $Name) {
            return ($header.Value -join ',')
        }
    }

    if ($null -ne $Response.Content) {
        foreach ($header in $Response.Content.Headers) {
            if ($header.Key -ieq $Name) {
                return ($header.Value -join ',')
            }
        }
    }

    return $null
}

function Read-Body($Response) {
    return $Response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
}

function New-KeeneticHttpClient([bool]$UseCredentials) {
    $handler = New-Object -TypeName System.Net.Http.HttpClientHandler
    $handler.UseCookies = $true
    $handler.CookieContainer = New-Object -TypeName System.Net.CookieContainer
    $handler.AllowAutoRedirect = $true

    if ($UseCredentials) {
        $handler.Credentials = New-Object -TypeName System.Net.NetworkCredential -ArgumentList @($script:User, $script:Password)
        $handler.PreAuthenticate = $false
    }

    $client = New-Object -TypeName System.Net.Http.HttpClient -ArgumentList @($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(15)
    return $client
}

function Get-Http([string]$Path) {
    return $script:Client.GetAsync($script:BaseUrl + $Path).GetAwaiter().GetResult()
}

function Get-ConfigLines {
    # Prefer the raw live CLI configuration.
    $resp = Get-Http '/ci/running-config.txt'

    if ([int]$resp.StatusCode -eq 200) {
        $body = Read-Body $resp
        if (-not [string]::IsNullOrWhiteSpace($body)) {
            return @($body -split "`r?`n")
        }
    }
    elseif ([int]$resp.StatusCode -eq 401) {
        Fail 'Authorization failed while reading /ci/running-config.txt.'
    }

    Debug-Log 'Falling back to /rci/show/running-config'
    $resp2 = Get-Http '/rci/show/running-config'

    if ([int]$resp2.StatusCode -ne 200) {
        Fail (('Cannot read running configuration. HTTP {0}.') -f [int]$resp2.StatusCode)
    }

    $body2 = Read-Body $resp2

    try {
        $obj = $body2 | ConvertFrom-Json

        if ($obj -is [System.Array]) {
            $lines = New-Object 'System.Collections.Generic.List[string]'
            foreach ($item in $obj) {
                if ($null -ne $item) {
                    $lines.Add([string]$item)
                }
            }
            if ($lines.Count -gt 0) {
                return $lines.ToArray()
            }
        }

        if ($obj -is [string]) {
            return @($obj -split "`r?`n")
        }

        if ($null -ne $obj.PSObject.Properties['message']) {
            $message = $obj.message

            if ($message -is [System.Array]) {
                $lines = New-Object 'System.Collections.Generic.List[string]'
                foreach ($item in $message) {
                    if ($null -ne $item) {
                        $lines.Add([string]$item)
                    }
                }
                if ($lines.Count -gt 0) {
                    return $lines.ToArray()
                }
            }
            elseif ($message -is [string]) {
                return @($message -split "`r?`n")
            }
        }
    }
    catch {
        Debug-Log ('RCI running-config JSON parse failed: ' + $_.Exception.Message)
    }

    Fail 'The router returned running-config in an unsupported format.'
}
function Add-PortRange($Set, [int]$From, [int]$To) {
    if ($From -gt $To) {
        $temp = $From
        $From = $To
        $To = $temp
    }

    if ($From -lt 1) { $From = 1 }
    if ($To -gt 65535) { $To = 65535 }
    if ($From -gt 65535 -or $To -lt 1) { return }

    for ($p = $From; $p -le $To; $p++) {
        $null = $Set.Add($p)
    }
}

function Add-PortSpec($Set, [string]$Spec) {
    if ([string]::IsNullOrWhiteSpace($Spec)) {
        return
    }

    $s = $Spec.Trim()

    if ($s -match '^(\d{1,5})\s*-\s*(\d{1,5})$') {
        Add-PortRange $Set ([int]$matches[1]) ([int]$matches[2])
    }
    elseif ($s -match '^\d{1,5}$') {
        $p = [int]$s
        if ($p -ge 1 -and $p -le 65535) {
            $null = $Set.Add($p)
        }
    }
}

function Add-UpnpPorts($Node, $Set) {
    if ($null -eq $Node) {
        return
    }

    if ($Node -is [System.Array]) {
        foreach ($item in $Node) {
            Add-UpnpPorts $item $Set
        }
        return
    }

    if ($Node -is [System.Management.Automation.PSCustomObject]) {
        foreach ($prop in $Node.PSObject.Properties) {
            if ($prop.Name -match '(?i)^(port|external-port|external_port)$') {
                $p = 0
                if ([int]::TryParse([string]$prop.Value, [ref]$p)) {
                    if ($p -ge 1 -and $p -le 65535) {
                        $null = $Set.Add($p)
                    }
                }
            }
            Add-UpnpPorts $prop.Value $Set
        }
    }
}

try {
    Status-Log (U '0JfQsNC/0YPRgdC60LDRjiDQv9GA0L7QstC10YDQutGDINGB0LLQvtCx0L7QtNC90L7Qs9C+INC/0L7RgNGC0LAuLi4=')

    Add-Type -AssemblyName System.Net.Http

    $script:User = $env:KEENETIC_USER
    $script:Password = $env:KEENETIC_PASSWORD

    if ([string]::IsNullOrWhiteSpace($script:User)) {
        Fail 'KEENETIC_USER is empty.'
    }

    if ([string]::IsNullOrEmpty($script:Password)) {
        Status-Log (U '0J/QsNGA0L7Qu9GMINCw0LTQvNC40L3QuNGB0YLRgNCw0YLQvtGA0LAg0L3QtSDQt9Cw0LTQsNC9INCyINC90LDRgdGC0YDQvtC50LrQsNGFLiDQl9Cw0L/RgNCw0YjQuNCy0LDRjiDQv9Cw0YDQvtC70YwuLi4=')
        $secure = Read-Host 'Keenetic admin password' -AsSecureString
        $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        $script:Password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    }

    $scheme = $env:KEENETIC_SCHEME
    if ($scheme -notin @('http','https')) {
        Fail 'KEENETIC_SCHEME must be http or https.'
    }

    if ([string]::IsNullOrWhiteSpace($env:KEENETIC_HOST)) {
        Fail 'KEENETIC_HOST is empty.'
    }

    $apiPort = Get-EnvInt 'KEENETIC_PORT' 80
    if ($apiPort -lt 1 -or $apiPort -gt 65535) {
        Fail 'KEENETIC_PORT is out of range.'
    }

    $portMin = Get-EnvInt 'PORT_MIN' 1024
    $portMax = Get-EnvInt 'PORT_MAX' 65535
    if ($portMin -lt 1 -or $portMax -gt 65535 -or $portMin -gt $portMax) {
        Fail 'Invalid PORT_MIN/PORT_MAX range.'
    }

    $script:BaseUrl = '{0}://{1}:{2}' -f $scheme, $env:KEENETIC_HOST, $apiPort
    Status-Log ((U '0J/QvtC00LrQu9GO0YfQsNGO0YHRjCDQuiBLZWVuZXRpYzogezB9Li4u') -f $script:BaseUrl)

    if ($scheme -eq 'https' -and $env:ALLOW_INSECURE_HTTPS -eq '1') {
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
    }

    Status-Log (U '0JDQstGC0L7RgNC40LfRg9GO0YHRjC4uLg==')
    $script:Client = New-KeeneticHttpClient $false
    $auth = Get-Http '/auth'

    if ([int]$auth.StatusCode -eq 401) {
        $realm = Get-Header $auth 'X-NDM-Realm'
        $challenge = Get-Header $auth 'X-NDM-Challenge'
        $wwwAuth = Get-Header $auth 'WWW-Authenticate'

        if (-not [string]::IsNullOrWhiteSpace($realm) -and -not [string]::IsNullOrWhiteSpace($challenge)) {
            $md5 = Get-HexHash 'MD5' ($script:User + ':' + $realm + ':' + $script:Password)
            $key = Get-HexHash 'SHA256' ($challenge + $md5)
            $json = @{ login = $script:User; password = $key } | ConvertTo-Json -Compress
            $content = New-Object -TypeName System.Net.Http.StringContent -ArgumentList @($json, [Text.Encoding]::UTF8, 'application/json')
            $loginResp = $script:Client.PostAsync($script:BaseUrl + '/auth', $content).GetAwaiter().GetResult()

            if ([int]$loginResp.StatusCode -ne 200) {
                Fail (('Keenetic authentication failed. HTTP {0}.') -f [int]$loginResp.StatusCode)
            }

            Status-Log (U '0JDQstGC0L7RgNC40LfQsNGG0LjRjyDQstGL0L/QvtC70L3QtdC90LAu')
            Debug-Log 'Authenticated with x-ndw2-interactive.'
        }
        elseif ($wwwAuth -match '(?i)Digest') {
            $script:Client.Dispose()
            $script:Client = New-KeeneticHttpClient $true
            Status-Log (U '0JjRgdC/0L7Qu9GM0LfRg9GOIEhUVFAgRGlnZXN0LdCw0LLRgtC+0YDQuNC30LDRhtC40Y4u')
            Debug-Log 'Using HTTP Digest authentication.'
        }
        else {
            Fail 'Router returned 401 but no supported authentication challenge was found.'
        }
    }
    elseif ([int]$auth.StatusCode -eq 200) {
        Status-Log (U '0KHQvtC10LTQuNC90LXQvdC40LUg0YEgQVBJINGD0YHRgtCw0L3QvtCy0LvQtdC90L4u')
    }
    else {
        Debug-Log (('/auth returned HTTP {0}; trying HTTP Digest.' -f [int]$auth.StatusCode))
        $script:Client.Dispose()
        $script:Client = New-KeeneticHttpClient $true
        Status-Log (U '0JjRgdC/0L7Qu9GM0LfRg9GOIEhUVFAgRGlnZXN0LdCw0LLRgtC+0YDQuNC30LDRhtC40Y4u')
    }

    Status-Log (U '0J/QvtC70YPRh9Cw0Y4g0LrQvtC90YTQuNCz0YPRgNCw0YbQuNGOINGA0L7Rg9GC0LXRgNCwLi4u')
    $configLines = @(Get-ConfigLines)
    Status-Log ((U '0JrQvtC90YTQuNCz0YPRgNCw0YbQuNGPINC/0L7Qu9GD0YfQtdC90LA6IHswfSDRgdGC0YDQvtC6Lg==') -f $configLines.Count)

    Status-Log (U '0J/QvtC70YPRh9Cw0Y4g0YHQv9C40YHQvtC6INC30LDQvdGP0YLRi9GFINC/0L7RgNGC0L7QsiDQuNC3INC/0YDQsNCy0LjQuyDQv9C10YDQtdCw0LTRgNC10YHQsNGG0LjQuC4uLg==')
    $occupied = New-Object 'System.Collections.Generic.HashSet[int]'

    foreach ($line in $configLines) {
        $s = ([string]$line).Trim()

        if ($s -notmatch '^ip\s+static\s+(?:tcp|udp)\s+') {
            continue
        }

        $tokens = $s -split '\s+'

        for ($i = 3; $i -lt $tokens.Count; $i++) {
            if ($tokens[$i] -match '^\d{1,5}$') {
                $first = [int]$tokens[$i]

                if ($first -lt 1 -or $first -gt 65535) {
                    continue
                }

                if (($i + 2) -lt $tokens.Count -and
                    $tokens[$i + 1] -ieq 'through' -and
                    $tokens[$i + 2] -match '^\d{1,5}$') {
                    Add-PortRange $occupied $first ([int]$tokens[$i + 2])
                }
                else {
                    $null = $occupied.Add($first)
                }

                break
            }
        }
    }

    Status-Log ((U '0KHRgtCw0YLQuNGH0LXRgdC60LjQtSDQv9GA0LDQstC40LvQsCDQvtCx0YDQsNCx0L7RgtCw0L3Riy4g0JfQsNC90Y/RgtC+INC/0L7RgNGC0L7QsjogezB9Lg==') -f $occupied.Count)

    if ($env:CHECK_UPNP -ne '0') {
        Status-Log (U '0J/RgNC+0LLQtdGA0Y/RjiDQtNC40L3QsNC80LjRh9C10YHQutC40LUgVVBuUC3Qv9GA0L7QsdGA0L7RgdGLLi4u')

        try {
            $upnpResp = Get-Http '/rci/show/upnp/redirect'

            if ([int]$upnpResp.StatusCode -eq 200) {
                $upnpText = Read-Body $upnpResp

                if (-not [string]::IsNullOrWhiteSpace($upnpText)) {
                    $upnpObj = $upnpText | ConvertFrom-Json
                    Add-UpnpPorts $upnpObj $occupied
                }
            }
            elseif ([int]$upnpResp.StatusCode -ne 404) {
                Debug-Log (('UPnP endpoint returned HTTP {0}; continuing.' -f [int]$upnpResp.StatusCode))
            }
        }
        catch {
            Debug-Log ('UPnP check failed; continuing: ' + $_.Exception.Message)
        }

        Status-Log ((U '0J/RgNC+0LLQtdGA0LrQsCBVUG5QINC30LDQstC10YDRiNC10L3QsC4g0JLRgdC10LPQviDQt9Cw0L3Rj9GC0L4g0L/QvtGA0YLQvtCyOiB7MH0u') -f $occupied.Count)
    }
    else {
        Status-Log (U '0J/RgNC+0LLQtdGA0LrQsCBVUG5QINC+0YLQutC70Y7Rh9C10L3QsC4=')
    }

    Status-Log (U '0KTQvtGA0LzQuNGA0YPRjiDRgdC/0LjRgdC+0Log0YHQu9GD0LbQtdCx0L3Ri9GFINC4INC30LDRgNC10LfQtdGA0LLQuNGA0L7QstCw0L3QvdGL0YUg0L/QvtGA0YLQvtCyLdC40YHQutC70Y7Rh9C10L3QuNC5Li4u')
    $excluded = New-Object 'System.Collections.Generic.HashSet[int]'

    $defaultExclude = @(
        '20-23',
        '25',
        '53',
        '67-69',
        '80',
        '110',
        '123',
        '135-139',
        '143',
        '161-162',
        '389',
        '443',
        '445',
        '465',
        '500',
        '514',
        '587',
        '631',
        '636',
        '853',
        '993',
        '995',
        '1194',
        '1433',
        '1521',
        '1701',
        '1723',
        '1812-1813',
        '1883',
        '1900',
        '2049',
        '2375-2376',
        '3306',
        '3389',
        '3478-3481',
        '4500',
        '5000',
        '5060-5061',
        '5353',
        '5355',
        '5432',
        '5672',
        '5900',
        '6379',
        '8000',
        '8080-8081',
        '8443',
        '8883',
        '9000',
        '9092',
        '9100',
        '9200',
        '11211',
        '27017',
        '32400',
        '51820'
    )

    foreach ($spec in $defaultExclude) {
        Add-PortSpec $excluded $spec
    }

    $null = $excluded.Add($apiPort)

    foreach ($line in $configLines) {
        $s = ([string]$line).Trim()

        if ($s -match '^ip\s+http\s+port\s+(\d{1,5})\b' -or
            $s -match '^ip\s+http\s+ssl\s+port\s+(\d{1,5})\b' -or
            $s -match '^ip\s+ssh\s+port\s+(\d{1,5})\b' -or
            $s -match '^ip\s+telnet\s+port\s+(\d{1,5})\b' -or
            $s -match '^listen-port\s+(\d{1,5})\b') {

            $p = [int]$matches[1]
            if ($p -ge 1 -and $p -le 65535) {
                $null = $excluded.Add($p)
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($env:EXTRA_EXCLUDE)) {
        Status-Log (U '0JTQvtCx0LDQstC70Y/RjiDQv9C+0LvRjNC30L7QstCw0YLQtdC70YzRgdC60LjQtSDQuNGB0LrQu9GO0YfQtdC90LjRjy4uLg==')
        foreach ($spec in ($env:EXTRA_EXCLUDE -split '[,;]')) {
            Add-PortSpec $excluded $spec
        }
    }

    Status-Log ((U '0JjRgdC60LvRjtGH0LXQvdC+INGB0LvRg9C20LXQsdC90YvRhS/Qt9Cw0YDQtdC30LXRgNCy0LjRgNC+0LLQsNC90L3Ri9GFINC/0L7RgNGC0L7QsjogezB9Lg==') -f $excluded.Count)
    Status-Log ((U '0KTQvtGA0LzQuNGA0YPRjiDRgdC/0LjRgdC+0Log0YHQstC+0LHQvtC00L3Ri9GFINC/0L7RgNGC0L7QsiDQsiDQtNC40LDQv9Cw0LfQvtC90LUgezB9LXsxfS4uLg==') -f $portMin, $portMax)

    $free = New-Object 'System.Collections.Generic.List[int]'

    for ($p = $portMin; $p -le $portMax; $p++) {
        if (-not $occupied.Contains($p) -and -not $excluded.Contains($p)) {
            $free.Add($p)
        }
    }

    Debug-Log (('Occupied ports: {0}' -f $occupied.Count))
    Debug-Log (('Excluded ports: {0}' -f $excluded.Count))
    Debug-Log (('Free candidates: {0}' -f $free.Count))

    if ($free.Count -eq 0) {
        Fail 'No free port remains in the selected range.'
    }

    Status-Log ((U '0J3QsNC50LTQtdC90L4g0YHQstC+0LHQvtC00L3Ri9GFINC60LDQvdC00LjQtNCw0YLQvtCyOiB7MH0u') -f $free.Count)
    Status-Log (U '0JLRi9Cx0LjRgNCw0Y4g0YHQu9GD0YfQsNC50L3Ri9C5INC/0L7Qu9C90L7RgdGC0YzRjiDRgdCy0L7QsdC+0LTQvdGL0Lkg0L/QvtGA0YIuLi4=')

    $index = Get-Random -Minimum 0 -Maximum $free.Count
    $selectedPort = $free[$index]

    Status-Log (U '0JPQvtGC0L7QstC+LiDQktGL0LHRgNCw0L0g0YHQstC+0LHQvtC00L3Ri9C5INC/0L7RgNGCOg==')
    [Console]::Out.WriteLine($selectedPort)
}
catch {
    Fail $_.Exception.Message
}
finally {
    if ($null -ne $script:Client) {
        $script:Client.Dispose()
    }
}
