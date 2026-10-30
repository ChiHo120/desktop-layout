# Cursor quota helpers. Credentials are read locally and never written or logged.

function New-CursorQuotaResult {
    param([string]$State, [string]$Text, [string]$Detail, $RemainingPercent = $null, [DateTime]$UpdatedAt = (Get-Date), $Buckets = $null)
    $result = @{ State = $State; Text = $Text; Detail = $Detail; RemainingPercent = $RemainingPercent; UpdatedAt = $UpdatedAt }
    if ($null -ne $Buckets) { $result.Buckets = $Buckets }
    return $result
}

function New-CursorQuotaBucket {
    param([string]$State, [string]$Text, $RemainingPercent = $null, [string]$Detail = '')
    return @{ State = $State; Text = $Text; Detail = $Detail; RemainingPercent = $RemainingPercent }
}

function Get-CursorQuotaField {
    param([AllowNull()]$Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $null
}

function ConvertTo-CursorQuotaNumber {
    param([AllowNull()]$Value)
    if ($null -eq $Value -or $Value -is [bool]) { return $null }
    $number = 0.0
    if (-not [double]::TryParse([string]$Value, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$number)) { return $null }
    if ([double]::IsNaN($number) -or [double]::IsInfinity($number) -or $number -lt 0) { return $null }
    return $number
}

function Format-CursorQuotaMoney {
    param([double]$Cents)
    return ('$' + ($Cents / 100).ToString('N2', [System.Globalization.CultureInfo]::InvariantCulture))
}

function Format-CursorQuotaPercent {
    param([double]$Percent)
    return $Percent.ToString('0.##', [System.Globalization.CultureInfo]::InvariantCulture) + '%'
}

function ConvertTo-CursorQuotaDate {
    param([AllowNull()]$Value)
    if ($Value -is [DateTimeOffset]) { return $Value }
    if ($Value -is [DateTime]) { return [DateTimeOffset]$Value }
    if ($Value -isnot [string]) { return $null }
    $parsed = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse($Value, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$parsed)) {
        return $parsed
    }
    return $null
}

function Get-CursorQuotaBalance {
    param([AllowNull()]$Quota, [switch]$AllowPercent)
    $used = ConvertTo-CursorQuotaNumber (Get-CursorQuotaField $Quota 'used')
    $limit = ConvertTo-CursorQuotaNumber (Get-CursorQuotaField $Quota 'limit')
    $remaining = ConvertTo-CursorQuotaNumber (Get-CursorQuotaField $Quota 'remaining')
    $enabled = Get-CursorQuotaField $Quota 'enabled'
    if ($enabled -is [bool] -and -not $enabled) {
        return @{ Available = $false; Used = $null; Limit = $null; Remaining = $null; Percent = $null }
    }
    if ($AllowPercent) {
        # Current Cursor plans expose normalized total / Auto / API buckets.
        # The legacy money fields can be capped at their allowance while these
        # buckets still have usage available; never infer a current dollar balance.
        $percentages = @{}
        foreach ($bucket in @('total', 'auto', 'api')) {
            $percentUsed = ConvertTo-CursorQuotaNumber (Get-CursorQuotaField $Quota ($bucket + 'PercentUsed'))
            if ($null -ne $percentUsed) {
                $percentages[$bucket] = [math]::Round([math]::Max(0.0, 100.0 - $percentUsed), 2)
            }
        }
        foreach ($bucket in @('total', 'auto', 'api')) {
            if ($percentages.ContainsKey($bucket)) {
                return @{ Available = $true; Used = $null; Limit = $null; Remaining = $null; Percent = $percentages[$bucket]; Source = 'percentage'; Bucket = $bucket; Percentages = $percentages }
            }
        }
    }
    if ($null -eq $remaining -and $null -ne $limit -and $null -ne $used) {
        $remaining = [math]::Max(0.0, $limit - $used)
    }
    $percent = $null
    if ($null -ne $remaining -and $null -ne $limit -and $limit -gt 0) {
        $percent = [math]::Round([math]::Min(100.0, ($remaining / $limit) * 100), 1)
    }
    return @{ Available = ($null -ne $remaining -or $null -ne $percent); Used = $used; Limit = $limit; Remaining = $remaining; Percent = $percent; Source = 'money' }
}

