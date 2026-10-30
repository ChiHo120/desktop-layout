# Token API key-usage quota helpers. This module never persists credentials.

function ConvertTo-QuotaNumber {
    param([object]$Value)
    if ($null -eq $Value -or $Value -is [bool]) { return $null }
    try {
        $number = [double]::Parse([string]$Value, [System.Globalization.CultureInfo]::InvariantCulture)
        if ([double]::IsNaN($number) -or [double]::IsInfinity($number)) { return $null }
        return $number
    } catch {
        return $null
    }
}

function Get-TokenQuotaField {
    param([AllowNull()]$Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return ,$Object[$Name] }
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return ,$property.Value }
    return $null
}

function Format-QuotaUsd {
    param([double]$Amount)
    return ('$' + $Amount.ToString('N2', [System.Globalization.CultureInfo]::InvariantCulture))
}

function Get-QuotaWindowName {
    param([string]$Window)
    if ([string]::IsNullOrWhiteSpace($Window)) { return '周期' }
    switch -Regex ($Window) {
        '^(5h|5H)$' { return '5 小时' }
        '^(1d|1D)$' { return '今日' }
        '^(7d|7D)$' { return '7 天' }
        default { return $Window }
    }
}

function Get-TokenQuotaDate {
    param([DateTimeOffset]$Now = [DateTimeOffset]::UtcNow)
    return $Now.ToOffset([TimeSpan]::FromHours(8)).ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
}

function ConvertFrom-TokenDailyUsage {
    param($Response, $DailyLimitUsd, [string]$UsageDate)

    $limit = ConvertTo-QuotaNumber $DailyLimitUsd
    $rows = Get-TokenQuotaField $Response 'daily_usage'
    $details = New-Object System.Collections.Generic.List[string]
    $used = $null
    if ($null -ne $rows) {
        $records = @($rows)
        $todayRows = @($records | Where-Object { [string](Get-TokenQuotaField $_ 'date') -eq $UsageDate })
        if ($records.Count -eq 0) { $used = 0.0 }
        elseif ($todayRows.Count -eq 1) {
            # Platform quota is charged at the actual cost, after any multiplier.
            $used = ConvertTo-QuotaNumber (Get-TokenQuotaField $todayRows[0] 'actual_cost')
            if ($null -ne $used -and $used -lt 0) { $used = $null }
        }
    }
    if ($null -ne $used) { $details.Add('今日实际已用 ' + (Format-QuotaUsd $used)) }
    if ($null -eq $limit -or $limit -lt 0) {
        $details.Add('接口未提供每日上限，请在额度设置中填入仪表盘的每日上限')
        return @{ State = 'unsupported'; Text = '每日剩余未知'; Detail = ($details -join ' · '); RemainingPercent = $null }
    }
    $details.Add('日上限设置 ' + (Format-QuotaUsd $limit))
    if ($null -eq $used) {
        $details.Add('接口未返回今日实际用量；未使用钱包余额推算')
        return @{ State = 'unsupported'; Text = '每日剩余未知'; Detail = ($details -join ' · '); RemainingPercent = $null }
    }
    $remaining = [math]::Max(0.0, $limit - $used)
    $percent = 0.0
    if ($limit -gt 0) { $percent = [math]::Round(($remaining / $limit) * 100, 1) }
    $details.Add($UsageDate + ' · 每日 00:00 重置（北京时间）')
    $details.Add('按当前 Key 用量估算；账户含其他 Key 时应以仪表盘为准；后台上限调整后请同步设置')
    $state = 'ok'
    if ($remaining -le 0) { $state = 'window-exhausted' }
    return @{ State = $state; Text = ('今日剩余 ' + (Format-QuotaUsd $remaining)); Detail = ($details -join ' · '); RemainingPercent = $percent }
}

