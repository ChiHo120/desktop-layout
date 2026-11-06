# 桌面文件夹汇总。只记住拖进来的路径，不移动桌面上的图标。
$ErrorActionPreference = 'Stop'
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($false, 'Local\DesktopFolderHub', [ref]$createdNew)
$owned = $false
try { $owned = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
if (-not $owned) { return }

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

if (-not ('FolderHubNative' -as [type])) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class FolderHubNative {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct SHFILEINFO {
        public IntPtr hIcon;
        public int iIcon;
        public uint dwAttributes;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
        public string szDisplayName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 80)]
        public string szTypeName;
    }
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr SHGetFileInfo(string path, uint attr, ref SHFILEINFO info, uint cb, uint flags);
    [DllImport("user32.dll")]
    public static extern bool DestroyIcon(IntPtr handle);
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    public static extern void SHChangeNotify(uint eventId, uint flags, string item1, IntPtr item2);
}
"@
}

$stateDir = Join-Path $env:LOCALAPPDATA '桌面小灵宠'
if (-not (Test-Path -LiteralPath $stateDir)) { New-Item -ItemType Directory -Force -Path $stateDir | Out-Null }
$statePath = Join-Path $stateDir 'folder-hub.json'
$script:folders = New-Object System.Collections.Generic.List[string]

function Get-HubAnchor {
    $area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    return @{
        Left = [Math]::Max($area.Left + 8, $area.Right - $window.Width - 16)
        Top = $area.Top + 8
    }
}

function Move-HubOnScreen {
    $anchor = Get-HubAnchor
    $window.Left = $anchor.Left
    $window.Top = $anchor.Top
}

function Save-Hub {
    if ($window.Left -lt -200 -or $window.Top -lt -200) { Move-HubOnScreen }
    $payload = @{
        Left = [math]::Round($window.Left, 1)
        Top = [math]::Round($window.Top, 1)
        Width = [math]::Round($window.Width, 1)
        Height = [math]::Round($window.Height, 1)
        Folders = @($script:folders)
    }
    ($payload | ConvertTo-Json) | Set-Content -Path $statePath -Encoding UTF8
}

function Get-FolderIcon {
    param([string]$Path)
    $info = New-Object FolderHubNative+SHFILEINFO
    $size = [Runtime.InteropServices.Marshal]::SizeOf($info)
    [void][FolderHubNative]::SHGetFileInfo($Path, 0x10, [ref]$info, $size, 0x100)
    if ($info.hIcon -eq [IntPtr]::Zero) { return $null }
    $icon = [System.Drawing.Icon]::FromHandle($info.hIcon)
    $bmp = $icon.ToBitmap()
    $stream = New-Object System.IO.MemoryStream
    $bmp.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
    $stream.Position = 0
    $image = New-Object System.Windows.Media.Imaging.BitmapImage
    $image.BeginInit()
    $image.CacheOption = 'OnLoad'
    $image.StreamSource = $stream
    $image.EndInit()
    $image.Freeze()
    $stream.Dispose()
    $bmp.Dispose()
    [void][FolderHubNative]::DestroyIcon($info.hIcon)
    return $image
}

function Resolve-DroppedPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    if (Test-Path -LiteralPath $Path -PathType Container) { return (Resolve-Path -LiteralPath $Path).Path }
    if ($Path -like '*.lnk' -and (Test-Path -LiteralPath $Path)) {
        $shell = New-Object -ComObject WScript.Shell
        $target = $shell.CreateShortcut($Path).TargetPath
        if ($target -and (Test-Path -LiteralPath $target -PathType Container)) {
            return (Resolve-Path -LiteralPath $target).Path
        }
    }
    return $null
}

$window = New-Object System.Windows.Window
$window.Title = '文件夹'
$window.Width = 460
$window.Height = 300
$window.MinWidth = 280
$window.MinHeight = 200
$window.WindowStartupLocation = 'Manual'
$window.WindowStyle = 'None'
$window.AllowsTransparency = $true
$window.Background = [System.Windows.Media.Brushes]::Transparent
$window.ResizeMode = 'CanResize'
$window.ShowInTaskbar = $true
$window.Topmost = $false
$window.FontFamily = 'Microsoft YaHei UI'

