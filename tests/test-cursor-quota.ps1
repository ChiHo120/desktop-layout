$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'cursor-quota.ps1')

$script:assertions = 0
function Assert-CursorEqual {
    param($Actual, $Expected, [string]$Message)
    $script:assertions++
    if ($Actual -ne $Expected) { throw ('Assertion failed: ' + $Message) }
}
function Assert-CursorContains {
    param([string]$Actual, [string]$Expected, [string]$Message)
    $script:assertions++
    if (-not $Actual.Contains($Expected)) { throw ('Assertion failed: ' + $Message) }
}

$remaining = ConvertFrom-CursorQuota '{"individualUsage":{"plan":{"enabled":true,"used":500,"limit":2000,"remaining":1500},"onDemand":{"enabled":true,"used":1250,"limit":null}}}'
Assert-CursorEqual $remaining.State 'ok' 'known balance state'
Assert-CursorEqual $remaining.Text '套餐余 $15.00' 'cents converted to USD'
Assert-CursorEqual $remaining.RemainingPercent 75 'remaining percent'
Assert-CursorContains $remaining.Detail '按量已用 $12.50' 'on-demand spending stays separate'
Assert-CursorEqual ($remaining.UpdatedAt -is [DateTime]) $true 'timestamp returned'

$zero = ConvertFrom-CursorQuota @{ individualUsage = @{ plan = @{ remaining = 0; used = 2000; limit = 2000 } } }
Assert-CursorEqual $zero.State 'ok' 'zero is known'
Assert-CursorEqual $zero.Text '套餐余 $0.00' 'zero displayed'
Assert-CursorEqual $zero.RemainingPercent 0 'zero percentage'

$derived = ConvertFrom-CursorQuota '{"individualUsage":{"plan":{"used":500,"limit":2000}}}'
Assert-CursorEqual $derived.Text '套餐余 $15.00' 'derive only from known used and limit'
$partial = ConvertFrom-CursorQuota '{"individualUsage":{"plan":{"remaining":700}}}'
Assert-CursorEqual $partial.Text '套餐余 $7.00' 'remaining without limit is useful'
Assert-CursorEqual $partial.RemainingPercent $null 'missing denominator stays unknown'
$percentage = ConvertFrom-CursorQuota '{"individualUsage":{"plan":{"totalPercentUsed":0.36}}}'
Assert-CursorEqual $percentage.Text '总额度余 99.64%' 'sub-one percentages are already percentages'
Assert-CursorEqual $percentage.RemainingPercent 99.64 'reported percentage fallback'
$autoOnly = ConvertFrom-CursorQuota '{"individualUsage":{"plan":{"autoPercentUsed":21.57}}}'
Assert-CursorEqual $autoOnly.Text 'Auto余 78.43%' 'partial bucket data is not mislabeled as total quota'
Assert-CursorContains $autoOnly.Detail '总额度比例未提供' 'missing total bucket stays explicit'
$overage = ConvertFrom-CursorQuota '{"individualUsage":{"plan":{"used":2500,"limit":2000}}}'
Assert-CursorEqual $overage.Text '套餐余 $0.00' 'overage has no remaining credits'

# Current Cursor responses expose normalized usage buckets. These percentages
# are authoritative for the active cycle even when legacy money fields are
# capped at the included allowance.
$current = ConvertFrom-CursorQuota ([pscustomobject]@{
    billingCycleStart = '2026-10-24T12:59:01.000Z'
    billingCycleEnd = '2026-11-24T12:59:01.000Z'
    individualUsage = [pscustomobject]@{
        plan = [pscustomobject]@{
            enabled = $true; used = 40000; limit = 40000; remaining = 0
            breakdown = [pscustomobject]@{ included = 40000; bonus = 29172; total = 69172 }
            autoPercentUsed = 21.573666666666664
            apiPercentUsed = 17.804000000000002
            totalPercentUsed = 21.28369230769231
        }
        onDemand = [pscustomobject]@{ enabled = $false; used = 0 }
    }
})
Assert-CursorEqual $current.State 'ok' 'current bucket state'
Assert-CursorEqual $current.Text '总额度余 78.72%' 'current cycle uses normalized total percentage'
Assert-CursorEqual $current.RemainingPercent 78.72 'current total remaining percentage'
Assert-CursorContains $current.Detail '总额度剩余 78.72%' 'total remainder shown'
Assert-CursorContains $current.Detail 'Auto剩余 78.43%' 'Auto remainder shown'
Assert-CursorContains $current.Detail 'API剩余 82.2%' 'API remainder shown'
Assert-CursorContains $current.Detail '奖励额度 $291.72' 'bonus amount shown separately'
Assert-CursorContains $current.Detail '合计额度 $691.72' 'combined allowance shown separately'
Assert-CursorContains $current.Detail '周期 2026-10-24 至 2026-11-24' 'current billing cycle shown'
Assert-CursorContains $current.Detail '不从旧金额字段推算' 'legacy money fields are not used as current balance'
Assert-CursorEqual $current.Buckets.Auto.State 'ok' 'Auto bucket is available'
Assert-CursorEqual $current.Buckets.Auto.RemainingPercent 78.43 'Auto keeps Cursor first-party usage percentage'
Assert-CursorEqual $current.Buckets.Advanced.State 'ok' 'advanced model bucket is available'
Assert-CursorEqual $current.Buckets.Advanced.RemainingPercent 82.2 'advanced bucket keeps Cursor API usage percentage'
Assert-CursorEqual $current.Buckets.Grok.State 'unsupported' 'Grok is not inferred from Auto'
Assert-CursorEqual $current.Buckets.Grok.RemainingPercent $null 'missing Grok percentage remains unknown'
Assert-CursorContains $current.Buckets.Grok.Detail '当前周期额度接口未提供独立字段' 'unavailable Grok bucket explains missing independent field'