function ConvertFrom-TokenQuota {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()][object]$Response,
        $DailyLimitUsd = $null,
        [string]$UsageDate = (Get-TokenQuotaDate)
    )

    $unsupported = @{
        State = 'unsupported'
        Text = '无法识别额度数据'
        Detail = '额度接口返回了未知格式'
        RemainingPercent = $null
    }
    if ($null -eq $Response) { return $unsupported }

    if ($Response -is [string]) {
        try { $Response = ConvertFrom-Json -InputObject $Response -ErrorAction Stop }
        catch { return $unsupported }
    }
    if ($null -eq $Response) { return $unsupported }
    if ($Response -is [System.Collections.IDictionary] -and $Response.Contains('data')) {
        $Response = $Response['data']
    } elseif ($Response.PSObject -and $Response.PSObject.Properties['data']) {
        $Response = $Response.data
    }
    if ($null -eq $Response) { return $unsupported }

    # The site's active indicator requires both a valid key and active status.
    $status = [string]$Response.status
    switch ($status) {
        'expired' {
            return @{ State = 'auth'; Text = 'API Key 已过期'; Detail = '请检查额度设置中的 API Key'; RemainingPercent = $null }
        }
        'disabled' {
            return @{ State = 'auth'; Text = 'API Key 已停用'; Detail = '请检查额度设置中的 API Key'; RemainingPercent = $null }
        }
        'quota_exhausted' {
            return @{ State = 'quota-exhausted'; Text = '额度已用完'; Detail = '额度接口报告当前 Key 的额度已用完'; RemainingPercent = 0 }
        }
    }
    if ($Response.isValid -is [bool] -and -not $Response.isValid) {
        return @{ State = 'auth'; Text = 'API Key 当前不可用'; Detail = '请检查额度设置中的 API Key'; RemainingPercent = $null }
    }

    $details = New-Object System.Collections.Generic.List[string]
    $remaining = $null
    $remainingPct = $null
    $text = ''
    $mode = [string]$Response.mode

    if ($mode -eq 'quota_limited') {
        $quota = $Response.quota
        # The site renders quota and rate_limits independently: either can be absent.
        if ($null -ne $quota) {
            $used = ConvertTo-QuotaNumber $quota.used
            $limit = ConvertTo-QuotaNumber $quota.limit
            $remaining = ConvertTo-QuotaNumber $quota.remaining
            if ($null -ne $remaining -and $remaining -lt 0) { $remaining = $null }
            if (($null -ne $limit -and $limit -lt 0) -or ($null -ne $used -and $used -lt 0)) { return $unsupported }
            if ($null -ne $limit -and $limit -eq 0) {
                # A nonpositive total limit is not evidence of an exhausted balance.
                $remaining = $null
                $details.Add('接口未提供有效总额度上限')
            } else {
                if ($null -eq $remaining -and $null -ne $limit -and $null -ne $used) {
                    $remaining = [math]::Max(0.0, $limit - $used)
                }
                if ($null -ne $remaining) {
                    if ($remaining -lt 0) { $remaining = 0.0 }
                    if ($null -ne $limit -and $limit -gt 0) {
                        $remainingPct = [math]::Round(([math]::Min($remaining, $limit) / $limit) * 100, 1)
                    }
                    $details.Add('总额度剩余 ' + (Format-QuotaUsd $remaining))
                }
                if ($null -ne $used -and $null -ne $limit) {
                    $details.Add(('总额度 {0}，已用 {1}' -f (Format-QuotaUsd $limit), (Format-QuotaUsd $used)))
                }
            }
        }

        $windowRecords = New-Object System.Collections.Generic.List[object]
        $windows = @($Response.rate_limits)
        foreach ($window in $windows) {
            if ($null -eq $window) { continue }
            $windowUsed = ConvertTo-QuotaNumber $window.used
            $windowLimit = ConvertTo-QuotaNumber $window.limit
            if ($null -eq $windowUsed -or $null -eq $windowLimit -or $windowUsed -lt 0 -or $windowLimit -le 0) { continue }
            $windowKey = [string]$window.window
            $label = Get-QuotaWindowName $windowKey
            $windowRemaining = [math]::Max(0.0, $windowLimit - $windowUsed)
            $windowPercent = [math]::Round(($windowRemaining / $windowLimit) * 100, 1)
            $windowRecords.Add([pscustomobject]@{
                Key = $windowKey
                Name = $label
                Used = $windowUsed
                Limit = $windowLimit
                Remaining = $windowRemaining
                Percent = $windowPercent
                Exhausted = ($windowRemaining -le 0)
            })
            $line = '{0} {1} / {2}' -f $label, (Format-QuotaUsd $windowUsed), (Format-QuotaUsd $windowLimit)
            if ($window.reset_at) {
                try {
                    $reset = [DateTimeOffset]::Parse([string]$window.reset_at, [System.Globalization.CultureInfo]::InvariantCulture)
                    $line += '，重置 ' + $reset.ToLocalTime().ToString('HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)
                } catch {}
            }
            $details.Add($line)
        }
        $dailyWindow = @($windowRecords | Where-Object { $_.Key -match '^(1d|1D)$' } | Select-Object -First 1)
        if ($dailyWindow.Count -gt 0) {
            $selectedWindow = $dailyWindow[0]
            $remaining = $selectedWindow.Remaining
            $remainingPct = $selectedWindow.Percent
            if ($selectedWindow.Exhausted) {
                return @{ State = 'window-exhausted'; Text = ($selectedWindow.Name + '额度已用完'); Detail = ($details -join ' · '); RemainingPercent = 0 }
            }
            $text = $selectedWindow.Name + '剩余 ' + (Format-QuotaUsd $remaining)
        } else {
            if ($null -ne $remaining) { $details.Add('总额度剩余 ' + (Format-QuotaUsd $remaining)) }
            return @{ State = 'unsupported'; Text = '每日剩余未知'; Detail = (($details.ToArray() + '接口未提供每日额度窗口') -join ' · '); RemainingPercent = $null }
        }
    } elseif ($Response.subscription) {
        $sub = $Response.subscription
        $topRemaining = ConvertTo-QuotaNumber $Response.remaining
        if ($null -ne $topRemaining -and $topRemaining -lt 0) { $topRemaining = $null }
        $windowRecords = New-Object System.Collections.Generic.List[object]
        $windows = @(
            @{ Key = '1d'; Name = '今日'; Used = $sub.daily_usage_usd; Limit = $sub.daily_limit_usd },
            @{ Key = '7d'; Name = '本周'; Used = $sub.weekly_usage_usd; Limit = $sub.weekly_limit_usd },
            @{ Key = '30d'; Name = '本月'; Used = $sub.monthly_usage_usd; Limit = $sub.monthly_limit_usd }
        )
        foreach ($window in $windows) {
            $windowUsed = ConvertTo-QuotaNumber $window.Used
            $windowLimit = ConvertTo-QuotaNumber $window.Limit
            if ($null -eq $windowLimit -or $windowLimit -le 0 -or $null -eq $windowUsed -or $windowUsed -lt 0) { continue }
            $windowRemaining = [math]::Max(0.0, $windowLimit - $windowUsed)
            $windowPct = [math]::Round(($windowRemaining / $windowLimit) * 100, 1)
            $windowRecords.Add([pscustomobject]@{
                Key = $window.Key
                Name = $window.Name
                Used = $windowUsed
                Limit = $windowLimit
                Remaining = $windowRemaining
                Percent = $windowPct
                Exhausted = ($windowRemaining -le 0)
            })
            $details.Add(('{0}剩余 {1} / {2}' -f $window.Name, (Format-QuotaUsd $windowRemaining), (Format-QuotaUsd $windowLimit)))
        }
        $dailyWindow = @($windowRecords | Where-Object { $_.Key -eq '1d' } | Select-Object -First 1)
        if ($dailyWindow.Count -gt 0) {
            $selectedWindow = $dailyWindow[0]
            $remaining = $selectedWindow.Remaining
            $remainingPct = $selectedWindow.Percent
            if ($selectedWindow.Exhausted) {
                if ($null -ne $topRemaining -and $topRemaining -ge 0) { $details.Add('总额度剩余 ' + (Format-QuotaUsd $topRemaining)) }
                return @{ State = 'window-exhausted'; Text = ($selectedWindow.Name + '额度已用完'); Detail = ($details -join ' · '); RemainingPercent = 0 }
            }
            $text = $selectedWindow.Name + '剩余 ' + (Format-QuotaUsd $remaining)
        } elseif ($null -ne $topRemaining) {
            $details.Add('接口未提供每日窗口，无法确认每日剩余')
            return @{ State = 'unsupported'; Text = '每日剩余未知'; Detail = ($details -join ' · '); RemainingPercent = $null }
        } else {
            return @{ State = 'unsupported'; Text = '每日剩余未知'; Detail = '接口未提供每日额度窗口'; RemainingPercent = $null }
        }
    } elseif ($mode -eq 'subscription') {
        $dailyUsed = ConvertTo-QuotaNumber $Response.daily_usage_usd
        $dailyLimit = ConvertTo-QuotaNumber $Response.daily_limit_usd
        $dailyRemaining = ConvertTo-QuotaNumber $Response.daily_remaining_usd
        if ($null -ne $dailyLimit -and $dailyLimit -gt 0 -and $null -ne $dailyUsed -and $dailyUsed -ge 0) {
            $dailyRemaining = [math]::Max(0.0, $dailyLimit - $dailyUsed)
        }
        if ($null -ne $dailyRemaining) {
            if ($dailyRemaining -le 0) {
                return @{ State = 'window-exhausted'; Text = '今日额度已用完'; Detail = '每日额度已耗尽'; RemainingPercent = 0 }
            }
            if ($null -ne $dailyLimit -and $dailyLimit -gt 0) {
                $remainingPct = [math]::Round(($dailyRemaining / $dailyLimit) * 100, 1)
            }
            $text = '今日剩余 ' + (Format-QuotaUsd $dailyRemaining)
        } else {
            return @{ State = 'unsupported'; Text = '每日剩余未知'; Detail = '接口未提供每日额度字段'; RemainingPercent = $null }
        }
    } elseif ($mode -eq 'unrestricted') {
        return ConvertFrom-TokenDailyUsage -Response $Response -DailyLimitUsd $DailyLimitUsd -UsageDate $UsageDate
    } elseif ($null -ne (ConvertTo-QuotaNumber $Response.balance)) {
        # A wallet balance is not a daily allowance. Never present it as one.
        return @{ State = 'unsupported'; Text = '每日剩余未知'; Detail = '接口只返回钱包总余额，未提供每日额度'; RemainingPercent = $null }
    } else {
        return $unsupported
    }

    return @{
        State = 'ok'
        Text = $text
        Detail = ($details -join ' · ')
        RemainingPercent = $remainingPct
    }
}