$root = New-Object System.Windows.Controls.Border
$root.CornerRadius = 16
$root.Background = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromArgb(235, 244, 241, 238))
$root.BorderBrush = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromArgb(80, 40, 48, 60))
$root.BorderThickness = 1
$root.Padding = New-Object System.Windows.Thickness 12,8,12,12
$root.AllowDrop = $true
$window.Content = $root
$window.AllowDrop = $true

$dock = New-Object System.Windows.Controls.DockPanel
$root.Child = $dock

$titleBar = New-Object System.Windows.Controls.Grid
$titleBar.Height = 32
$titleBar.Background = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromArgb(235, 244, 241, 238))
$titleBar.Cursor = 'SizeAll'
[System.Windows.Controls.DockPanel]::SetDock($titleBar, 'Top')
$title = New-Object System.Windows.Controls.TextBlock
$title.Text = '文件夹'
$title.FontSize = 14
$title.FontWeight = 'Bold'
$title.Foreground = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(28, 34, 44))
$title.VerticalAlignment = 'Center'
$titleBar.Children.Add($title) | Out-Null
$close = New-Object System.Windows.Controls.Button
$close.Content = '×'
$close.Width = 24
$close.Height = 24
$close.HorizontalAlignment = 'Right'
$close.Background = [System.Windows.Media.Brushes]::Transparent
$close.BorderThickness = 0
$close.FontSize = 16
$close.Cursor = 'Hand'
$close.Add_Click({ $window.Close() })
$titleBar.Children.Add($close) | Out-Null
$titleBar.Add_MouseLeftButtonDown({
    $node = $_.OriginalSource -as [System.Windows.DependencyObject]
    while ($node) {
        if ($node -eq $close) { return }
        $node = [System.Windows.Media.VisualTreeHelper]::GetParent($node)
    }
    if ($_.LeftButton -ne 'Pressed') { return }
    try { $window.DragMove() } catch {}
})
$dock.Children.Add($titleBar) | Out-Null

$hint = New-Object System.Windows.Controls.TextBlock
$hint.Text = '把桌面上的文件夹拖到这里。拖进来后，桌面上就不再显示它。'
$hint.Foreground = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(90, 98, 112))
$hint.FontSize = 12
$hint.TextWrapping = 'Wrap'
$hint.Margin = '0,8,0,0'
$hint.HorizontalAlignment = 'Center'
$hint.VerticalAlignment = 'Center'
[System.Windows.Controls.DockPanel]::SetDock($hint, 'Bottom')

$scroll = New-Object System.Windows.Controls.ScrollViewer
$scroll.VerticalScrollBarVisibility = 'Auto'
$scroll.HorizontalScrollBarVisibility = 'Disabled'
$wrap = New-Object System.Windows.Controls.WrapPanel
$scroll.Content = $wrap
$dock.Children.Add($scroll) | Out-Null
$dock.Children.Add($hint) | Out-Null

function Update-Hint {
    $hint.Visibility = $(if ($script:folders.Count -eq 0) { 'Visible' } else { 'Collapsed' })
}

function Add-FolderCard {
    param([string]$Path)
    $card = New-Object System.Windows.Controls.StackPanel
    $card.Width = 96
    $card.Margin = '6,8,6,4'
    $card.Cursor = 'Hand'
    $card.Tag = $Path
    $image = New-Object System.Windows.Controls.Image
    $image.Width = 48
    $image.Height = 48
    $image.HorizontalAlignment = 'Center'
    $image.Source = Get-FolderIcon $Path
    $name = New-Object System.Windows.Controls.TextBlock
    $name.Text = Split-Path $Path -Leaf
    $name.TextAlignment = 'Center'
    $name.TextWrapping = 'Wrap'
    $name.FontSize = 12
    $name.Foreground = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb(28, 34, 44))
    $name.Margin = '0,4,0,0'
    if (-not (Test-Path -LiteralPath $Path)) { $name.Opacity = 0.45 }
    $card.Children.Add($image) | Out-Null
    $card.Children.Add($name) | Out-Null
    $card.ToolTip = $Path
    $card.Add_MouseLeftButtonUp({
        $target = $this.Tag
        if (Test-Path -LiteralPath $target) { Start-Process explorer.exe $target }
    })
    $menu = New-Object System.Windows.Controls.ContextMenu
    $remove = New-Object System.Windows.Controls.MenuItem
    $remove.Header = '从汇总里移出'
    $remove.Add_Click({
        $target = $card.Tag
        [void]$script:folders.Remove($target)
        if (Test-DesktopItem $target) { Set-DesktopIconVisible $target $true }
        [void]$wrap.Children.Remove($card)
        Update-Hint
        Save-Hub
    }.GetNewClosure())
    $menu.Items.Add($remove) | Out-Null
    $card.ContextMenu = $menu
    $wrap.Children.Add($card) | Out-Null
}

