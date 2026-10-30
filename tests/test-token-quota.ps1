$ErrorActionPreference = 'Stop'
$module = Join-Path (Split-Path -Parent $PSScriptRoot) 'token-quota.ps1'
. $module

$script:RequestCount = 0
$script:LastRequest = $null
function Invoke-RestMethod {
    param($Uri, $Method, $Headers, $TimeoutSec, $MaximumRedirection, $ErrorAction)
    $script:RequestCount++
    $script:LastRequest = @{ Uri = [string]$Uri; Method = [string]$Method; Headers = $Headers }
    if ($script:MockFailure) { throw [System.Exception]::new('request failed with secret ' + $script:MockSecret) }
    return $script:MockResponse
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Name)
    if ($Expected -ne $Actual) {
        throw ('{0}: expected [{1}], got [{2}]' -f $Name, $Expected, $Actual)
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Name)
    if (-not $Condition) { throw ('Assertion failed: ' + $Name) }
}

Assert-Equal '2026-10-26' (Get-TokenQuotaDate ([DateTimeOffset]'2026-10-26T15:59:59Z')) 'Beijing date before midnight boundary'
Assert-Equal '2026-10-27' (Get-TokenQuotaDate ([DateTimeOffset]'2026-10-26T16:00:00Z')) 'Beijing date after midnight boundary'

$limited = [pscustomobject]@{
    mode = 'quota_limited'
    status = 'active'
    quota = [pscustomobject]@{ used = 13.25; limit = 20; remaining = 6.75 }
    rate_limits = @(
        [pscustomobject]@{ window = '5h'; used = 1.25; limit = 10; reset_at = '2026-10-27T12:30:00Z' },
        [pscustomobject]@{ window = '1d'; used = 4; limit = 12; reset_at = '2026-10-28T00:00:00Z' },
        [pscustomobject]@{ window = '7d'; used = 13.25; limit = 50; reset_at = '2026-11-03T00:00:00Z' }
    )
}
$parsed = ConvertFrom-TokenQuota $limited
Assert-Equal 'ok' $parsed.State 'quota_limited state'
Assert-Equal '今日剩余 $8.00' $parsed.Text 'daily window wins over total and the shorter 5h window'
Assert-Equal 66.7 $parsed.RemainingPercent 'daily remaining percent'
Assert-True ($parsed.Detail.Contains('5 小时') -and $parsed.Detail.Contains('今日') -and $parsed.Detail.Contains('7 天')) 'quota window labels'
Assert-True ($parsed.Detail.Contains('重置')) 'reset time shown'
$serverDailyWins = ConvertFrom-TokenQuota -Response $limited -DailyLimitUsd 400 -UsageDate '2026-10-27'
Assert-Equal '今日剩余 $8.00' $serverDailyWins.Text 'configured fallback never overrides a server daily rate limit'

$nonDailyWindows = ConvertFrom-TokenQuota ([pscustomobject]@{
    mode = 'quota_limited'
    quota = [pscustomobject]@{ used = 120; limit = 1000; remaining = 880 }
    rate_limits = @(
        [pscustomobject]@{ window = '5h'; used = 2; limit = 20 },
        [pscustomobject]@{ window = '7d'; used = 40; limit = 100 }
    )
})
Assert-Equal 'unsupported' $nonDailyWindows.State '5h and 7d windows cannot masquerade as daily allowance'
Assert-Equal '每日剩余未知' $nonDailyWindows.Text 'non-daily windows do not produce daily remaining'
Assert-True ($nonDailyWindows.Detail.Contains('总额度剩余 $880.00')) 'non-daily windows keep total balance only in details'

$zeroQuota = [pscustomobject]@{
    mode = 'quota_limited'
    quota = [pscustomobject]@{ used = 5; limit = 5; remaining = 0 }
    rate_limits = @()
}
$zero = ConvertFrom-TokenQuota $zeroQuota
Assert-Equal '每日剩余未知' $zero.Text 'zero total quota without a daily window is unknown'
Assert-Equal $null $zero.RemainingPercent 'zero total quota without a daily window has no percentage'
Assert-Equal 'unsupported' $zero.State 'zero total quota is not treated as a daily exhaustion'

