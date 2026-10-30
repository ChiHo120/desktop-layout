function Get-SpiritQuotaSettings {
    param([Parameter(Mandatory = $true)][string]$StateDir)

    $settings = @{
        CursorEnabled = $true
        ApiEnabled = $false
        AllowInsecureHttp = $false
        ProtectedApiKey = ''
        ApiKeyNeedsReplacement = $false
        ApiDailyLimitUsd = $null
    }
    $settingsPath = Join-Path $StateDir 'quotas.json'
    if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) { return $settings }

    try {
        $saved = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        foreach ($name in @('CursorEnabled', 'ApiEnabled', 'AllowInsecureHttp')) {
            if ($saved.$name -is [bool]) { $settings[$name] = $saved.$name }
        }
        if ($saved.ProtectedApiKey -is [string] -and $saved.ProtectedApiKey) {
            $settings.ProtectedApiKey = [string]$saved.ProtectedApiKey
        }
        if ($null -ne $saved.ApiDailyLimitUsd) {
            try { $settings.ApiDailyLimitUsd = ConvertTo-SpiritQuotaDailyLimit $saved.ApiDailyLimitUsd }
            catch { $settings.ApiDailyLimitUsd = $null }
        }
    } catch {
        return $settings
    }

    if ($settings.ApiEnabled -and $settings.AllowInsecureHttp -and $settings.ProtectedApiKey) {
        $secure = $null
        try {
            $secure = ConvertTo-SecureString -String $settings.ProtectedApiKey -ErrorAction Stop
            if ($secure.Length -eq 0) { $settings.ProtectedApiKey = '' }
        } catch {
            # Only active connections need to decrypt the saved credential.
            $settings.ProtectedApiKey = ''
            $settings.ApiKeyNeedsReplacement = $true
        } finally {
            if ($null -ne $secure) { $secure.Dispose() }
        }
    }
    if ((-not $settings.ProtectedApiKey -or -not $settings.AllowInsecureHttp) -and -not $settings.ApiKeyNeedsReplacement) {
        $settings.ApiEnabled = $false
    }
    return $settings
}

function ConvertTo-SpiritQuotaDailyLimit {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [bool]) { throw '每日上限必须是非负有限数值。' }
    $number = 0.0
    $valid = $false
    if ($Value -is [string]) {
        $text = $Value.Trim()
        if (-not $text) { return $null }
        $valid = [double]::TryParse($text, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$number)
    } else {
        try {
            $number = [Convert]::ToDouble($Value, [System.Globalization.CultureInfo]::InvariantCulture)
            $valid = $true
        } catch {}
    }
    if (-not $valid -or [double]::IsNaN($number) -or [double]::IsInfinity($number) -or $number -lt 0) {
        throw '每日上限必须是非负有限数值。'
    }
    return $number
}

function Save-SpiritQuotaSettings {
    param(
        [Parameter(Mandatory = $true)][string]$StateDir,
        [Parameter(Mandatory = $true)]$Settings
    )

    $payload = [ordered]@{
        CursorEnabled = $true
        ApiEnabled = $false
        AllowInsecureHttp = $false
        ProtectedApiKey = ''
        ApiDailyLimitUsd = $null
    }
    foreach ($name in @('CursorEnabled', 'ApiEnabled', 'AllowInsecureHttp')) {
        if ($Settings.$name -is [bool]) { $payload[$name] = $Settings.$name }
    }
    $payload.ApiDailyLimitUsd = ConvertTo-SpiritQuotaDailyLimit $Settings.ApiDailyLimitUsd
    $ciphertext = [string]$Settings.ProtectedApiKey
    if ($ciphertext) {
        $secure = $null
        try {
            $secure = ConvertTo-SecureString -String $ciphertext -ErrorAction Stop
            if ($secure.Length -eq 0) { throw 'API Key 为空。' }
            $payload.ProtectedApiKey = $ciphertext
        } catch {
            throw 'API Key 无法在当前 Windows 用户下解密，请重新输入后保存。'
        } finally {
            if ($null -ne $secure) { $secure.Dispose() }
        }
    }
    if ($payload.ApiEnabled -and (-not $payload.ProtectedApiKey -or -not $payload.AllowInsecureHttp)) {
        throw '启用 API 额度前，请填写 API Key 并确认允许 HTTP 明文传输。'
    }

    if (-not (Test-Path -LiteralPath $StateDir -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $StateDir -Force -ErrorAction Stop)
    }
    $settingsPath = Join-Path $StateDir 'quotas.json'
    $temporaryPath = Join-Path $StateDir ('quotas.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $json = $payload | ConvertTo-Json
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($temporaryPath, $json, $utf8)
        if ([System.IO.File]::Exists($settingsPath)) {
            $backupPath = $settingsPath + '.bak'
            if ([System.IO.File]::Exists($backupPath)) { [System.IO.File]::Delete($backupPath) }
            [System.IO.File]::Replace($temporaryPath, $settingsPath, $backupPath)
            if ([System.IO.File]::Exists($backupPath)) { [System.IO.File]::Delete($backupPath) }
        } else {
            [System.IO.File]::Move($temporaryPath, $settingsPath)
        }
    } finally {
        if ([System.IO.File]::Exists($temporaryPath)) {
            try { [System.IO.File]::Delete($temporaryPath) } catch { }
        }
    }
}

