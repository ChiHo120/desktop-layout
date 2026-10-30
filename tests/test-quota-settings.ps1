param(
    [string]$Action = '',
    [string]$StateDir = ''
)

$ErrorActionPreference = 'Stop'
if ($Action) {
    if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
        throw 'Run this test with powershell.exe -STA.'
    }
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase
    $script:settingsSource = Join-Path (Split-Path -Parent $PSScriptRoot) 'quota-settings.ps1'
    $script:stateDir = $StateDir
    $script:action = $Action
    $script:app = New-Object System.Windows.Application
    $script:timer = New-Object System.Windows.Threading.DispatcherTimer
    $script:timer.Interval = [TimeSpan]::FromMilliseconds(50)
    $script:dialogFound = $false
    $script:dialogError = $null
    $script:validationFailure = ''
    $script:timer.Add_Tick({
        $dialog = @($script:app.Windows | Where-Object { $null -ne $_.FindName('ApiKey') }) | Select-Object -First 1
        if ($null -eq $dialog) { return }
        $script:dialogFound = $true
        # Focus changes can pump the dispatcher while a validation action runs.
        # Each fixture interaction must be driven once, without a nested tick.
        $script:timer.Stop()
        switch ($script:action) {
            'save-new' {
                $dialog.FindName('CursorEnabled').IsChecked = $true
                $dialog.FindName('ApiEnabled').IsChecked = $true
                $dialog.FindName('AllowInsecureHttp').IsChecked = $true
                $dialog.FindName('ApiKey').Password = 'synthetic-settings-save-regression'
                $dialog.FindName('ApiDailyLimitUsd').Text = '400'
                $save = $dialog.FindName('Save')
                $save.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, $save))
            }
            'retain' {
                if ($dialog.FindName('ApiDailyLimitUsd').Text -ne '400') { $script:validationFailure = 'The saved daily limit was not shown in the dialog.' }
                $save = $dialog.FindName('Save')
                $save.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, $save))
            }
            'cancel' {
                $dialog.FindName('ApiKey').Password = 'synthetic-settings-replacement'
                $dialog.FindName('ApiDailyLimitUsd').Text = '800'
                $cancel = $dialog.FindName('Cancel')
                $cancel.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, $cancel))
            }
            'clear-cancel' {
                $dialog.FindName('ApiDailyLimitUsd').Text = ''
                $clear = $dialog.FindName('ClearKey')
                $clear.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, $clear))
                $cancel = $dialog.FindName('Cancel')
                $cancel.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, $cancel))
            }
            'limit-invalid' {
                $dialog.FindName('ApiDailyLimitUsd').Text = '-1'
                $save = $dialog.FindName('Save')
                $save.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, $save))
                if (-not $dialog.FindName('Validation').Text) { $script:validationFailure = 'An invalid daily limit was accepted.' }
                $cancel = $dialog.FindName('Cancel')
                $cancel.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, $cancel))
            }
            'limit-zero' {
                $dialog.FindName('ApiDailyLimitUsd').Text = '0'
                $save = $dialog.FindName('Save')
                $save.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, $save))
            }
            'limit-clear' {
                if ($dialog.FindName('ApiDailyLimitUsd').Text -ne '0') { $script:validationFailure = 'A zero daily limit was not retained.' }
                $dialog.FindName('ApiDailyLimitUsd').Text = ''
                $save = $dialog.FindName('Save')
                $save.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, $save))
            }
            'clear-save' {
                $clear = $dialog.FindName('ClearKey')
                $clear.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, $clear))
                $save = $dialog.FindName('Save')
                $save.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, $save))
            }
            'replace-unreadable' {
                $save = $dialog.FindName('Save')
                $save.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, $save))
                if ([string]::IsNullOrWhiteSpace([string]$dialog.FindName('Validation').Text)) { $script:validationFailure = 'Saving an empty replacement did not show a validation message.' }
                $dialog.FindName('ApiKey').Password = 'synthetic-settings-recovered-key'
                $dialog.FindName('ApiEnabled').IsChecked = $true
                $save.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, $save))
            }
        }
    })
    $menuItem = New-Object System.Windows.Controls.MenuItem
    $menuItem.Add_Click({
        try {
            . $script:settingsSource
            [void](Show-SpiritQuotaSettings -Owner $null -StateDir $script:stateDir)
        } catch {
            $script:dialogError = $_
        }
    })
    $script:timer.Start()
    try {
        $menuItem.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.MenuItem]::ClickEvent, $menuItem))
    } finally {
        $script:timer.Stop()
    }
    if ($script:dialogError) { throw ('Synthetic UI action failed: ' + $script:dialogError.Exception.GetType().Name) }
    if ($script:validationFailure) { throw $script:validationFailure }
    if (-not $script:dialogFound) { throw ('Synthetic UI action did not reach the settings window: ' + $Action) }
    Write-Output ($script:action.ToUpperInvariant() + '_OK')
    $script:app.Shutdown()
    exit 0
}