function ConvertFrom-CursorQuota {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()]$Response, [DateTime]$UpdatedAt = (Get-Date))

    $unknownText = '套餐剩余未知'
    $unknownDetail = 'Cursor 未提供可识别的剩余额度'
    $buckets = @{
        Auto = (New-CursorQuotaBucket 'unsupported' '暂无额度数据')
        Advanced = (New-CursorQuotaBucket 'unsupported' '暂无额度数据')
        Grok = (New-CursorQuotaBucket 'unsupported' '接口未提供独立额度' $null '当前周期额度接口未提供独立字段')
    }
    if ($Response -is [string]) {
        try { $Response = ConvertFrom-Json -InputObject $Response -ErrorAction Stop }
        catch { return (New-CursorQuotaResult 'unsupported' $unknownText $unknownDetail -UpdatedAt $UpdatedAt -Buckets $buckets) }
    }
    if ($null -eq $Response) { return (New-CursorQuotaResult 'unsupported' $unknownText $unknownDetail -UpdatedAt $UpdatedAt -Buckets $buckets) }

    $individual = Get-CursorQuotaField $Response 'individualUsage'
    $team = Get-CursorQuotaField $Response 'teamUsage'
    $plan = Get-CursorQuotaField $individual 'plan'
    $candidates = @(
        @{ Label = '套餐'; Quota = $plan; AllowPercent = $true },
        @{ Label = '个人上限'; Quota = (Get-CursorQuotaField $individual 'overall'); AllowPercent = $false },
        @{ Label = '团队共享'; Quota = (Get-CursorQuotaField $team 'pooled'); AllowPercent = $false }
    )
    $details = New-Object System.Collections.Generic.List[string]
    $selected = $null
    $selectedLabel = ''
    foreach ($candidate in $candidates) {
        $balance = Get-CursorQuotaBalance $candidate.Quota -AllowPercent:$candidate.AllowPercent
        if ($balance.Available) {
            $selected = $balance
            $selectedLabel = $candidate.Label
            break
        }
    }
    if ($null -ne $selected) {
        if ($selected.Source -eq 'percentage') {
            if ($selected.Bucket -eq 'total') { $selectedLabel = '总额度' }
            elseif ($selected.Bucket -eq 'auto') { $selectedLabel = 'Auto' }
            elseif ($selected.Bucket -eq 'api') { $selectedLabel = 'API' }
            foreach ($bucket in @('total', 'auto', 'api')) {
                if ($selected.Percentages.ContainsKey($bucket)) {
                    $label = @{ total = '总额度'; auto = 'Auto'; api = 'API' }[$bucket]
                    $details.Add(($label + '剩余 ' + (Format-CursorQuotaPercent $selected.Percentages[$bucket])))
                }
            }
            if ($selected.Percentages.ContainsKey('auto')) {
                $autoPercent = $selected.Percentages['auto']
                $buckets.Auto = New-CursorQuotaBucket 'ok' ('剩余 ' + (Format-CursorQuotaPercent $autoPercent)) $autoPercent 'Cursor Auto 当前周期'
            }
            if ($selected.Percentages.ContainsKey('api')) {
                $apiPercent = $selected.Percentages['api']
                $buckets.Advanced = New-CursorQuotaBucket 'ok' ('剩余 ' + (Format-CursorQuotaPercent $apiPercent)) $apiPercent 'Cursor 高级模型/API 当前周期'
            }
            if (-not $selected.Percentages.ContainsKey('total')) { $details.Add('总额度比例未提供；未合并独立用量池') }
            $breakdown = Get-CursorQuotaField $plan 'breakdown'
            $bonus = ConvertTo-CursorQuotaNumber (Get-CursorQuotaField $breakdown 'bonus')
            $included = ConvertTo-CursorQuotaNumber (Get-CursorQuotaField $breakdown 'included')
            $combined = ConvertTo-CursorQuotaNumber (Get-CursorQuotaField $breakdown 'total')
            if ($null -ne $bonus -and $bonus -gt 0) {
                $details.Add(('奖励额度 ' + (Format-CursorQuotaMoney $bonus)))
            }
            if ($null -ne $included -and $null -ne $combined -and $combined -gt $included) {
                $details.Add(('包含额度 ' + (Format-CursorQuotaMoney $included) + ' · 合计额度 ' + (Format-CursorQuotaMoney $combined)))
            }
        }
        if ($null -ne $selected.Limit) { $details.Add(('{0}上限 {1}' -f $selectedLabel, (Format-CursorQuotaMoney $selected.Limit))) }
        if ($null -ne $selected.Used) { $details.Add(('已用 {0}' -f (Format-CursorQuotaMoney $selected.Used))) }
        if ($selectedLabel -eq '团队共享') { $details.Add('团队共用额度，非个人余额') }
    }

    # On-demand spending does not reduce or describe the included-plan balance.
    foreach ($demand in @(
        @{ Label = '按量'; Quota = (Get-CursorQuotaField $individual 'onDemand') },
        @{ Label = '团队按量'; Quota = (Get-CursorQuotaField $team 'onDemand') }
    )) {
        $demandEnabled = Get-CursorQuotaField $demand.Quota 'enabled'
        if ($demandEnabled -is [bool] -and -not $demandEnabled) { continue }
        $demandUsed = ConvertTo-CursorQuotaNumber (Get-CursorQuotaField $demand.Quota 'used')
        $demandLimit = ConvertTo-CursorQuotaNumber (Get-CursorQuotaField $demand.Quota 'limit')
        if ($null -ne $demandUsed) {
            $line = '{0}已用 {1}' -f $demand.Label, (Format-CursorQuotaMoney $demandUsed)
            if ($null -ne $demandLimit) { $line += ' / 上限 ' + (Format-CursorQuotaMoney $demandLimit) }
            $details.Add($line)
        }
    }
    $cycleStart = ConvertTo-CursorQuotaDate (Get-CursorQuotaField $Response 'billingCycleStart')
    $cycleEnd = ConvertTo-CursorQuotaDate (Get-CursorQuotaField $Response 'billingCycleEnd')
    if ($null -ne $cycleEnd) {
        $endText = $cycleEnd.ToLocalTime().ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
        if ($null -ne $cycleStart -and $cycleStart -lt $cycleEnd) {
            $startText = $cycleStart.ToLocalTime().ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
            $details.Add(('周期 {0} 至 {1}' -f $startText, $endText))
        } else { $details.Add(('周期截至 {0}' -f $endText)) }
    }
    if ($null -ne $selected -and $selected.Source -eq 'percentage') {
        $details.Add('按 Cursor 当前比例显示；不从旧金额字段推算美元余额')
    }
    if ($null -eq $selected) {
        $details.Insert(0, $unknownDetail)
        return (New-CursorQuotaResult 'unsupported' $unknownText ($details -join ' · ') -UpdatedAt $UpdatedAt -Buckets $buckets)
    }
    if ($null -ne $selected.Remaining) {
        $text = $selectedLabel + '余 ' + (Format-CursorQuotaMoney $selected.Remaining)
    } else {
        $text = $selectedLabel + '余 ' + (Format-CursorQuotaPercent $selected.Percent)
    }
    return (New-CursorQuotaResult 'ok' $text ($details -join ' · ') -RemainingPercent $selected.Percent -UpdatedAt $UpdatedAt -Buckets $buckets)
}

