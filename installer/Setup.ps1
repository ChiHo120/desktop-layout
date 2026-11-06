# Installs the pet and the Rainmeter taskbar onto this computer.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$payloadPet = Join-Path $PSScriptRoot 'payload\pet'
$payloadTasks = Join-Path $PSScriptRoot 'payload\tasks'
if (-not (Test-Path -LiteralPath $payloadPet) -or -not (Test-Path -LiteralPath $payloadTasks)) {
    [System.Windows.Forms.MessageBox]::Show('安装包不完整，缺少 payload 文件夹。请使用打好的「桌面布局安装包」。', '安装桌面布局')
    return
}

$computer = Get-CimInstance Win32_ComputerSystem
$maker = [string]$computer.Manufacturer
$model = [string]$computer.Model
$machineKey = ('{0}|{1}' -f $maker.Trim(), $model.Trim())
$drive = if (Test-Path 'D:\') { 'D:\' } else { 'C:\' }

$profiles = @{
    'LENOVO|21RUA0B8CD' = @{
        Pet   = 'c:\lizhihao2\桌面\cursor项目记忆\桌面小灵宠'
        Tasks = 'D:\Tree_tasks'
        Qq    = 'D:\qq_music\QQMusic\QQMusic.exe'
    }
}
$savedProfiles = Join-Path $env:LOCALAPPDATA '桌面布局\machines.json'
if (Test-Path -LiteralPath $savedProfiles) {
    try {
        $extra = Get-Content -LiteralPath $savedProfiles -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($prop in $extra.PSObject.Properties) { $profiles[$prop.Name] = $prop.Value }
    } catch {}
}

function Find-QQMusic {
    $candidates = @(
        'D:\qq_music\QQMusic\QQMusic.exe',
        (Join-Path $env:ProgramFiles 'Tencent\QQMusic\QQMusic.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Tencent\QQMusic\QQMusic.exe')
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
    }
    $menus = @(
        "$env:ProgramData\Microsoft\Windows\Start Menu\Programs",
        "$env:APPDATA\Microsoft\Windows\Start Menu\Programs"
    )
    $shell = New-Object -ComObject WScript.Shell
    foreach ($menu in $menus) {
        if (-not (Test-Path -LiteralPath $menu)) { continue }
        $links = Get-ChildItem -LiteralPath $menu -Filter '*.lnk' -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match 'QQ音乐|QQMusic' } |
            Select-Object -First 4
        foreach ($link in $links) {
            $target = $shell.CreateShortcut($link.FullName).TargetPath
            if ($target -and (Test-Path -LiteralPath $target) -and $target -like '*QQMusic.exe') { return $target }
        }
    }
    return ''
}

$known = $profiles[$machineKey]
$petDefault = Join-Path $drive '桌面小灵宠'
$tasksDefault = Join-Path $drive 'Tree_tasks'
$qqDefault = Find-QQMusic
if ($known) {
    if ($known.Pet) { $petDefault = [string]$known.Pet }
    if ($known.Tasks) { $tasksDefault = [string]$known.Tasks }
    if ($known.Qq) { $qqDefault = [string]$known.Qq }
}

function New-BrowseBox {
    param($Label, $Initial, [switch]$File)
    $row = New-Object System.Windows.Controls.DockPanel
    $row.Margin = '0,0,0,10'
    $button = New-Object System.Windows.Controls.Button
    $button.Content = '浏览'
    $button.Width = 72
    $button.Margin = '8,0,0,0'
    [System.Windows.Controls.DockPanel]::SetDock($button, 'Right')
    $box = New-Object System.Windows.Controls.TextBox
    $box.Text = $Initial
    $box.Height = 28
    $box.VerticalContentAlignment = 'Center'
    $button.Add_Click({
        if ($File) {
            $dialog = New-Object System.Windows.Forms.OpenFileDialog
            $dialog.Filter = 'QQ音乐|QQMusic.exe|程序|*.exe'
            $dialog.Title = $Label
            if ($dialog.ShowDialog() -eq 'OK') { $box.Text = $dialog.FileName }
        } else {
            $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
            $dialog.Description = $Label
            $dialog.ShowNewFolderButton = $true
            if ($box.Text -and (Test-Path -LiteralPath $box.Text)) { $dialog.SelectedPath = $box.Text }
            if ($dialog.ShowDialog() -eq 'OK') { $box.Text = $dialog.SelectedPath }
        }
    }.GetNewClosure())
    $row.Children.Add($button) | Out-Null
    $row.Children.Add($box) | Out-Null
    return @{ Row = $row; Box = $box }
}