function Get-SpiritQuotaSaveErrorText {
    param($ErrorRecord)

    $exception = $ErrorRecord.Exception
    if ($exception -is [System.Security.Cryptography.CryptographicException]) {
        return 'API Key 加密失败，设置未保存。请重新输入 Key 后重试。'
    }
    if ($exception -is [System.UnauthorizedAccessException]) {
        return '保存失败：本机设置目录不可写。请检查目录权限后重试。'
    }
    if ($exception -is [System.IO.DirectoryNotFoundException] -or $exception -is [System.IO.PathTooLongException]) {
        return '保存失败：本机设置目录不可用。请重启小灵后重试。'
    }
    if ($exception -is [System.IO.IOException]) {
        return '保存失败：设置文件无法写入。请关闭占用该文件的程序并检查磁盘空间。'
    }

    $message = [string]$exception.Message
    if ($message -eq 'API Key 无法在当前 Windows 用户下解密，请重新输入后保存。') {
        return 'API Key 无法在当前 Windows 用户下解密，设置未保存。请重新输入 Key 后重试。'
    }
    if ($message -eq '启用 API 额度前，请填写 API Key 并确认允许 HTTP 明文传输。') {
        return '请填写 API Key，并确认允许 HTTP 明文传输后再保存。'
    }
    if ($message -eq '每日上限必须是非负有限数值。') {
        return '请输入非负有限数字，例如 400；留空表示不设置每日上限。'
    }
    return '保存失败：设置未写入。请重新输入 API Key 后重试；若仍失败，请重启小灵。'
}

function Get-SpiritApiKey {
    param($Settings)

    $ciphertext = [string]$Settings.ProtectedApiKey
    if (-not $ciphertext) { return '' }
    $secure = $null
    $buffer = [IntPtr]::Zero
    try {
        $secure = ConvertTo-SecureString -String $ciphertext -ErrorAction Stop
        $buffer = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($buffer)
    } catch {
        return ''
    } finally {
        if ($buffer -ne [IntPtr]::Zero) { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($buffer) }
        if ($null -ne $secure) { $secure.Dispose() }
    }
}

function Protect-SpiritApiKey {
    param([string]$ApiKey)

    if ([string]::IsNullOrEmpty($ApiKey)) { return '' }
    $secure = $null
    try {
        $secure = ConvertTo-SecureString -String $ApiKey -AsPlainText -Force -ErrorAction Stop
        return ConvertFrom-SecureString -SecureString $secure -ErrorAction Stop
    } finally {
        if ($null -ne $secure) { $secure.Dispose() }
    }
}