function Initialize-CursorQuotaSqlite {
    if ('SpiritQuota.CursorSqlite' -as [type]) { return }
    $source = @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

namespace SpiritQuota {
    public static class CursorSqlite {
        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_open_v2(byte[] filename, out IntPtr db, int flags, IntPtr vfs);
        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_busy_timeout(IntPtr db, int milliseconds);
        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_prepare_v2(IntPtr db, byte[] sql, int bytes, out IntPtr statement, IntPtr tail);
        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_step(IntPtr statement);
        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_column_type(IntPtr statement, int column);
        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern IntPtr sqlite3_column_blob(IntPtr statement, int column);
        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_column_bytes(IntPtr statement, int column);
        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_finalize(IntPtr statement);
        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_close(IntPtr db);

        public static string ReadAccessToken(string path) {
            IntPtr db = IntPtr.Zero;
            IntPtr statement = IntPtr.Zero;
            try {
                // SQLITE_OPEN_READONLY. Query only the explicitly authorized key.
                int code = sqlite3_open_v2(Encoding.UTF8.GetBytes(path + "\0"), out db, 1, IntPtr.Zero);
                if (code != 0) throw new InvalidOperationException("Cursor credential store unavailable.");
                sqlite3_busy_timeout(db, 1200);
                byte[] sql = Encoding.UTF8.GetBytes("SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken' LIMIT 1;\0");
                code = sqlite3_prepare_v2(db, sql, sql.Length, out statement, IntPtr.Zero);
                if (code != 0) throw new InvalidOperationException("Cursor credential query unavailable.");
                code = sqlite3_step(statement);
                if (code == 101) return null;
                if (code != 100) throw new InvalidOperationException("Cursor credential read unavailable.");
                int type = sqlite3_column_type(statement, 0);
                if (type == 5) return null;
                if (type != 3 && type != 4) return null;
                IntPtr value = sqlite3_column_blob(statement, 0);
                int length = sqlite3_column_bytes(statement, 0);
                if (value == IntPtr.Zero || length <= 0 || length > 65536) return null;
                byte[] data = new byte[length];
                Marshal.Copy(value, data, 0, length);
                try {
                    bool utf16 = length % 2 == 0;
                    for (int i = 0; utf16 && i < length; i += 2) {
                        if (data[i] == 0 || data[i] > 127 || data[i + 1] != 0) utf16 = false;
                    }
                    return (utf16 ? Encoding.Unicode : Encoding.UTF8).GetString(data).TrimEnd('\0');
                } finally {
                    Array.Clear(data, 0, data.Length);
                }
            } finally {
                if (statement != IntPtr.Zero) sqlite3_finalize(statement);
                if (db != IntPtr.Zero) sqlite3_close(db);
            }
        }
    }
}
'@
    try { Add-Type -TypeDefinition $source -Language CSharp -ErrorAction Stop }
    catch { if (-not ('SpiritQuota.CursorSqlite' -as [type])) { throw 'Cursor SQLite reader unavailable.' } }
}