# Each interaction runs in a clean PS5.1 process, as the pet loads its module from a menu callback.
$fixturePath = Join-Path ([IO.Path]::GetTempPath()) ('spirit-quota-settings-' + [guid]::NewGuid().ToString('N'))
try {
    foreach ($scenario in @('save-new', 'retain', 'cancel', 'clear-cancel', 'limit-invalid', 'limit-zero', 'limit-clear', 'clear-save')) {
        $savedErrorAction = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $output = & powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $PSCommandPath -Action $scenario -StateDir $fixturePath 2>&1
        $ErrorActionPreference = $savedErrorAction
        if ($LASTEXITCODE -ne 0) { throw ('Scenario failed (' + $scenario + '): ' + ($output -join ' ')) }
        $saved = $null
        $settingsPath = Join-Path $fixturePath 'quotas.json'
        if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
            $saved = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        }
        if ($scenario -ne 'clear-save') {
            if ($null -eq $saved -or -not $saved.ApiEnabled -or -not $saved.AllowInsecureHttp -or -not $saved.ProtectedApiKey) {
                throw ('Expected API settings were not preserved after ' + $scenario + '.')
            }
            $secure = ConvertTo-SecureString -String ([string]$saved.ProtectedApiKey) -ErrorAction Stop
            $buffer = [IntPtr]::Zero
            try {
                $buffer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
                $roundTrip = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($buffer)
            } finally {
                if ($buffer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($buffer) }
                $secure.Dispose()
            }
            if ($roundTrip -ne 'synthetic-settings-save-regression') { throw ('Synthetic key round-trip failed after ' + $scenario + '.') }
        } elseif ($null -eq $saved -or $saved.ApiEnabled -or $saved.ProtectedApiKey) {
            throw 'Confirmed clear did not remove the key and disable API.'
        }
        if ($scenario -in @('save-new', 'retain', 'cancel', 'clear-cancel', 'limit-invalid')) {
            if ($saved.ApiDailyLimitUsd -ne 400) { throw ('Expected daily limit was not preserved after ' + $scenario + '.') }
        } elseif ($scenario -eq 'limit-zero') {
            if ($null -eq $saved.ApiDailyLimitUsd -or $saved.ApiDailyLimitUsd -ne 0) { throw 'Zero daily limit was not saved.' }
        } elseif ($null -ne $saved.ApiDailyLimitUsd) {
            throw ('A cleared daily limit was not saved as null after ' + $scenario + '.')
        }
        Write-Output ($scenario.ToUpperInvariant() + '_OK')
    }

    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'quota-settings.ps1')
    $readBack = Get-SpiritQuotaSettings $fixturePath
    if ($null -ne $readBack.ApiDailyLimitUsd) { throw 'An empty daily limit did not read back as null.' }
    foreach ($value in @([double]400.25, [decimal]12.5, '0')) {
        $readBack.ApiDailyLimitUsd = $value
        Save-SpiritQuotaSettings $fixturePath $readBack
        $loaded = Get-SpiritQuotaSettings $fixturePath
        if ($null -eq $loaded.ApiDailyLimitUsd -or $loaded.ApiDailyLimitUsd -ne [double]$value) { throw 'Daily limit numeric round-trip failed.' }
    }
    $beforeInvalid = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8
    foreach ($invalidValue in @(-1, [double]::NaN, [double]::PositiveInfinity, [double]::NegativeInfinity, $true, 'bad-number')) {
        $readBack.ApiDailyLimitUsd = $invalidValue
        $rejected = $false
        try { Save-SpiritQuotaSettings $fixturePath $readBack }
        catch { $rejected = $true }
        if (-not $rejected) { throw 'An invalid numeric daily limit was accepted.' }
        if ((Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8) -cne $beforeInvalid) { throw 'Invalid daily limit changed the settings file.' }
    }
    Write-Output 'DAILY_LIMIT_NUMERIC_OK'

    $invalidPayload = [ordered]@{
        CursorEnabled = $true
        ApiEnabled = $true
        AllowInsecureHttp = $true
        ProtectedApiKey = '01000000d08c9ddf0100000000000000-invalid-dpapi-blob'
        ApiDailyLimitUsd = 400
    }
    $invalidPayload | ConvertTo-Json | Set-Content -LiteralPath $settingsPath -Encoding UTF8
    $beforeReplacement = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8
    $invalidRead = Get-SpiritQuotaSettings $fixturePath
    if (-not $invalidRead.ApiKeyNeedsReplacement -or -not $invalidRead.ApiEnabled -or $invalidRead.ProtectedApiKey) {
        throw 'Unreadable saved key was not marked for replacement.'
    }
    if ((Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8) -cne $beforeReplacement) {
        throw 'Reading an unreadable saved key changed the settings file.'
    }
    $savedErrorAction = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $replacementOutput = & powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $PSCommandPath -Action 'replace-unreadable' -StateDir $fixturePath 2>&1
    $replacementExitCode = $LASTEXITCODE
    $ErrorActionPreference = $savedErrorAction
    if ($replacementExitCode -ne 0) { throw ('Unreadable-key replacement failed: ' + ($replacementOutput -join ' ')) }
    $recovered = Get-SpiritQuotaSettings $fixturePath
    if ($recovered.ApiKeyNeedsReplacement -or -not $recovered.ApiEnabled -or (Get-SpiritApiKey $recovered) -ne 'synthetic-settings-recovered-key') {
        throw 'Replacement key did not save and read back.'
    }
    Write-Output 'INVALID_KEY_REPLACEMENT_OK'
    Write-Output 'SETTINGS_SAVE_OK'
} finally {
    if (Test-Path -LiteralPath $fixturePath) { Remove-Item -LiteralPath $fixturePath -Recurse -Force }
}