function Test-DesktopItem {
    param([string]$Path)
    $parent = Split-Path $Path -Parent
    $desktops = @(
        [Environment]::GetFolderPath('Desktop'),
        [Environment]::GetFolderPath('CommonDesktopDirectory')
    )
    foreach ($desk in $desktops) {
        if ($parent -and $desk -and ($parent.TrimEnd('\') -eq $desk.TrimEnd('\'))) { return $true }
    }
    return $false
}

function Set-DesktopIconVisible {
    param([string]$Path, [bool]$Visible)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return }
    $item = Get-Item -LiteralPath $Path -Force
    if ($Visible) {
        $item.Attributes = $item.Attributes -band (-bnot [System.IO.FileAttributes]::Hidden)
    } else {
        $item.Attributes = $item.Attributes -bor [System.IO.FileAttributes]::Hidden
    }
    $desk = Split-Path $Path -Parent
    [FolderHubNative]::SHChangeNotify(0x1000, 0x1005, $desk, [IntPtr]::Zero)
}

function Add-HubFolder {
    param([string]$Path)
    $resolved = Resolve-DroppedPath $Path
    if (-not $resolved) { return }
    if ($script:folders -contains $resolved) { return }
    $script:folders.Add($resolved)
    Add-FolderCard $resolved
    if (Test-DesktopItem $Path) { Set-DesktopIconVisible $Path $true }
    elseif (Test-DesktopItem $resolved) { Set-DesktopIconVisible $resolved $true }
    Update-Hint
    Save-Hub
}

function Receive-Drop {
    param($Event)
    if (-not $Event.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop)) {
        $Event.Effects = [System.Windows.DragDropEffects]::None
        $Event.Handled = $true
        return
    }
    $allowed = $Event.AllowedEffects
    if ($allowed -band [System.Windows.DragDropEffects]::Link) {
        $Event.Effects = [System.Windows.DragDropEffects]::Link
    } elseif ($allowed -band [System.Windows.DragDropEffects]::Copy) {
        $Event.Effects = [System.Windows.DragDropEffects]::Copy
    } else {
        $Event.Effects = [System.Windows.DragDropEffects]::None
    }
    $Event.Handled = $true
    if ($Event.RoutedEvent.Name -ne 'Drop') { return }
    foreach ($item in @($Event.Data.GetData([System.Windows.DataFormats]::FileDrop))) {
        Add-HubFolder $item
    }
}

$window.Add_DragOver({ Receive-Drop $_ })
$window.Add_Drop({ Receive-Drop $_ })
$root.Add_DragOver({ Receive-Drop $_ })
$root.Add_Drop({ Receive-Drop $_ })
$scroll.Add_DragOver({ Receive-Drop $_ })
$scroll.Add_Drop({ Receive-Drop $_ })

if (Test-Path -LiteralPath $statePath) {
    try {
        $saved = Get-Content -Path $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($saved.Width) { $window.Width = [double]$saved.Width }
        if ($saved.Height) { $window.Height = [double]$saved.Height }
        foreach ($folder in @($saved.Folders)) { Add-HubFolder $folder }
    } catch {}
}
function Add-HubResizeGrip {
    param([int]$Horizontal, [int]$Vertical)
    $grip = New-Object System.Windows.Controls.Border
    $grip.Background = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromArgb(1, 0, 0, 0))
    if ($Horizontal -ne 0 -and $Vertical -ne 0) {
        $grip.Width = 16
        $grip.Height = 16
        $grip.HorizontalAlignment = $(if ($Horizontal -lt 0) { 'Left' } else { 'Right' })
        $grip.VerticalAlignment = $(if ($Vertical -lt 0) { 'Top' } else { 'Bottom' })
        if ($Horizontal -eq $Vertical) { $grip.Cursor = 'SizeNWSE' } else { $grip.Cursor = 'SizeNESW' }
    } elseif ($Horizontal -ne 0) {
        $grip.Width = 8
        $grip.HorizontalAlignment = $(if ($Horizontal -lt 0) { 'Left' } else { 'Right' })
        $grip.VerticalAlignment = 'Stretch'
        $grip.Cursor = 'SizeWE'
    } else {
        $grip.Height = 8
        $grip.VerticalAlignment = $(if ($Vertical -lt 0) { 'Top' } else { 'Bottom' })
        $grip.HorizontalAlignment = 'Stretch'
        $grip.Cursor = 'SizeNS'
    }
    $grip.Tag = @{ H = $Horizontal; V = $Vertical }
    $grip.Add_MouseLeftButtonDown({
        $_.Handled = $true
        $this.CaptureMouse() | Out-Null
        $script:hubResize = @{
            H = $this.Tag.H
            V = $this.Tag.V
            X = [System.Windows.Forms.Cursor]::Position.X
            Y = [System.Windows.Forms.Cursor]::Position.Y
            Left = $window.Left
            Top = $window.Top
            Width = $window.ActualWidth
            Height = $window.ActualHeight
        }
    })
    $grip.Add_MouseMove({
        if (-not $script:hubResize -or -not $this.IsMouseCaptured) { return }
        $scale = 1.0
        $source = [System.Windows.PresentationSource]::FromVisual($window)
        if ($source) { $scale = $source.CompositionTarget.TransformToDevice.M11 }
        if ($scale -lt 0.5) { $scale = 1.0 }
        $drag = $script:hubResize
        $dx = ([System.Windows.Forms.Cursor]::Position.X - $drag.X) / $scale
        $dy = ([System.Windows.Forms.Cursor]::Position.Y - $drag.Y) / $scale
        if ($drag.H -lt 0) {
            $width = [Math]::Max($window.MinWidth, $drag.Width - $dx)
            $window.Width = $width
            $window.Left = $drag.Left + ($drag.Width - $width)
        } elseif ($drag.H -gt 0) {
            $window.Width = [Math]::Max($window.MinWidth, $drag.Width + $dx)
        }
        if ($drag.V -lt 0) {
            $height = [Math]::Max($window.MinHeight, $drag.Height - $dy)
            $window.Height = $height
            $window.Top = $drag.Top + ($drag.Height - $height)
        } elseif ($drag.V -gt 0) {
            $window.Height = [Math]::Max($window.MinHeight, $drag.Height + $dy)
        }
    })
    $grip.Add_MouseLeftButtonUp({
        if ($this.IsMouseCaptured) { $this.ReleaseMouseCapture() }
        $script:hubResize = $null
        Save-Hub
    })
    $shell.Children.Add($grip) | Out-Null
}

$shell = New-Object System.Windows.Controls.Grid
$window.Content = $shell
$shell.Children.Add($root) | Out-Null
foreach ($edge in @(
    @{ H = 0; V = -1 }, @{ H = 0; V = 1 }, @{ H = -1; V = 0 }, @{ H = 1; V = 0 },
    @{ H = -1; V = -1 }, @{ H = 1; V = -1 }, @{ H = -1; V = 1 }, @{ H = 1; V = 1 }
)) {
    Add-HubResizeGrip -Horizontal $edge.H -Vertical $edge.V
}
Move-HubOnScreen
Update-Hint
$window.Add_LocationChanged({ Save-Hub })
$window.Add_SizeChanged({ Save-Hub })
$window.Add_Closed({
    try { $mutex.ReleaseMutex() } catch {}
    try { $mutex.Dispose() } catch {}
})
$null = $window.ShowDialog()
