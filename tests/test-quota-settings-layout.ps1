param([string]$OutputPath = '')

$ErrorActionPreference = 'Stop'
if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    throw 'Run this check with powershell.exe -STA.'
}
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

# Parse only the dialog markup: do not read settings, invoke handlers, or show a window.
$source = Join-Path (Split-Path -Parent $PSScriptRoot) 'quota-settings.ps1'
$parseErrors = $null
$tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw 'Settings script has syntax errors.' }
$markup = $ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $node.Value -like '<Window*'
}, $true) | Select-Object -First 1
if ($null -eq $markup) { throw 'Settings window markup was not found.' }
$dialog = [System.Windows.Markup.XamlReader]::Parse($markup.Value)
$controls = @{}
foreach ($name in @('CursorEnabled', 'ApiEnabled', 'AllowInsecureHttp', 'ApiDailyLimitUsd', 'ApiKey', 'KeyStatus', 'ClearKey', 'Validation', 'Save', 'Cancel')) {
    $control = $dialog.FindName($name)
    if ($null -eq $control) { throw ('Missing settings control: ' + $name) }
    $controls[$name] = $control
}

# Reproduce the unconfigured state without loading a real credential or enabling HTTP.
$controls.CursorEnabled.IsChecked = $true
$controls.ApiEnabled.IsChecked = $false
$controls.KeyStatus.Text = '尚未设置 Key。'
$controls.ClearKey.IsEnabled = $false
if ($controls.ApiKey.Password.Length -ne 0 -or $controls.AllowInsecureHttp.IsChecked -eq $true -or $controls.ApiDailyLimitUsd.Text.Length -ne 0) {
    throw 'The preview must have no credential and HTTP permission must remain off.'
}

$content = $dialog.Content
$dialog.Content = $null
$renderRoot = New-Object System.Windows.Controls.Border
$renderRoot.Background = $dialog.Background
$renderRoot.Child = $content
# Reserve 16 DIPs for the normal window frame when checking the 520-DIP dialog.
$clientWidth = [double]$dialog.Width - 16.0
$renderRoot.Measure([System.Windows.Size]::new($clientWidth, [double]::PositiveInfinity))
$clientHeight = [math]::Ceiling($renderRoot.DesiredSize.Height)
if ($clientHeight -le 0 -or $clientHeight -gt 900) { throw 'Unexpected settings dialog height.' }
$renderRoot.Arrange([System.Windows.Rect]::new(0, 0, $clientWidth, $clientHeight))
$renderRoot.UpdateLayout()
foreach ($name in $controls.Keys) {
    $control = $controls[$name]
    $bounds = $control.TransformToAncestor($renderRoot).TransformBounds([System.Windows.Rect]::new($control.RenderSize))
    if ($bounds.Left -lt 0 -or $bounds.Top -lt 0 -or $bounds.Right -gt ($clientWidth + 0.5) -or $bounds.Bottom -gt ($clientHeight + 0.5)) {
        throw ('Settings control is outside the dialog: ' + $name)
    }
}

if (-not $OutputPath) {
    $OutputPath = Join-Path ([System.IO.Path]::GetTempPath()) ('spirit-quota-settings-layout-' + [guid]::NewGuid().ToString('N') + '.png')
}
$OutputPath = [System.IO.Path]::GetFullPath($OutputPath)
$bitmap = [System.Windows.Media.Imaging.RenderTargetBitmap]::new([int]$clientWidth, [int]$clientHeight, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
$bitmap.Render($renderRoot)
$encoder = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
$encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
$stream = [System.IO.File]::Open($OutputPath, [System.IO.FileMode]::CreateNew)
try { $encoder.Save($stream) }
finally { $stream.Dispose() }
Write-Output ('LAYOUT_OK {0}x{1}' -f [int]$clientWidth, [int]$clientHeight)
Write-Output $OutputPath