function Get-TokenQuota {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$ApiKey,
        [bool]$AllowInsecureHttp = $false,
        $DailyLimitUsd = $null
    )

    if ([string]::IsNullOrWhiteSpace($ApiKey)) {
        return @{ State = 'not-configured'; Text = '未配置 API Key'; Detail = ''; RemainingPercent = $null }
    }
    if (-not $AllowInsecureHttp) {
        return @{ State = 'insecure'; Text = 'HTTP 已阻止'; Detail = '请先在设置中确认明文传输风险'; RemainingPercent = $null }
    }

    $today = Get-TokenQuotaDate
    $timezone = 'Asia/Shanghai'
    $url = 'http://token.acerobotics.com/v1/usage?start_date={0}&end_date={0}&days=1&timezone={1}' -f $today, [System.Uri]::EscapeDataString($timezone)
    try {
        $response = Invoke-RestMethod -Uri $url -Method Get -Headers @{ Authorization = ('Bearer ' + $ApiKey) } -TimeoutSec 8 -MaximumRedirection 0 -ErrorAction Stop
    } catch {
        $statusCode = 0
        try {
            if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }
        } catch {}
        if ($statusCode -eq 401 -or $statusCode -eq 403) {
            return @{ State = 'auth'; Text = 'API Key 无效'; Detail = '请检查额度设置中的 API Key'; RemainingPercent = $null }
        }
        if ($statusCode -eq 429) {
            return @{ State = 'rate-limited'; Text = '请求过于频繁'; Detail = '稍后会自动重试'; RemainingPercent = $null }
        }
        return @{ State = 'error'; Text = 'Token API 暂不可用'; Detail = '检查网络或服务状态'; RemainingPercent = $null }
    }
    return ConvertFrom-TokenQuota -Response $response -DailyLimitUsd $DailyLimitUsd -UsageDate $today
}