$windowOnly = ConvertFrom-TokenQuota ([pscustomobject]@{
    mode = 'quota_limited'
    status = 'active'
    rate_limits = @(
        [pscustomobject]@{ window = '5h'; used = 8; limit = 10; reset_at = '2026-10-27T12:30:00Z' },
        [pscustomobject]@{ window = '1d'; used = 20; limit = 50; reset_at = '2026-10-28T00:00:00Z' }
    )
})
Assert-Equal 'ok' $windowOnly.State 'rate limits without a total quota are supported'
Assert-Equal '今日剩余 $30.00' $windowOnly.Text 'daily remainder is displayed instead of the shorter 5h window'
Assert-Equal 60 $windowOnly.RemainingPercent 'daily window percent is shown'
Assert-True ($windowOnly.Detail.Contains('今日 $20.00 / $50.00')) 'other window usage remains available in details'

$unlimitedTotal = ConvertFrom-TokenQuota ([pscustomobject]@{
    mode = 'quota_limited'
    status = 'active'
    quota = [pscustomobject]@{ used = 42; limit = 0; remaining = 0 }
    rate_limits = @(
        [pscustomobject]@{ window = '1d'; used = 3; limit = 10 }
    )
})
Assert-Equal 'ok' $unlimitedTotal.State 'zero total limit is not exhaustion'
Assert-Equal '今日剩余 $7.00' $unlimitedTotal.Text 'zero total limit falls back to a valid window'
Assert-Equal 70 $unlimitedTotal.RemainingPercent 'zero total limit uses the window percentage'
Assert-True ($unlimitedTotal.Detail.Contains('未提供有效总额度上限')) 'zero total limit is identified as unbounded'

$unlimitedWithoutWindows = ConvertFrom-TokenQuota ([pscustomobject]@{
    mode = 'quota_limited'
    quota = [pscustomobject]@{ used = 0; limit = 0; remaining = 0 }
    rate_limits = @()
})
Assert-Equal 'unsupported' $unlimitedWithoutWindows.State 'unbounded quota without windows has no calculable remainder'
Assert-True ($unlimitedWithoutWindows.Text -ne '剩余 $0.00') 'zero limit is never represented as zero remaining'

$exhaustedStatus = ConvertFrom-TokenQuota ([pscustomobject]@{
    mode = 'quota_limited'
    status = 'quota_exhausted'
    quota = [pscustomobject]@{ used = 20; limit = 20; remaining = 0 }
    rate_limits = @()
})
Assert-Equal 'quota-exhausted' $exhaustedStatus.State 'site exhausted status is propagated'
Assert-Equal '额度已用完' $exhaustedStatus.Text 'site exhausted status is not shown as an available balance'

$exhaustedWindow = ConvertFrom-TokenQuota ([pscustomobject]@{
    mode = 'quota_limited'
    status = 'active'
    quota = [pscustomobject]@{ used = 4; limit = 20; remaining = 16 }
    rate_limits = @(
        [pscustomobject]@{ window = '5h'; used = 10; limit = 10 },
        [pscustomobject]@{ window = '1d'; used = 5; limit = 20 }
    )
})
Assert-Equal 'ok' $exhaustedWindow.State 'exhausted 5h window does not replace the daily allowance'
Assert-Equal '今日剩余 $15.00' $exhaustedWindow.Text 'daily amount remains distinct from exhausted shorter window'
Assert-Equal 75 $exhaustedWindow.RemainingPercent 'daily percentage is independent of exhausted shorter window'
Assert-True ($exhaustedWindow.Detail.Contains('5 小时 $10.00 / $10.00')) 'exhausted shorter window stays available in details'

$exhaustedDailyWindow = ConvertFrom-TokenQuota ([pscustomobject]@{
    mode = 'quota_limited'
    status = 'active'
    quota = [pscustomobject]@{ used = 1; limit = 100; remaining = 99 }
    rate_limits = @([pscustomobject]@{ window = '1d'; used = 20; limit = 20 })
})
Assert-Equal 'window-exhausted' $exhaustedDailyWindow.State 'exhausted daily rate window is propagated'
Assert-Equal '今日额度已用完' $exhaustedDailyWindow.Text 'exhausted daily window is not hidden by a positive total'
Assert-Equal 0 $exhaustedDailyWindow.RemainingPercent 'exhausted daily window reports zero availability'