function Update-InstallText {
    param([string]$Path, [hashtable]$Map)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 2) { return }
    $encoding = $null
    $text = $null
    if ($bytes[0] -eq 255 -and $bytes[1] -eq 254) {
        $encoding = New-Object System.Text.UnicodeEncoding $false, $true
        $text = $encoding.GetString($bytes)
    } elseif ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) {
        $encoding = New-Object System.Text.UTF8Encoding $true
        $text = $encoding.GetString($bytes)
    } else {
        $encoding = New-Object System.Text.UTF8Encoding $false
        $text = $encoding.GetString($bytes)
    }
    $updated = $text
    foreach ($key in $Map.Keys) { $updated = $updated.Replace($key, $Map[$key]) }
    if ($updated -ne $text) { [System.IO.File]::WriteAllText($Path, $updated, $encoding) }
}

$window = New-Object System.Windows.Window
$window.Title = '安装桌面布局'
$window.Width = 640
$window.Height = 460
$window.WindowStartupLocation = 'CenterScreen'
$window.ResizeMode = 'NoResize'
$window.FontFamily = 'Microsoft YaHei UI'

$panel = New-Object System.Windows.Controls.StackPanel
$panel.Margin = '22'
$window.Content = $panel

$title = New-Object System.Windows.Controls.TextBlock
$title.Text = '安装小灵和任务栏'
$title.FontSize = 22
$title.FontWeight = 'Bold'
$title.Margin = '0,0,0,8'
$panel.Children.Add($title) | Out-Null

$info = New-Object System.Windows.Controls.TextBlock
$info.Text = "已识别这台电脑：$maker  $model`n位置可以改。小灵和任务栏是两个文件夹，安装时会按你选的位置写好路径。"
$info.TextWrapping = 'Wrap'
$info.Margin = '0,0,0,16'
$info.Foreground = [System.Windows.Media.Brushes]::DimGray
$panel.Children.Add($info) | Out-Null

function Add-Label([string]$Text) {
    $label = New-Object System.Windows.Controls.TextBlock
    $label.Text = $Text
    $label.Margin = '0,0,0,4'
    $panel.Children.Add($label) | Out-Null
}
Add-Label '小灵文件夹'
$petPick = New-BrowseBox '选择小灵文件夹' $petDefault
$panel.Children.Add($petPick.Row) | Out-Null
Add-Label '任务栏文件夹'
$tasksPick = New-BrowseBox '选择任务栏文件夹' $tasksDefault
$panel.Children.Add($tasksPick.Row) | Out-Null
Add-Label 'QQ 音乐程序（找不到就留空，歌名和声波以后再接）'
$qqPick = New-BrowseBox '选择 QQMusic.exe' $qqDefault -File
$panel.Children.Add($qqPick.Row) | Out-Null

$regen = New-Object System.Windows.Controls.CheckBox
$regen.Content = '按这台电脑的屏幕和已安装软件重新生成任务栏图标'
$regen.IsChecked = $true
$regen.Margin = '0,4,0,8'
$panel.Children.Add($regen) | Out-Null

$startNow = New-Object System.Windows.Controls.CheckBox
$startNow.Content = '安装完成后立即打开'
$startNow.IsChecked = $true
$startNow.Margin = '0,0,0,12'
$panel.Children.Add($startNow) | Out-Null

$status = New-Object System.Windows.Controls.TextBlock
$status.TextWrapping = 'Wrap'
$status.MinHeight = 36
$status.Margin = '0,0,0,8'
$panel.Children.Add($status) | Out-Null

$install = New-Object System.Windows.Controls.Button
$install.Content = '安装'
$install.Height = 36
$install.FontSize = 15
$panel.Children.Add($install) | Out-Null