function Show-SpiritQuotaSettings {
    param(
        $Owner,
        [Parameter(Mandatory = $true)][string]$StateDir
    )

    Add-Type -AssemblyName PresentationFramework
    $original = Get-SpiritQuotaSettings $StateDir
    $dialogState = @{
        ProtectedApiKey = [string]$original.ProtectedApiKey
        ApiKeyNeedsReplacement = [bool]$original.ApiKeyNeedsReplacement
        Changed = $false
    }
    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="小灵 · 额度设置" Width="520" SizeToContent="Height"
        ResizeMode="NoResize" WindowStartupLocation="CenterOwner"
        ShowInTaskbar="False" FontFamily="Microsoft YaHei UI"
        Background="#F5F7FB">
    <StackPanel Margin="24">
        <TextBlock Text="额度设置" FontSize="21" FontWeight="SemiBold" Foreground="#18243B"/>
        <TextBlock Text="设置保存后，小灵会在后台自动刷新额度。" Margin="0,8,0,18" Foreground="#5F6C80" TextWrapping="Wrap"/>
        <CheckBox x:Name="CursorEnabled" Content="显示 Cursor 额度（读取本机已登录的 Cursor）" FontSize="13"/>
        <Separator Margin="0,18,0,18"/>
        <CheckBox x:Name="ApiEnabled" Content="显示 API 额度" FontSize="13"/>
        <TextBlock Text="API 地址：http://token.acerobotics.com/v1" Margin="0,10,0,14" Foreground="#5F6C80" TextWrapping="Wrap"/>
        <TextBlock Text="每日上限（美元）" Foreground="#18243B"/>
        <TextBox x:Name="ApiDailyLimitUsd" Height="32" Width="150" HorizontalAlignment="Left" Margin="0,6,0,0" Padding="7,4" ToolTip="仅在接口未提供每日上限时使用；请与仪表盘一致，后台调整后同步修改。留空不补上限。"/>
        <TextBlock Text="仅在接口未提供每日上限时使用；请与仪表盘一致，后台调整后同步修改。留空不补上限。" Margin="0,5,0,14" Foreground="#5F6C80" FontSize="11" TextWrapping="Wrap"/>
        <TextBlock Text="API Key" Foreground="#18243B"/>
        <PasswordBox x:Name="ApiKey" Height="32" Margin="0,6,0,0" Padding="7,4" ToolTip="输入新 Key 可替换；留空保留已保存的 Key。"/>
        <Grid Margin="0,7,0,14">
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <TextBlock x:Name="KeyStatus" VerticalAlignment="Center" Foreground="#5F6C80" FontSize="11" TextWrapping="Wrap" Margin="0,0,8,0"/>
            <Button x:Name="ClearKey" Grid.Column="1" Content="清除已保存的 Key" Padding="8,4"/>
        </Grid>
        <CheckBox x:Name="AllowInsecureHttp" VerticalContentAlignment="Center">
            <TextBlock Text="允许通过 HTTP 明文发送 API Key（连接未加密，Key 可能被截获）" TextWrapping="Wrap" Width="422" Foreground="#914B13"/>
        </CheckBox>
        <TextBlock Text="API Key 会加密保存在本机，仅当前 Windows 用户可读取。账号密码、Cookie 和 API Key 明文不会写入项目或日志。" Margin="0,15,0,0" FontSize="11" Foreground="#5F6C80" TextWrapping="Wrap"/>
        <TextBlock x:Name="Validation" Margin="0,12,0,0" Foreground="#B42318" TextWrapping="Wrap"/>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0">
            <Button x:Name="Cancel" Content="取消" Width="78" Height="32" Margin="0,0,10,0" IsCancel="True"/>
            <Button x:Name="Save" Content="保存" Width="78" Height="32" IsDefault="True"/>
        </StackPanel>
    </StackPanel>
</Window>
'@
    $dialog = [System.Windows.Markup.XamlReader]::Parse($xaml)
    if ($null -ne $Owner -and $Owner -is [System.Windows.Window]) { $dialog.Owner = $Owner }
    else { $dialog.WindowStartupLocation = 'CenterScreen' }

    $cursorBox = $dialog.FindName('CursorEnabled')
    $apiBox = $dialog.FindName('ApiEnabled')
    $httpBox = $dialog.FindName('AllowInsecureHttp')
    $keyBox = $dialog.FindName('ApiKey')
    $dailyLimitBox = $dialog.FindName('ApiDailyLimitUsd')
    $keyStatus = $dialog.FindName('KeyStatus')
    $clearButton = $dialog.FindName('ClearKey')
    $validation = $dialog.FindName('Validation')
    $cursorBox.IsChecked = [bool]$original.CursorEnabled
    $apiBox.IsChecked = [bool]$original.ApiEnabled
    $httpBox.IsChecked = [bool]$original.AllowInsecureHttp
    if ($null -ne $original.ApiDailyLimitUsd) {
        $dailyLimitBox.Text = ([double]$original.ApiDailyLimitUsd).ToString('0.################', [System.Globalization.CultureInfo]::InvariantCulture)
    }
    if ($original.ApiKeyNeedsReplacement) {
        $keyStatus.Text = '检测到旧 Key，但当前 Windows 用户无法解密；请重新输入后保存。'
    } elseif ($dialogState.ProtectedApiKey) {
        $keyStatus.Text = '已有加密保存的 Key；留空可保留。'
    } else {
        $keyStatus.Text = '尚未设置 Key。'
    }
    $clearButton.IsEnabled = [bool]($dialogState.ProtectedApiKey -or $original.ApiKeyNeedsReplacement)

    $passwordChangedHandler = {
        $clearButton.IsEnabled = ($keyBox.Password.Length -gt 0 -or [bool]$dialogState.ProtectedApiKey)
        $validation.Text = ''
    }
    $keyBox.Add_PasswordChanged($passwordChangedHandler)
    $clearKeyHandler = {
        $dialogState.ProtectedApiKey = ''
        $dialogState.ApiKeyNeedsReplacement = $false
        $keyBox.Clear()
        $apiBox.IsChecked = $false
        $keyStatus.Text = '保存后将清除 Key，并关闭 API 额度。'
        $clearButton.IsEnabled = $false
        $validation.Text = ''
    }
    $clearButton.Add_Click($clearKeyHandler)
    $cancelHandler = { $dialog.DialogResult = $false }
    $dialog.FindName('Cancel').Add_Click($cancelHandler)
    $saveHandler = {
        $next = @{
            CursorEnabled = [bool]$cursorBox.IsChecked
            ApiEnabled = [bool]$apiBox.IsChecked
            AllowInsecureHttp = [bool]$httpBox.IsChecked
            ProtectedApiKey = [string]$dialogState.ProtectedApiKey
            ApiDailyLimitUsd = $null
        }
        try {
            $next.ApiDailyLimitUsd = ConvertTo-SpiritQuotaDailyLimit $dailyLimitBox.Text
        } catch {
            $validation.Text = '请输入非负有限数字，例如 400；留空表示不设置每日上限。'
            [void]$dailyLimitBox.Focus()
            return
        }
        if ($dialogState.ApiKeyNeedsReplacement -and $next.ApiEnabled -and [string]::IsNullOrWhiteSpace($keyBox.Password)) {
            $validation.Text = '旧 Key 无法解密；请重新输入或清除后保存。'
            [void]$keyBox.Focus()
            return
        }
        if ($next.ApiEnabled -and -not $next.AllowInsecureHttp) {
            $validation.Text = '该 API 地址使用 HTTP。请先确认允许明文传输，或关闭 API 额度。'
            return
        }
        if ($next.ApiEnabled -and -not $next.ProtectedApiKey -and [string]::IsNullOrWhiteSpace($keyBox.Password)) {
            $validation.Text = '请填写 API Key 后再启用 API 额度。'
            [void]$keyBox.Focus()
            return
        }
        try {
            if (-not [string]::IsNullOrWhiteSpace($keyBox.Password)) {
                $next.ProtectedApiKey = Protect-SpiritApiKey ($keyBox.Password.Trim())
            }
        } catch {
            $validation.Text = Get-SpiritQuotaSaveErrorText $_
            return
        }
        try {
            Save-SpiritQuotaSettings $StateDir $next
        } catch {
            $validation.Text = Get-SpiritQuotaSaveErrorText $_
            return
        }
        foreach ($name in @('CursorEnabled', 'ApiEnabled', 'AllowInsecureHttp', 'ProtectedApiKey', 'ApiDailyLimitUsd')) {
            if ($next[$name] -ne $original[$name]) { $dialogState.Changed = $true }
        }
        if ($original.ApiKeyNeedsReplacement) { $dialogState.Changed = $true }
        $keyBox.Clear()
        $dialog.DialogResult = $true
    }
    $dialog.FindName('Save').Add_Click($saveHandler)

    try { [void]$dialog.ShowDialog() }
    finally { $keyBox.Clear() }
    return [bool]$dialogState.Changed
}