$fallback = ConvertFrom-TokenQuota ([pscustomobject]@{
    mode = 'quota_limited'
    quota = [pscustomobject]@{ used = 3; limit = 8 }
})
Assert-Equal 'unsupported' $fallback.State 'total-only quota is not presented as daily remaining'
Assert-Equal '每日剩余未知' $fallback.Text 'total-only quota clearly states daily value unavailable'
Assert-True ($fallback.Detail.Contains('总额度剩余 $5.00')) 'total quota remains visible in supporting detail'

$wrapped = ConvertFrom-TokenQuota ([pscustomobject]@{
    code = 0
    data = [pscustomobject]@{
        mode = 'subscription'
        remaining = 45.5
        subscription = [pscustomobject]@{
            daily_usage_usd = 2.5; daily_limit_usd = 10
            weekly_usage_usd = 5; weekly_limit_usd = 30
            monthly_usage_usd = 15; monthly_limit_usd = 100
        }
    }
})
Assert-Equal '今日剩余 $7.50' $wrapped.Text 'subscription daily remaining takes precedence over wallet balance'
Assert-Equal 75 $wrapped.RemainingPercent 'subscription daily percentage'
Assert-True ($wrapped.Detail.Contains('今日剩余 $7.50 / $10.00')) 'subscription daily limit'
$serverSubscriptionWins = ConvertFrom-TokenQuota -Response ([pscustomobject]@{
    mode = 'subscription'
    subscription = [pscustomobject]@{ daily_usage_usd = 2.5; daily_limit_usd = 10 }
}) -DailyLimitUsd 400 -UsageDate '2026-10-27'
Assert-Equal '今日剩余 $7.50' $serverSubscriptionWins.Text 'configured fallback never overrides server subscription daily limit'

$weeklySubscriptionOnly = ConvertFrom-TokenQuota ([pscustomobject]@{
    mode = 'subscription'
    remaining = 999999
    subscription = [pscustomobject]@{ weekly_usage_usd = 10; weekly_limit_usd = 100 }
})
Assert-Equal 'unsupported' $weeklySubscriptionOnly.State 'weekly subscription allowance is not daily quota'
Assert-Equal '每日剩余未知' $weeklySubscriptionOnly.Text 'subscription without daily cap does not invent daily balance'

$tightest = ConvertFrom-TokenQuota ([pscustomobject]@{
    subscription = [pscustomobject]@{ daily_usage_usd = 8; daily_limit_usd = 10; weekly_usage_usd = 10; weekly_limit_usd = 100 }
})
Assert-Equal '今日剩余 $2.00' $tightest.Text 'subscription daily window is preferred'
Assert-Equal 20 $tightest.RemainingPercent 'subscription daily configured window'

$subscriptionWindowExhausted = ConvertFrom-TokenQuota ([pscustomobject]@{
    mode = 'subscription'
    remaining = 100
    subscription = [pscustomobject]@{ daily_usage_usd = 10; daily_limit_usd = 10; weekly_usage_usd = 10; weekly_limit_usd = 100 }
})
Assert-Equal 'window-exhausted' $subscriptionWindowExhausted.State 'subscription exhausted window takes precedence over a positive total'
Assert-Equal '今日额度已用完' $subscriptionWindowExhausted.Text 'subscription exhausted window cannot be displayed as available'

$invalidKey = ConvertFrom-TokenQuota ([pscustomobject]@{
    mode = 'quota_limited'
    isValid = $false
    quota = [pscustomobject]@{ used = 0; limit = 20; remaining = 20 }
})
Assert-Equal 'auth' $invalidKey.State 'invalid key cannot report an available balance'

$wallet = ConvertFrom-TokenQuota ([pscustomobject]@{ balance = 0 })
Assert-Equal 'unsupported' $wallet.State 'wallet balance is not daily quota'
Assert-Equal '每日剩余未知' $wallet.Text 'wallet-only response never claims a daily balance'
Assert-True ($wallet.Detail.Contains('钱包总余额')) 'wallet-only response explains unavailable daily field'
$unknownWallet = ConvertFrom-TokenQuota ([pscustomobject]@{ balance = -1 })
Assert-Equal 'unsupported' $unknownWallet.State 'negative wallet sentinel is not a zero balance'
$unknownTotal = ConvertFrom-TokenQuota ([pscustomobject]@{
    mode = 'quota_limited'
    quota = [pscustomobject]@{ remaining = -1 }
    rate_limits = @([pscustomobject]@{ window = '1d'; used = 3; limit = 10 })
})
Assert-Equal '今日剩余 $7.00' $unknownTotal.Text 'negative total sentinel falls back to a valid window'