$install.Add_Click({
    $install.IsEnabled = $false
    try {
        $petDir = $petPick.Box.Text.Trim()
        $tasksDir = $tasksPick.Box.Text.Trim()
        $qqPath = $qqPick.Box.Text.Trim()
        if (-not $petDir -or -not $tasksDir) { throw '请选择小灵文件夹和任务栏文件夹。' }
        if ($petDir.TrimEnd('\') -eq $tasksDir.TrimEnd('\')) { throw '两个文件夹不能是同一个位置。' }
        $status.Text = '正在复制文件...'
        $window.Dispatcher.Invoke([Action]{}, 'Background')
        New-Item -ItemType Directory -Force -Path $petDir, $tasksDir | Out-Null
        $petCopy = robocopy $payloadPet $petDir /E /NFL /NDL /NJH /NJS /nc /ns /np
        if ($LASTEXITCODE -ge 8) { throw '复制小灵文件失败。' }
        $tasksCopy = robocopy $payloadTasks $tasksDir /E /NFL /NDL /NJH /NJS /nc /ns /np
        if ($LASTEXITCODE -ge 8) { throw '复制任务栏文件失败。' }

        $status.Text = '正在按这台电脑改路径...'
        $tasksForward = $tasksDir.Replace('\', '/').TrimEnd('/')
        $map = @{
            'D:/Tree_tasks' = $tasksForward
            'D:\Tree_tasks' = $tasksDir.TrimEnd('\')
        }
        if ($qqPath) {
            $map['D:\qq_music\QQMusic\QQMusic.exe'] = $qqPath
            $map['D:/qq_music/QQMusic/QQMusic.exe'] = $qqPath.Replace('\', '/')
        }
        $extensions = @('.ps1', '.ini', '.json', '.bat', '.lua', '.xml', '.config', '.txt', '.cs')
        Get-ChildItem -LiteralPath $petDir, $tasksDir -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $extensions -contains $_.Extension.ToLower() } |
            ForEach-Object { Update-InstallText $_.FullName $map }

        $installInfo = @{
            Model = $machineKey
            Pet   = $petDir
            Tasks = $tasksDir
            Qq    = $qqPath
        }
        ($installInfo | ConvertTo-Json) | Set-Content -LiteralPath (Join-Path $tasksDir 'install.json') -Encoding UTF8
        $profileDir = Split-Path $savedProfiles -Parent
        New-Item -ItemType Directory -Force -Path $profileDir | Out-Null
        $profiles[$machineKey] = @{ Pet = $petDir; Tasks = $tasksDir; Qq = $qqPath }
        ($profiles | ConvertTo-Json) | Set-Content -LiteralPath $savedProfiles -Encoding UTF8

        if ($regen.IsChecked) {
            $status.Text = '正在按这台电脑生成任务栏...'
            $redesign = Join-Path $tasksDir 'redesign-docks.ps1'
            if (Test-Path -LiteralPath $redesign) {
                & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $redesign -NoLaunch
            }
        }

        $launcher = Join-Path $tasksDir '启动桌面布局.ps1'
        $startup = [Environment]::GetFolderPath('Startup')
        $shell = New-Object -ComObject WScript.Shell
        $link = $shell.CreateShortcut((Join-Path $startup '桌面布局.lnk'))
        $link.TargetPath = (Get-Command powershell.exe).Source
        $link.Arguments = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $launcher
        $link.WorkingDirectory = $tasksDir
        $link.WindowStyle = 7
        $link.Description = '小灵和任务栏'
        $link.Save()

        if ($startNow.IsChecked -and (Test-Path -LiteralPath $launcher)) {
            Start-Process powershell.exe -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',$launcher -WorkingDirectory $tasksDir -WindowStyle Hidden
        }
        $status.Text = '安装完成。开机后会自动打开。'
        [System.Windows.Forms.MessageBox]::Show("安装完成。`n小灵：$petDir`n任务栏：$tasksDir", '安装桌面布局')
    } catch {
        $status.Text = $_.Exception.Message
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '安装没有完成')
    } finally {
        $install.IsEnabled = $true
    }
})

$null = $window.ShowDialog()
