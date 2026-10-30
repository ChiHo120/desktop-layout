$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $projectRoot 'quota-worker.ps1')

# All provider calls, credentials and time are fixtures. A network call is a failure.
$script:NetworkCalls = 0
function Invoke-RestMethod {
    $script:NetworkCalls++
    throw 'The quota-worker tests must not access the network.'
}
function Invoke-WebRequest {
    $script:NetworkCalls++
    throw 'The quota-worker tests must not access the network.'
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

$script:CursorCalls = 0
$script:DecryptCalls = 0
$script:TokenCalls = 0
$script:MockNow = [datetime]'2026-10-27T12:00:00'
$script:CursorThrows = $false
$script:TokenThrows = $false
$script:PollMode = $false
$script:CursorResult = @{ State = 'ok'; Text = 'Cursor balance'; Detail = 'Cursor details'; RemainingPercent = 62.5 }
$script:CursorResult.Buckets = @{
    Auto = @{ State = 'ok'; Text = 'remaining 80%'; Detail = 'Auto cycle'; RemainingPercent = 80 }
    Advanced = @{ State = 'ok'; Text = 'remaining 60%'; Detail = 'Advanced cycle'; RemainingPercent = 60 }
    Grok = @{ State = 'ok'; Text = 'remaining 25%'; Detail = 'Grok cycle'; RemainingPercent = 25 }
}
$script:TokenResult = @{ State = 'ok'; Text = 'Token balance'; Detail = 'Token details'; RemainingPercent = 25.5 }

function Get-Date { return $script:MockNow }
function Get-CursorQuota {
    $script:CursorCalls++
    if ($script:CursorThrows) { throw 'PRIVATE-CURSOR-SESSION' }
    if ($script:PollMode) { return $script:PollFrames[$script:PollIndex].Cursor }
    return $script:CursorResult
}
function Get-SpiritApiKey {
    param($Settings)
    $script:DecryptCalls++
    return 'fixture-key'
}
function Get-TokenQuota {
    param([string]$ApiKey, [bool]$AllowInsecureHttp, $DailyLimitUsd = $null)
    $script:TokenCalls++
    $script:LastTokenArgs = @{ ApiKey = $ApiKey; AllowInsecureHttp = $AllowInsecureHttp; DailyLimitUsd = $DailyLimitUsd }
    if ($script:TokenThrows) { throw 'PRIVATE-API-SECRET' }
    if ($script:PollMode) { return $script:PollFrames[$script:PollIndex].Token }
    return $script:TokenResult
}

$disabled = @{ CursorEnabled = $false; ApiEnabled = $false; AllowInsecureHttp = $true; ProtectedApiKey = 'fixture-ciphertext' }
$script:CursorThrows = $true
$reading = Read-SpiritQuota -Provider Cursor -Settings $disabled
Assert-Equal 'disabled' $reading.State 'disabled Cursor state'
Assert-Equal 0 $script:CursorCalls 'disabled Cursor does not read login'
Assert-Equal $null $reading.UpdatedAt 'disabled Cursor has no update time'
$script:CursorThrows = $false

$reading = Read-SpiritQuota -Provider Token -Settings $disabled
Assert-Equal 'disabled' $reading.State 'disabled API state'
Assert-Equal 0 $script:DecryptCalls 'disabled API does not decrypt a key'
Assert-Equal 0 $script:TokenCalls 'disabled API does not request usage'

$unreadableKey = $disabled.Clone()
$unreadableKey.ApiKeyNeedsReplacement = $true
$reading = Read-SpiritQuota -Provider Token -Settings $unreadableKey
Assert-Equal 'auth' $reading.State 'unreadable saved key requires replacement instead of appearing unconfigured'
Assert-Equal 0 $script:DecryptCalls 'unreadable key does not attempt a second decryption'
Assert-Equal 0 $script:TokenCalls 'unreadable key never triggers a usage request'

$noConsent = @{ CursorEnabled = $false; ApiEnabled = $true; AllowInsecureHttp = $false; ProtectedApiKey = 'fixture-ciphertext' }
$reading = Read-SpiritQuota -Provider Token -Settings $noConsent
Assert-Equal 'insecure' $reading.State 'HTTP consent is required'
Assert-Equal 0 $script:DecryptCalls 'without HTTP consent no key is decrypted'
Assert-Equal 0 $script:TokenCalls 'without HTTP consent no usage is requested'

$enabled = @{ CursorEnabled = $true; ApiEnabled = $true; AllowInsecureHttp = $true; ProtectedApiKey = 'fixture-ciphertext'; ApiDailyLimitUsd = 400 }
$cursorGood = Read-SpiritQuota -Provider Cursor -Settings $enabled
Assert-Equal 'ok' $cursorGood.State 'successful Cursor state'
Assert-Equal $script:MockNow $cursorGood.UpdatedAt 'successful Cursor receives update time'
Assert-Equal 62.5 $cursorGood.RemainingPercent 'Cursor percentage is preserved'
Assert-Equal 1 $script:CursorCalls 'enabled Cursor reads the provider once'
Assert-Equal 80 $cursorGood.Buckets.Auto.RemainingPercent 'Auto bucket passes through worker'
Assert-Equal 60 $cursorGood.Buckets.Advanced.RemainingPercent 'Advanced bucket passes through worker'
Assert-Equal 25 $cursorGood.Buckets.Grok.RemainingPercent 'Grok bucket passes through worker'
Assert-Equal $script:MockNow $cursorGood.Buckets.Grok.UpdatedAt 'bucket success timestamp is recorded'

$partialFailure = $cursorGood.Clone()
$partialFailure.Buckets = $cursorGood.Buckets.Clone()
$partialFailure.Buckets.Grok = @{ State = 'error'; Text = 'Grok unavailable'; Detail = ''; RemainingPercent = $null; UpdatedAt = $null }
$partialView = Get-SpiritQuotaView -Reading $partialFailure -LastGood $cursorGood
Assert-Equal 'ok' $partialView.Buckets.Auto.State 'independent bucket success remains current'
Assert-Equal 'stale' $partialView.Buckets.Grok.State 'independent Grok failure keeps a marked cache'
Assert-Equal 25 $partialView.Buckets.Grok.RemainingPercent 'independent bucket cache retains its value'
Assert-Equal $cursorGood.Buckets.Grok.UpdatedAt $partialView.Buckets.Grok.UpdatedAt 'independent bucket cache retains its timestamp'
Assert-Equal 'error' $partialFailure.Buckets.Grok.State 'merging never mutates the provider reading'
Assert-Equal 'ok' $cursorGood.Buckets.Grok.State 'merging never mutates the last successful reading'
$repeatedPartialView = Get-SpiritQuotaView -Reading $partialFailure -LastGood $partialView
Assert-Equal $partialView.Buckets.Grok.Detail $repeatedPartialView.Buckets.Grok.Detail 'repeated independent failure does not grow cache explanation text'
Assert-Equal $cursorGood.Buckets.Grok.UpdatedAt $repeatedPartialView.Buckets.Grok.UpdatedAt 'repeated independent failure preserves the original success time'

$tokenGood = Read-SpiritQuota -Provider Token -Settings $enabled
Assert-Equal 'ok' $tokenGood.State 'successful API state'
Assert-Equal $script:MockNow $tokenGood.UpdatedAt 'successful API receives update time'
Assert-Equal 1 $script:DecryptCalls 'enabled API decrypts only once'
Assert-Equal 1 $script:TokenCalls 'enabled API requests usage once'
Assert-Equal 'fixture-key' $script:LastTokenArgs.ApiKey 'decrypted fixture key is passed to the provider'
Assert-Equal $true $script:LastTokenArgs.AllowInsecureHttp 'HTTP consent reaches the provider'
Assert-Equal 400 $script:LastTokenArgs.DailyLimitUsd 'configured daily limit reaches the provider'

$script:TokenThrows = $true
$failure = Read-SpiritQuota -Provider Token -Settings $enabled
Assert-Equal 'error' $failure.State 'provider exceptions become error readings'
Assert-Equal $null $failure.UpdatedAt 'failure does not receive a success timestamp'
Assert-True (-not (($failure | ConvertTo-Json -Compress).Contains('PRIVATE-API-SECRET'))) 'provider error is secret safe'
$script:TokenThrows = $false

foreach ($state in @('error', 'rate-limited')) {
    $failedReading = @{ State = $state; Text = 'temporary failure'; Detail = ''; RemainingPercent = $null; UpdatedAt = $null }
    $view = Get-SpiritQuotaView -Reading $failedReading -LastGood $tokenGood
    Assert-Equal 'stale' $view.State ($state + ' is marked stale when a cache exists')
    Assert-Equal $tokenGood.Text $view.Text ($state + ' preserves the cached amount')
    Assert-Equal $tokenGood.RemainingPercent $view.RemainingPercent ($state + ' preserves the cached percentage')
    Assert-Equal $tokenGood.UpdatedAt $view.UpdatedAt ($state + ' preserves the original success time')
    Assert-True ($view.Detail.Contains('temporary failure')) ($state + ' includes the current failure')
    $uncached = Get-SpiritQuotaView -Reading $failedReading -LastGood $null
    Assert-Equal $state $uncached.State ($state + ' without cache keeps its actual state')
    Assert-Equal $null $uncached.UpdatedAt ($state + ' without cache does not invent an update time')
}

$auth = @{ State = 'auth'; Text = 'login required'; Detail = 'sign in again'; RemainingPercent = $null; UpdatedAt = $null }
$authView = Get-SpiritQuotaView -Reading $auth -LastGood $tokenGood
Assert-Equal 'auth' $authView.State 'auth failure never displays a cached success'
Assert-Equal 'login required' $authView.Text 'auth failure keeps its actual message'
Assert-Equal $null $authView.UpdatedAt 'auth failure does not invent an update time'
foreach ($state in @('quota-exhausted', 'window-exhausted')) {
    $exhausted = @{ State = $state; Text = 'quota exhausted'; Detail = ''; RemainingPercent = 0; UpdatedAt = $null }
    $exhaustedView = Get-SpiritQuotaView -Reading $exhausted -LastGood $tokenGood
    Assert-Equal $state $exhaustedView.State ($state + ' is not hidden behind cached data')
    Assert-Equal 'quota exhausted' $exhaustedView.Text ($state + ' keeps its actual message')
    Assert-Equal 0 $exhaustedView.RemainingPercent ($state + ' does not reuse the cached percentage')
}

# Drive complete polling cycles without sleeping, reading settings, decrypting or networking.
function Get-SpiritQuotaSettings {
    param([string]$StateDir)
    return $script:PollFrames[$script:PollIndex].Settings
}
function Start-Sleep {
    param([int]$Milliseconds)
    $script:PollSnapshots.Add(@{
        Cursor = $script:PollSync.CursorQuota
        Token = $script:PollSync.TokenQuota
        TokenArgs = $script:LastTokenArgs
    })
    $script:PollIndex++
    if ($script:PollIndex -ge $script:PollFrames.Count) {
        $script:PollSync.Stop = $true
    } else {
        $script:MockNow = $script:MockNow.AddMinutes(1)
        $script:PollSync.QuotaRefreshRequested = $true
    }
}
function Invoke-FixturePolling {
    param([object[]]$Frames)
    $script:PollFrames = $Frames
    $script:PollIndex = 0
    $script:PollSnapshots = New-Object System.Collections.Generic.List[object]
    $script:PollSync = @{ Stop = $false; QuotaRefreshRequested = $true }
    $script:PollMode = $true
    try { Invoke-SpiritQuotaPolling -Sync $script:PollSync -StateDir 'fixture-state-directory' }
    finally { $script:PollMode = $false }
}

$errorReading = @{ State = 'error'; Text = 'temporary failure'; Detail = ''; RemainingPercent = $null }
$rateLimited = @{ State = 'rate-limited'; Text = 'try later'; Detail = ''; RemainingPercent = $null }
Invoke-FixturePolling @(
    @{ Settings = $enabled; Cursor = $script:CursorResult; Token = $script:TokenResult },
    @{ Settings = $enabled; Cursor = $errorReading; Token = $rateLimited },
    @{ Settings = $enabled; Cursor = $auth; Token = $auth },
    @{ Settings = $enabled; Cursor = $errorReading; Token = $errorReading }
)
Assert-Equal 4 $script:PollSnapshots.Count 'all fixture polling cycles ran'
Assert-Equal 80 $script:PollSnapshots[1].Cursor.Buckets.Auto.RemainingPercent 'whole provider outage retains Auto bucket'
Assert-Equal 60 $script:PollSnapshots[1].Cursor.Buckets.Advanced.RemainingPercent 'whole provider outage retains Advanced bucket'
Assert-Equal 25 $script:PollSnapshots[1].Cursor.Buckets.Grok.RemainingPercent 'whole provider outage retains Grok bucket'
foreach ($provider in @('Cursor', 'Token')) {
    $first = $script:PollSnapshots[0][$provider]
    $stale = $script:PollSnapshots[1][$provider]
    Assert-Equal 'ok' $first.State ($provider + ' first poll succeeds')
    Assert-Equal 'stale' $stale.State ($provider + ' second poll uses stale cache')
    Assert-Equal $first.UpdatedAt $stale.UpdatedAt ($provider + ' stale poll retains successful timestamp')
    Assert-Equal 'auth' $script:PollSnapshots[2][$provider].State ($provider + ' auth poll does not hide behind cached data')
    Assert-Equal 'error' $script:PollSnapshots[3][$provider].State ($provider + ' auth poll invalidates the cached balance')
    Assert-Equal $null $script:PollSnapshots[3][$provider].UpdatedAt ($provider + ' failed poll after auth has no timestamp')
}

$changedIdentity = $enabled.Clone()
$changedIdentity.ProtectedApiKey = 'different-fixture-ciphertext'
Invoke-FixturePolling @(
    @{ Settings = $enabled; Cursor = $script:CursorResult; Token = $script:TokenResult },
    @{ Settings = $changedIdentity; Cursor = $errorReading; Token = $errorReading }
)
Assert-Equal 'stale' $script:PollSnapshots[1].Cursor.State 'unchanged Cursor connection keeps its cache'
Assert-Equal 'error' $script:PollSnapshots[1].Token.State 'changed API key invalidates the old balance'
Assert-Equal $null $script:PollSnapshots[1].Token.UpdatedAt 'changed API key has no prior success time'

$changedDailyLimit = $enabled.Clone()
$changedDailyLimit.ApiDailyLimitUsd = 500
Invoke-FixturePolling @(
    @{ Settings = $enabled; Cursor = $script:CursorResult; Token = $script:TokenResult },
    @{ Settings = $changedDailyLimit; Cursor = $errorReading; Token = $errorReading },
    @{ Settings = $changedDailyLimit; Cursor = $script:CursorResult; Token = $script:TokenResult },
    @{ Settings = $changedDailyLimit; Cursor = $errorReading; Token = $rateLimited }
)
Assert-Equal 400 $script:PollSnapshots[0].TokenArgs.DailyLimitUsd 'initial polling passes configured daily limit'
Assert-Equal 500 $script:PollSnapshots[1].TokenArgs.DailyLimitUsd 'changed daily limit reaches next provider call'
Assert-Equal 'stale' $script:PollSnapshots[1].Cursor.State 'daily limit change does not invalidate Cursor cache'
Assert-Equal 'error' $script:PollSnapshots[1].Token.State 'daily limit change invalidates previously computed daily balance'
Assert-Equal $null $script:PollSnapshots[1].Token.UpdatedAt 'changed daily limit has no old success timestamp'
Assert-Equal 'stale' $script:PollSnapshots[3].Token.State 'success with new limit can be cached for later transient failure'
Assert-Equal $script:PollSnapshots[2].Token.UpdatedAt $script:PollSnapshots[3].Token.UpdatedAt 'new-limit cache retains the new successful timestamp'

$clearedDailyLimit = $enabled.Clone()
$clearedDailyLimit.ApiDailyLimitUsd = $null
$zeroDailyLimit = $enabled.Clone()
$zeroDailyLimit.ApiDailyLimitUsd = 0
Invoke-FixturePolling @(
    @{ Settings = $enabled; Cursor = $script:CursorResult; Token = $script:TokenResult },
    @{ Settings = $clearedDailyLimit; Cursor = $script:CursorResult; Token = $errorReading },
    @{ Settings = $clearedDailyLimit; Cursor = $script:CursorResult; Token = $script:TokenResult },
    @{ Settings = $zeroDailyLimit; Cursor = $script:CursorResult; Token = $errorReading }
)
Assert-Equal $null $script:PollSnapshots[1].TokenArgs.DailyLimitUsd 'cleared daily limit is passed as null'
Assert-Equal 'error' $script:PollSnapshots[1].Token.State 'cleared daily limit invalidates a prior daily balance'
Assert-Equal 0 $script:PollSnapshots[3].TokenArgs.DailyLimitUsd 'zero daily limit is passed without becoming null'
Assert-Equal 'error' $script:PollSnapshots[3].Token.State 'zero limit is a distinct cache identity from no configured limit'

Assert-Equal 0 $script:NetworkCalls 'no test performed a network request'
Write-Output 'Quota worker tests passed.'