$malformed = ConvertFrom-TokenQuota '{not json'
Assert-Equal 'unsupported' $malformed.State 'malformed payload'
$unknown = ConvertFrom-TokenQuota ([pscustomobject]@{ unexpected = 'shape' })
Assert-Equal 'unsupported' $unknown.State 'unknown payload'
$empty = ConvertFrom-TokenQuota $null
Assert-Equal 'unsupported' $empty.State 'null payload'
$notNumber = ConvertFrom-TokenQuota ([pscustomobject]@{ mode = 'quota_limited'; quota = [pscustomobject]@{remaining = [double]::NaN} })
Assert-Equal 'unsupported' $notNumber.State 'non-finite quota value'

$fixedUsageDate = '2026-10-27'
$todayUsage = [pscustomobject]@{
    mode = 'unrestricted'
    balance = 99999995346.1841
    remaining = 99999995346.1841
    daily_usage = @(
        [pscustomobject]@{ date = '2026-10-26'; cost = 150; actual_cost = 150 },
        [pscustomobject]@{ date = $fixedUsageDate; cost = 300; actual_cost = 165.2371 }
    )
}
$unrestricted = ConvertFrom-TokenQuota -Response $todayUsage -DailyLimitUsd 400 -UsageDate $fixedUsageDate
Assert-Equal 'ok' $unrestricted.State 'unrestricted daily usage with configured limit'
Assert-Equal '今日剩余 $234.76' $unrestricted.Text 'configured daily limit minus actual cost'
Assert-Equal 58.7 $unrestricted.RemainingPercent 'configured daily remaining percentage'
Assert-True ($unrestricted.Detail.Contains('今日实际已用 $165.24')) 'actual cost is used for quota math'
Assert-True (-not $unrestricted.Text.Contains('999999')) 'large wallet balance never replaces daily remaining'

$noLimit = ConvertFrom-TokenQuota -Response $todayUsage -UsageDate $fixedUsageDate
Assert-Equal 'unsupported' $noLimit.State 'unrestricted daily usage without a daily limit is unknown'
Assert-Equal '每日剩余未知' $noLimit.Text 'missing daily limit is explicit'

$yesterdayOnly = ConvertFrom-TokenQuota -Response ([pscustomobject]@{
    mode = 'unrestricted'
    balance = 90000000000
    daily_usage = @([pscustomobject]@{ date = '2026-10-26'; cost = 1; actual_cost = 1 })
}) -DailyLimitUsd 400 -UsageDate $fixedUsageDate
Assert-Equal 'unsupported' $yesterdayOnly.State 'yesterday usage is not reused as today'
Assert-Equal '每日剩余未知' $yesterdayOnly.Text 'missing today record does not imply zero usage'

$missingActualCost = ConvertFrom-TokenQuota -Response ([pscustomobject]@{
    mode = 'unrestricted'
    daily_usage = @([pscustomobject]@{ date = $fixedUsageDate; cost = 5 })
}) -DailyLimitUsd 400 -UsageDate $fixedUsageDate
Assert-Equal 'unsupported' $missingActualCost.State 'missing actual cost is not treated as zero'

$missingDailyUsage = ConvertFrom-TokenQuota -Response ([pscustomobject]@{ mode = 'unrestricted'; balance = 1000 }) -DailyLimitUsd 400 -UsageDate $fixedUsageDate
Assert-Equal 'unsupported' $missingDailyUsage.State 'missing daily array is not equivalent to an explicit empty array'

$duplicateToday = ConvertFrom-TokenQuota -Response ([pscustomobject]@{
    mode = 'unrestricted'
    daily_usage = @(
        [pscustomobject]@{ date = $fixedUsageDate; actual_cost = 1 },
        [pscustomobject]@{ date = $fixedUsageDate; actual_cost = 2 }
    )
}) -DailyLimitUsd 400 -UsageDate $fixedUsageDate
Assert-Equal 'unsupported' $duplicateToday.State 'ambiguous duplicate daily aggregates are not added or selected'