function ConvertTo-CursorSessionCookie {
    param([AllowNull()][AllowEmptyString()][string]$AccessToken, [DateTime]$Now = [DateTime]::UtcNow)
    if ([string]::IsNullOrWhiteSpace($AccessToken) -or $AccessToken.Length -gt 65536) { return $null }
    if ($AccessToken -notmatch '^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$') { return $null }
    try {
        $payload = $AccessToken.Split('.')[1].Replace('-', '+').Replace('_', '/')
        $payload += '=' * ((4 - ($payload.Length % 4)) % 4)
        $claims = ConvertFrom-Json -InputObject ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload))) -ErrorAction Stop
        $subject = Get-CursorQuotaField $claims 'sub'
        if ($subject -isnot [string]) { return $null }
        $parts = $subject.Split([char[]]'|', [StringSplitOptions]::RemoveEmptyEntries)
        if ($parts.Length -eq 0) { return $null }
        $userId = $parts[$parts.Length - 1]
        if ($userId -notmatch '^[A-Za-z0-9._-]+$') { return $null }
        $expires = ConvertTo-CursorQuotaNumber (Get-CursorQuotaField $claims 'exp')
        $epoch = [DateTime]::SpecifyKind([DateTime]'1970-01-01', [DateTimeKind]::Utc)
        if ($null -eq $expires -or $expires -le ($Now.ToUniversalTime() - $epoch).TotalSeconds + 60) { return $null }
        return ('WorkosCursorSessionToken=' + $userId + '%3A%3A' + $AccessToken)
    } catch { return $null }
}

