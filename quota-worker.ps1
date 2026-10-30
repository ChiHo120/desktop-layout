# Quota polling runs outside the WPF dispatcher. Cached balances remain in memory only.
. (Join-Path $PSScriptRoot 'quota-settings.ps1')
. (Join-Path $PSScriptRoot 'cursor-quota.ps1')
. (Join-Path $PSScriptRoot 'token-quota.ps1')

function Read-SpiritQuota {
    param(
        [ValidateSet('Cursor', 'Token')][string]$Provider,
        [Parameter(Mandatory = $true)]$Settings
    )

    try {
        if ($Provider -eq 'Cursor') {
            if (-not $Settings.CursorEnabled) {
                return @{ State = 'disabled'; Text = '已关闭'; Detail = '右键 → 设置额度连接'; RemainingPercent = $null; UpdatedAt = $null }
            }
            $result = Get-CursorQuota
        } else {
            if ($Settings.ApiKeyNeedsReplacement) {
                return @{ State = 'auth'; Text = '请重新保存 API Key'; Detail = '旧 Key 无法在当前 Windows 用户下解密；右键 → 设置额度连接'; RemainingPercent = $null; UpdatedAt = $null }
            }
            if (-not $Settings.ApiEnabled) {
                $text = '未连接'
                if ($Settings.ProtectedApiKey) { $text = '已关闭' }
                return @{ State = 'disabled'; Text = $text; Detail = '右键 → 设置额度连接'; RemainingPercent = $null; UpdatedAt = $null }
            }
            if (-not $Settings.AllowInsecureHttp) {
                return @{ State = 'insecure'; Text = 'HTTP 已阻止'; Detail = '请在额度设置中确认连接方式'; RemainingPercent = $null; UpdatedAt = $null }
            }
            $apiKey = $null
            try {
                $apiKey = Get-SpiritApiKey $Settings
                $result = Get-TokenQuota -ApiKey $apiKey -AllowInsecureHttp ([bool]$Settings.AllowInsecureHttp) -DailyLimitUsd $Settings.ApiDailyLimitUsd
            } finally {
                $apiKey = $null
            }
        }
        if ($null -eq $result -or -not $result.State) { throw 'Empty quota result' }
        $updated = $null
        if ($result.State -in @('ok', 'quota-exhausted', 'window-exhausted')) { $updated = Get-Date }
        $reading = @{
            State = [string]$result.State
            Text = [string]$result.Text
            Detail = [string]$result.Detail
            RemainingPercent = $result.RemainingPercent
            UpdatedAt = $updated
        }
        if ($null -ne $result.Buckets) {
            $reading.Buckets = @{}
            foreach ($name in @('Auto', 'Advanced', 'Grok')) {
                $bucket = $result.Buckets[$name]
                if ($null -eq $bucket) { continue }
                $bucketUpdated = $null
                if ($bucket.State -in @('ok', 'quota-exhausted', 'window-exhausted')) { $bucketUpdated = Get-Date }
                $reading.Buckets[$name] = @{
                    State = [string]$bucket.State; Text = [string]$bucket.Text; Detail = [string]$bucket.Detail
                    RemainingPercent = $bucket.RemainingPercent; UpdatedAt = $bucketUpdated
                }
            }
        }
        return $reading
    } catch {
        # Exceptions may contain request headers; expose only a static message.
        return @{ State = 'error'; Text = '暂不可用'; Detail = '额度读取失败；稍后自动重试'; RemainingPercent = $null; UpdatedAt = $null }
    }
}

function Get-SpiritQuotaView {
    param([Parameter(Mandatory = $true)]$Reading, $LastGood)

    if ($Reading.State -in @('error', 'rate-limited') -and $null -ne $LastGood) {
        $successDetail = [string]$LastGood.Detail
        if ($null -ne $LastGood.LastSuccessDetail) { $successDetail = [string]$LastGood.LastSuccessDetail }
        $view = @{
            State = 'stale'
            Text = [string]$LastGood.Text
            Detail = ('缓存 · {0}；{1}' -f $Reading.Text, $successDetail)
            LastSuccessDetail = $successDetail
            RemainingPercent = $LastGood.RemainingPercent
            UpdatedAt = $LastGood.UpdatedAt
        }
        if ($null -ne $LastGood.Buckets) { $view.Buckets = $LastGood.Buckets }
        return $view
    }
    if ($null -ne $Reading.Buckets) {
        $view = $Reading.Clone()
        $view.Buckets = @{}
        foreach ($name in @('Auto', 'Advanced', 'Grok')) {
            $bucket = $Reading.Buckets[$name]
            if ($null -eq $bucket) { continue }
            $priorBucket = $null
            if ($null -ne $LastGood -and $null -ne $LastGood.Buckets) {
                $priorBucket = $LastGood.Buckets[$name]
                if ($priorBucket.State -notin @('ok', 'stale', 'quota-exhausted', 'window-exhausted')) { $priorBucket = $null }
            }
            $view.Buckets[$name] = Get-SpiritQuotaView -Reading $bucket -LastGood $priorBucket
        }
        return $view
    }
    return $Reading
}

function Invoke-SpiritQuotaPolling {
    param(
        [Parameter(Mandatory = $true)]$Sync,
        [Parameter(Mandatory = $true)][string]$StateDir
    )

    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $nextRefresh = 0.0
    $lastGood = @{}
    $lastIdentity = @{}
    while (-not $Sync.Stop) {
        if ($Sync.QuotaRefreshRequested -or $clock.Elapsed.TotalSeconds -ge $nextRefresh) {
            $Sync.QuotaRefreshRequested = $false
            $settings = Get-SpiritQuotaSettings $StateDir
            foreach ($provider in @('Cursor', 'Token')) {
                if ($Sync.Stop) { break }
                # Forget cached values when the API connection is changed or disabled.
                $identity = [string]$settings.CursorEnabled
                if ($provider -eq 'Token') {
                    $identity = '{0}:{1}:{2}:{3}' -f $settings.ApiEnabled, $settings.AllowInsecureHttp, $settings.ProtectedApiKey, $settings.ApiDailyLimitUsd
                }
                if ($lastIdentity[$provider] -ne $identity) { $lastGood.Remove($provider) }
                $lastIdentity[$provider] = $identity
                $reading = Read-SpiritQuota -Provider $provider -Settings $settings
                $view = Get-SpiritQuotaView -Reading $reading -LastGood $lastGood[$provider]
                if ($reading.State -in @('ok', 'quota-exhausted', 'window-exhausted')) { $lastGood[$provider] = $view }
                elseif ($reading.State -notin @('error', 'rate-limited')) { $lastGood.Remove($provider) }
                # Publish each provider atomically so the UI sees a consistent result.
                $Sync[$provider + 'Quota'] = $view
            }
            $Sync.QuotaReady = $true
            $nextRefresh = $clock.Elapsed.TotalSeconds + 30
        }
        Start-Sleep -Milliseconds 100
    }
    $clock.Stop()
}