$invalidActualCost = ConvertFrom-TokenQuota -Response ([pscustomobject]@{
    mode = 'unrestricted'
    daily_usage = @([pscustomobject]@{ date = $fixedUsageDate; cost = 5; actual_cost = [double]::NaN })
}) -DailyLimitUsd 400 -UsageDate $fixedUsageDate
Assert-Equal 'unsupported' $invalidActualCost.State 'non-finite actual cost is rejected'

$overLimit = ConvertFrom-TokenQuota -Response ([pscustomobject]@{
    mode = 'unrestricted'
    daily_usage = @([pscustomobject]@{ date = $fixedUsageDate; cost = 405; actual_cost = 405 })
}) -DailyLimitUsd 400 -UsageDate $fixedUsageDate
Assert-Equal 'window-exhausted' $overLimit.State 'usage above daily limit is exhausted'
Assert-Equal '今日剩余 $0.00' $overLimit.Text 'usage above daily limit clamps remaining to zero'

$zeroLimit = ConvertFrom-TokenQuota -Response ([pscustomobject]@{
    mode = 'unrestricted'
    balance = 1000
    daily_usage = @([pscustomobject]@{ date = $fixedUsageDate; cost = 0; actual_cost = 0 })
}) -DailyLimitUsd 0 -UsageDate $fixedUsageDate
Assert-Equal 'window-exhausted' $zeroLimit.State 'zero configured limit has no daily availability'
Assert-Equal '今日剩余 $0.00' $zeroLimit.Text 'zero configured limit is shown as no available amount'

$emptyDaily = ConvertFrom-TokenQuota -Response ([pscustomobject]@{
    mode = 'unrestricted'
    balance = 1000
    daily_usage = [object[]]@()
}) -DailyLimitUsd 400 -UsageDate $fixedUsageDate
Assert-Equal 'ok' $emptyDaily.State 'explicit empty daily usage array means zero usage today'
Assert-Equal '今日剩余 $400.00' $emptyDaily.Text 'explicit empty daily usage keeps the full daily limit'

$script:RequestCount = 0
$script:MockFailure = $false
$script:MockResponse = $limited
$script:MockUsageDate = '2026-10-27'
function Get-TokenQuotaDate {
    param([DateTimeOffset]$Now = [DateTimeOffset]::UtcNow)
    return $script:MockUsageDate
}
$noKey = Get-TokenQuota -ApiKey '' -AllowInsecureHttp $true
Assert-Equal 'not-configured' $noKey.State 'empty API key'
Assert-Equal 0 $script:RequestCount 'empty key performs no request'

$blocked = Get-TokenQuota -ApiKey 'test-key' -AllowInsecureHttp $false
Assert-Equal 'insecure' $blocked.State 'HTTP opt-in required'
Assert-Equal 0 $script:RequestCount 'without HTTP opt-in performs no request'

$enabled = Get-TokenQuota -ApiKey 'test-key' -AllowInsecureHttp $true
Assert-Equal 'ok' $enabled.State 'authorized HTTP request mocked'
Assert-Equal 1 $script:RequestCount 'request made only after opt-in'
Assert-Equal 'http://token.acerobotics.com/v1/usage?start_date=2026-10-27&end_date=2026-10-27&days=1&timezone=Asia%2FShanghai' $script:LastRequest.Uri 'request pins Shanghai date and timezone'
Assert-Equal 'Bearer test-key' $script:LastRequest.Headers.Authorization 'bearer header sent'

$script:MockResponse = $todayUsage
$dailyRequest = Get-TokenQuota -ApiKey 'test-key' -AllowInsecureHttp $true -DailyLimitUsd 400
Assert-Equal '今日剩余 $234.76' $dailyRequest.Text 'configured daily limit is passed into unrestricted response'
Assert-Equal 'http://token.acerobotics.com/v1/usage?start_date=2026-10-27&end_date=2026-10-27&days=1&timezone=Asia%2FShanghai' $script:LastRequest.Uri 'fixed date is used for daily usage request'

$script:MockFailure = $true
$script:MockSecret = 'DO-NOT-LEAK'
$failure = Get-TokenQuota -ApiKey $script:MockSecret -AllowInsecureHttp $true
Assert-Equal 'error' $failure.State 'request error state'
Assert-True (-not ($failure.Text.Contains($script:MockSecret)) -and -not ($failure.Detail.Contains($script:MockSecret))) 'error output does not leak key'
$script:MockFailure = $false

Write-Output 'Token quota tests passed.'