$grok = ConvertFrom-CursorGrokQuota '{"usagePercent":5.206594,"currentPeriodStart":"2026-10-24T17:52:17.988Z","nextResetTimestampUtc":"2026-10-31T17:52:17.988Z","hasAvailableUsage":true,"hasNonZeroIncludedLimit":true,"grokPlanLabel":"Grok Bot Plan","cursorPlanName":"Ultra"}'
Assert-CursorEqual $grok.State 'ok' 'Grok weekly response is available'
Assert-CursorEqual $grok.RemainingPercent 94.79 'Grok usage percent converts to remaining percent'
Assert-CursorEqual $grok.Text '剩余 94.79%' 'Grok remaining display is percentage based'
Assert-CursorContains $grok.Detail 'Grok Bot Plan' 'Grok plan label is retained'
$grokCycleStart = ([DateTimeOffset]'2026-10-24T17:52:17.988Z').ToLocalTime().ToString('yyyy-MM-dd')
$grokCycleEnd = ([DateTimeOffset]'2026-10-31T17:52:17.988Z').ToLocalTime().ToString('yyyy-MM-dd')
Assert-CursorContains $grok.Detail ('周期 ' + $grokCycleStart + ' 至 ' + $grokCycleEnd) 'Grok weekly cycle is shown in local date'
Assert-CursorContains $grok.Detail ('重置 ' + $grokCycleEnd) 'Grok reset date is shown'
Assert-CursorContains $grok.Detail '（本地时间）' 'Grok reset timezone is explicit'
$grokExhausted = ConvertFrom-CursorGrokQuota @{ usagePercent = 125; hasAvailableUsage = $false }
Assert-CursorEqual $grokExhausted.RemainingPercent 0 'Grok usage is clamped at exhausted'
Assert-CursorEqual $grokExhausted.State 'window-exhausted' 'Grok exhaustion is a successful zero balance'
Assert-CursorContains $grokExhausted.Detail '当前周期已无可用额度' 'Grok exhausted state is explicit'
$grokExplicitlyUnavailable = ConvertFrom-CursorGrokQuota @{ usagePercent = 20; hasAvailableUsage = $false; hasNonZeroIncludedLimit = $true }
Assert-CursorEqual $grokExplicitlyUnavailable.RemainingPercent 0 'explicit no-availability overrides a stale positive percentage'
Assert-CursorEqual $grokExplicitlyUnavailable.State 'window-exhausted' 'included Grok quota with no availability is exhausted'
$grokUnavailableWithoutUsage = ConvertFrom-CursorGrokQuota @{ hasAvailableUsage = $false; hasNonZeroIncludedLimit = $true }
Assert-CursorEqual $grokUnavailableWithoutUsage.RemainingPercent 0 'explicit exhaustion does not require a percentage field'
$grokUnknown = ConvertFrom-CursorGrokQuota '{"currentPeriodStart":"2026-10-24T00:00:00Z"}'
Assert-CursorEqual $grokUnknown.State 'unsupported' 'missing Grok usage stays unknown'
Assert-CursorEqual $grokUnknown.RemainingPercent $null 'missing Grok usage does not fabricate remainder'
Assert-CursorEqual (Get-CursorGrokQuota -Cookie '').State 'unsupported' 'Grok request without cookie is unavailable'
Assert-CursorEqual (ConvertFrom-CursorGrokQuota '{"usagePercent":0}').RemainingPercent 100 'Grok zero usage is full remaining allowance'
Assert-CursorEqual (ConvertFrom-CursorGrokQuota '{"usagePercent":0.5}').RemainingPercent 99.5 'Grok sub-one value is already a percent'
$grokNotIncluded = ConvertFrom-CursorGrokQuota @{ usagePercent = 0; hasNonZeroIncludedLimit = $false }
Assert-CursorEqual $grokNotIncluded.State 'unsupported' 'Grok without an included allowance is not a full balance'
Assert-CursorEqual $grokNotIncluded.RemainingPercent $null 'Grok without an allowance has no percentage'
foreach ($grokFixture in @($null, '', 'not json', '{}', '[]', '{"usagePercent":-1}', '{"usagePercent":"NaN"}', '{"usagePercent":true}')) {
    $grokInvalid = ConvertFrom-CursorGrokQuota -Response $grokFixture
    Assert-CursorEqual $grokInvalid.State 'unsupported' 'Grok invalid responses remain isolated and unavailable'
    Assert-CursorEqual $grokInvalid.RemainingPercent $null 'Grok invalid responses never manufacture a percentage'
}