function ConvertFrom-CursorGrokQuota {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()]$Response)

    $unknown = New-CursorQuotaBucket 'unsupported' 'Grok Bot 额度不可用' $null 'Grok Bot 周额度接口暂不可用'
    if ($Response -is [string]) {
        try { $Response = ConvertFrom-Json -InputObject $Response -ErrorAction Stop }
        catch { return $unknown }
    }
    if ($null -eq $Response) { return $unknown }

    $hasIncludedLimit = Get-CursorQuotaField $Response 'hasNonZeroIncludedLimit'
    if ($hasIncludedLimit -is [bool] -and -not $hasIncludedLimit) {
        return (New-CursorQuotaBucket 'unsupported' '未包含周额度' $null '当前账户未包含 Grok Bot 周额度')
    }

    $available = Get-CursorQuotaField $Response 'hasAvailableUsage'
    $usage = ConvertTo-CursorQuotaNumber (Get-CursorQuotaField $Response 'usagePercent')
    $confirmedExhausted = ($hasIncludedLimit -is [bool] -and $hasIncludedLimit -and $available -is [bool] -and -not $available)
    if ($null -eq $usage -and -not $confirmedExhausted) { return $unknown }
    # The Cursor page clamps this display value to [0, 100].  Preserve the
    # server's percentage semantics and calculate a separate remaining value.
    if ($confirmedExhausted) { $remaining = 0.0 }
    else {
        $usage = [math]::Min(100.0, $usage)
        $remaining = [math]::Round([math]::Max(0.0, 100.0 - $usage), 2)
    }

    $details = New-Object System.Collections.Generic.List[string]
    $details.Add('Grok Bot 周额度')
    $planLabel = Get-CursorQuotaField $Response 'grokPlanLabel'
    if ($planLabel -is [string] -and -not [string]::IsNullOrWhiteSpace($planLabel)) {
        $details.Add([string]$planLabel)
    }
    $periodStart = ConvertTo-CursorQuotaDate (Get-CursorQuotaField $Response 'currentPeriodStart')
    $resetAt = ConvertTo-CursorQuotaDate (Get-CursorQuotaField $Response 'nextResetTimestampUtc')
    if ($null -ne $periodStart -and $null -ne $resetAt -and $periodStart -lt $resetAt) {
        $startText = $periodStart.ToLocalTime().ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
        $resetText = $resetAt.ToLocalTime().ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
        $details.Add(('周期 {0} 至 {1}' -f $startText, $resetText))
    } elseif ($null -ne $periodStart) {
        $details.Add(('周期开始 {0}' -f $periodStart.ToLocalTime().ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)))
    }
    if ($null -ne $resetAt) {
        $details.Add(('重置 {0}（本地时间）' -f $resetAt.ToLocalTime().ToString('yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)))
    } else {
        $details.Add('每周重置时间未知')
    }
    if ($available -is [bool] -and -not $available) { $details.Add('当前周期已无可用额度') }
    $state = 'ok'
    if ($remaining -le 0) { $state = 'window-exhausted' }
    return (New-CursorQuotaBucket $state ('剩余 ' + (Format-CursorQuotaPercent $remaining)) $remaining ($details -join ' · '))
}

function Get-CursorGrokQuota {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Cookie)

    $response = $null
    $reader = $null
    try {
        if ([string]::IsNullOrWhiteSpace($Cookie)) {
            return (New-CursorQuotaBucket 'unsupported' 'Grok Bot 额度不可用' $null 'Grok Bot 接口未授权')
        }
        $request = [System.Net.HttpWebRequest]::Create('https://cursor.com/api/dashboard/get-sand-usage-status')
        $request.Method = 'POST'
        $request.Accept = 'application/json'
        $request.ContentType = 'application/json'
        $request.UserAgent = 'DesktopSpiritQuota/1.0'
        $request.CookieContainer = New-Object System.Net.CookieContainer
        $cookieParts = $Cookie.Split([char[]]'=', 2)
        if ($cookieParts.Length -ne 2 -or [string]::IsNullOrWhiteSpace($cookieParts[0]) -or [string]::IsNullOrWhiteSpace($cookieParts[1])) {
            return (New-CursorQuotaBucket 'unsupported' 'Grok Bot 额度不可用' $null 'Grok Bot 接口未授权')
        }
        $sessionCookie = New-Object System.Net.Cookie
        $sessionCookie.Name = $cookieParts[0]
        $sessionCookie.Value = $cookieParts[1]
        $sessionCookie.Path = '/'
        $sessionCookie.Domain = 'cursor.com'
        $request.CookieContainer.Add($sessionCookie)
        # The web dashboard requires same-origin request metadata in addition
        # to the session cookie. The request never follows redirects.
        $request.Headers['Origin'] = 'https://cursor.com'
        $request.Referer = 'https://cursor.com/dashboard/spending'
        $request.Headers['Sec-Fetch-Site'] = 'same-origin'
        $request.Headers['Sec-Fetch-Mode'] = 'cors'
        $request.Headers['Sec-Fetch-Dest'] = 'empty'
        $request.Headers['Accept-Language'] = 'zh-CN,zh;q=0.9,en;q=0.8'
        $request.AllowAutoRedirect = $false
        $request.Timeout = 8000
        $request.ReadWriteTimeout = 8000
        $request.MaximumResponseHeadersLength = 64
        $body = [Text.Encoding]::UTF8.GetBytes('{}')
        $request.ContentLength = $body.Length
        $requestStream = $request.GetRequestStream()
        try { $requestStream.Write($body, 0, $body.Length) } finally { $requestStream.Dispose() }
        $response = $request.GetResponse()
        if ([int]$response.StatusCode -ne 200) {
            return (New-CursorQuotaBucket 'error' 'Grok Bot 额度不可用' $null 'Grok Bot 接口暂不可用')
        }
        $reader = New-Object System.IO.StreamReader($response.GetResponseStream(), [Text.Encoding]::UTF8)
        $buffer = New-Object char[] 131073
        $length = $reader.ReadBlock($buffer, 0, $buffer.Length)
        if ($length -gt 131072) {
            return (New-CursorQuotaBucket 'unsupported' 'Grok Bot 额度不可用' $null 'Grok Bot 接口返回了未知格式')
        }
        return (ConvertFrom-CursorGrokQuota ([string]::new($buffer, 0, $length)))
    } catch {
        $status = 0
        try {
            $failure = $_.Exception
            for ($depth = 0; $depth -lt 5 -and $null -ne $failure; $depth++) {
                if ($failure -is [System.Net.WebException] -and $null -ne $failure.Response) {
                    $response = $failure.Response
                    $status = [int]$response.StatusCode
                    break
                }
                $failure = $failure.InnerException
            }
        } catch {}
        if ($status -eq 401 -or $status -eq 403) {
            return (New-CursorQuotaBucket 'unsupported' 'Grok Bot 额度不可用' $null 'Grok Bot 接口未授权或会话已失效')
        }
        if ($status -eq 429) {
            return (New-CursorQuotaBucket 'rate-limited' 'Grok Bot 额度不可用' $null 'Grok Bot 请求过于频繁')
        }
        return (New-CursorQuotaBucket 'error' 'Grok Bot 额度不可用' $null 'Grok Bot 接口暂不可用')
    } finally {
        if ($null -ne $reader) { $reader.Dispose() }
        if ($null -ne $response) { $response.Close() }
    }
}

function Get-CursorQuota {
    [CmdletBinding()]
    param()

    $accessToken = $null
    $cookie = $null
    $response = $null
    $reader = $null
    try {
        $dbPath = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'Cursor\User\globalStorage\state.vscdb'
        if (-not [IO.File]::Exists($dbPath)) {
            return (New-CursorQuotaResult 'auth' '请登录 Cursor' '未找到本机 Cursor 登录信息')
        }
        try {
            Initialize-CursorQuotaSqlite
            $accessToken = [SpiritQuota.CursorSqlite]::ReadAccessToken($dbPath)
        } catch {
            return (New-CursorQuotaResult 'error' 'Cursor 暂不可用' '无法读取本机 Cursor 登录信息，稍后自动重试')
        }
        if ($accessToken -and $accessToken.StartsWith('cursor-safe-storage:', [StringComparison]::Ordinal)) {
            return (New-CursorQuotaResult 'unsupported' '登录存储暂不支持' '此版本 Cursor 使用了加密登录存储')
        }
        $cookie = ConvertTo-CursorSessionCookie $accessToken
        if ([string]::IsNullOrEmpty($cookie)) {
            return (New-CursorQuotaResult 'auth' '请重新登录 Cursor' '本机 Cursor 登录信息缺失或已过期')
        }
        # Fixed HTTPS origin and no redirects prevent sending the cookie elsewhere.
        $request = [System.Net.HttpWebRequest]::Create('https://cursor.com/api/usage-summary')
        $request.Method = 'GET'
        $request.Accept = 'application/json'
        $request.UserAgent = 'DesktopSpiritQuota/1.0'
        $request.CookieContainer = New-Object System.Net.CookieContainer
        $cookieParts = $cookie.Split([char[]]'=', 2)
        $sessionCookie = New-Object System.Net.Cookie
        $sessionCookie.Name = $cookieParts[0]
        $sessionCookie.Value = $cookieParts[1]
        $sessionCookie.Path = '/'
        $sessionCookie.Domain = 'cursor.com'
        $request.CookieContainer.Add($sessionCookie)
        $request.AllowAutoRedirect = $false
        $request.Timeout = 8000
        $request.ReadWriteTimeout = 8000
        $request.MaximumResponseHeadersLength = 64
        $request.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
        $response = $request.GetResponse()
        if ([int]$response.StatusCode -ne 200) {
            return (New-CursorQuotaResult 'error' 'Cursor 暂不可用' '额度接口暂不可用，稍后自动重试')
        }
        $reader = New-Object System.IO.StreamReader($response.GetResponseStream(), [Text.Encoding]::UTF8)
        $buffer = New-Object char[] 262145
        $length = $reader.ReadBlock($buffer, 0, $buffer.Length)
        if ($length -gt 262144) {
            return (New-CursorQuotaResult 'unsupported' '套餐剩余未知' 'Cursor 额度接口返回了未知格式')
        }
        $result = ConvertFrom-CursorQuota ([string]::new($buffer, 0, $length))
        # Grok Bot has a separate weekly pool. A failure here must not hide a
        # valid Cursor total/Auto/API response, so keep it as an independent
        # bucket and leave the primary result state unchanged.
        $grok = Get-CursorGrokQuota -Cookie $cookie
        if ($null -eq $result.Buckets) {
            $result.Buckets = @{
                Auto = New-CursorQuotaBucket 'unsupported' '暂无额度数据'
                Advanced = New-CursorQuotaBucket 'unsupported' '暂无额度数据'
                Grok = $grok
            }
        } else {
            $result.Buckets.Grok = $grok
        }
        if ($grok.State -eq 'ok') {
            $result.Detail = $result.Detail + ' · Grok Bot ' + $grok.Text + ' · ' + $grok.Detail
        }
        return $result
    } catch {
        $status = 0
        try {
            # PowerShell can wrap GetResponse failures in MethodInvocationException.
            $failure = $_.Exception
            for ($depth = 0; $depth -lt 5 -and $null -ne $failure; $depth++) {
                if ($failure -is [System.Net.WebException] -and $null -ne $failure.Response) {
                    $response = $failure.Response
                    $status = [int]$response.StatusCode
                    break
                }
                $failure = $failure.InnerException
            }
        } catch {}
        if ($status -eq 401 -or $status -eq 403) {
            return (New-CursorQuotaResult 'auth' '请重新登录 Cursor' 'Cursor 登录已失效，请在客户端重新登录')
        }
        if ($status -eq 429) {
            return (New-CursorQuotaResult 'error' 'Cursor 请求过于频繁' '稍后自动重试')
        }
        return (New-CursorQuotaResult 'error' 'Cursor 暂不可用' '请检查网络或 Cursor 服务状态')
    } finally {
        if ($null -ne $reader) { $reader.Dispose() }
        if ($null -ne $response) { $response.Close() }
        $cookie = $null
        $accessToken = $null
    }
}