$withoutBuckets = ConvertFrom-CursorQuota '{"individualUsage":{"plan":{"totalPercentUsed":10,"autoPercentUsed":20,"apiPercentUsed":30}}}'
Assert-CursorEqual $withoutBuckets.Buckets.Auto.RemainingPercent 80 'Auto uses its own percentage field'
Assert-CursorEqual $withoutBuckets.Buckets.Advanced.RemainingPercent 70 'advanced uses its own percentage field'
Assert-CursorEqual $withoutBuckets.Buckets.Grok.State 'unsupported' 'no Grok bucket is fabricated from Auto or API'
Assert-CursorEqual $withoutBuckets.Buckets.Grok.RemainingPercent $null 'unsupported Grok remains unknown'

foreach ($fixture in @(
    $null, '', 'not json', '[]', '{}', 'null',
    '{"individualUsage":{"plan":{"limit":2000}}}',
    '{"individualUsage":{"plan":{"used":500,"breakdown":{"total":2000}}}}',
    '{"individualUsage":{"plan":{"remaining":true}}}',
    '{"individualUsage":{"plan":{"remaining":"NaN"}}}',
    '{"individualUsage":{"plan":{"remaining":-1}}}',
    '{"individualUsage":{"plan":{"enabled":false,"remaining":2000}}}'
)) {
    $unknown = ConvertFrom-CursorQuota -Response $fixture
    Assert-CursorEqual $unknown.State 'unsupported' 'unsupported data is explicit'
    Assert-CursorEqual $unknown.RemainingPercent $null 'unsupported data never fabricates a percentage'
    Assert-CursorEqual $unknown.Buckets.Grok.State 'unsupported' 'Grok remains unavailable without independent source data'
}
$onlyDemand = ConvertFrom-CursorQuota '{"individualUsage":{"onDemand":{"used":500,"limit":2000}}}'
Assert-CursorEqual $onlyDemand.State 'unsupported' 'on-demand limit is not a plan balance'
Assert-CursorContains $onlyDemand.Detail '按量已用 $5.00' 'unknown plan can still explain on-demand spending'
$pooled = ConvertFrom-CursorQuota '{"teamUsage":{"pooled":{"used":2500,"limit":10000}}}'
Assert-CursorEqual $pooled.Text '团队共享余 $75.00' 'team balances are clearly identified'

# Only synthetic tokens are used; these tests never read the real Cursor database.
function New-FakeCursorToken {
    param([string]$Claims)
    $base64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Claims)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    return 'eyJhbGciOiJub25lIn0.' + $base64 + '.fake'
}
$clock = [DateTime]::SpecifyKind([DateTime]'2026-01-01', [DateTimeKind]::Utc)
$fake = New-FakeCursorToken '{"sub":"auth0|fake_user-1","exp":2000000000}'
$cookie = ConvertTo-CursorSessionCookie -AccessToken $fake -Now $clock
Assert-CursorEqual $cookie ('WorkosCursorSessionToken=fake_user-1%3A%3A' + $fake) 'cookie format'
$expired = New-FakeCursorToken '{"sub":"auth0|fake_user-1","exp":1}'
Assert-CursorEqual (ConvertTo-CursorSessionCookie -AccessToken $expired -Now $clock) $null 'expired token is rejected'
$unsafe = New-FakeCursorToken '{"sub":"auth0|bad;user","exp":2000000000}'
Assert-CursorEqual (ConvertTo-CursorSessionCookie -AccessToken $unsafe -Now $clock) $null 'unsafe cookie user id is rejected'
Assert-CursorEqual (ConvertTo-CursorSessionCookie -AccessToken 'not-a-jwt' -Now $clock) $null 'malformed token is rejected'

# Compile the native wrapper without invoking a database read.
Initialize-CursorQuotaSqlite
Assert-CursorEqual ([bool]('SpiritQuota.CursorSqlite' -as [type])) $true 'native reader compiles on Windows PowerShell'

$fixtureType = @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
namespace SpiritQuotaTest {
    public static class FixtureDatabase {
        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_open_v2(byte[] filename, out IntPtr db, int flags, IntPtr vfs);
        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl, CharSet = CharSet.Ansi)]
        private static extern int sqlite3_exec(IntPtr db, string sql, IntPtr callback, IntPtr state, out IntPtr error);
        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_close(IntPtr db);
        public static void Create(string path, int mode) {
            IntPtr db = IntPtr.Zero;
            IntPtr error = IntPtr.Zero;
            try {
                int code = sqlite3_open_v2(Encoding.UTF8.GetBytes(path + "\0"), out db, 2 | 4, IntPtr.Zero);
                if (code != 0) throw new InvalidOperationException("Fixture SQLite open failed.");
                string value = "'fixture-access-token.only'";
                if (mode == 1 || mode == 2) {
                    byte[] bytes = (mode == 1 ? Encoding.UTF8 : Encoding.Unicode).GetBytes("fixture-access-token.only");
                    value = "X'" + BitConverter.ToString(bytes).Replace("-", "") + "'";
                }
                if (mode == 3) value = "NULL";
                string sql = "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value BLOB);" +
                    "INSERT INTO ItemTable VALUES ('cursorAuth/refreshToken', 'wrong-refresh-token');";
                if (mode != 4) sql += "INSERT INTO ItemTable VALUES ('cursorAuth/accessToken', " + value + ");";
                code = sqlite3_exec(db, sql, IntPtr.Zero, IntPtr.Zero, out error);
                if (code != 0) throw new InvalidOperationException("Fixture SQLite setup failed.");
            } finally {
                if (error != IntPtr.Zero) sqlite3_free(error);
                if (db != IntPtr.Zero) sqlite3_close(db);
            }
        }
        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern void sqlite3_free(IntPtr pointer);
    }
}
'@
Add-Type -TypeDefinition $fixtureType -Language CSharp -ErrorAction Stop
$fixtureDirectory = Join-Path ([IO.Path]::GetTempPath()) ('spirit-cursor-quota-测试-' + [Guid]::NewGuid().ToString('N'))
try {
    [void][IO.Directory]::CreateDirectory($fixtureDirectory)
    foreach ($mode in 0..4) {
        $fixturePath = Join-Path $fixtureDirectory ('fixture-' + $mode + '.vscdb')
        try {
            [SpiritQuotaTest.FixtureDatabase]::Create($fixturePath, $mode)
            $hashBefore = (Get-FileHash -LiteralPath $fixturePath -Algorithm SHA256).Hash
            [IO.File]::SetAttributes($fixturePath, [IO.FileAttributes]::ReadOnly)
            $storedFake = [SpiritQuota.CursorSqlite]::ReadAccessToken($fixturePath)
            $expectedFake = $null
            if ($mode -lt 3) { $expectedFake = 'fixture-access-token.only' }
            Assert-CursorEqual $storedFake $expectedFake 'native SQLite handles text, UTF-8/UTF-16 blobs, missing values and exact key'
            Assert-CursorEqual ((Get-FileHash -LiteralPath $fixturePath -Algorithm SHA256).Hash) $hashBefore 'credential reads leave database bytes unchanged'
        } finally {
            if ([IO.File]::Exists($fixturePath)) {
                [IO.File]::SetAttributes($fixturePath, [IO.FileAttributes]::Normal)
                [IO.File]::Delete($fixturePath)
            }
        }
    }
} finally {
    if ([IO.Directory]::Exists($fixtureDirectory)) { [IO.Directory]::Delete($fixtureDirectory) }
}
Write-Output ('Cursor quota tests passed: {0} assertions' -f $script:assertions)
