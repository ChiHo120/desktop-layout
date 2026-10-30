$ErrorActionPreference = 'Stop'
if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    throw 'Run this check with powershell.exe -STA.'
}

# Load only layout code. Do not start sensors, polling, or credential storage.
$source = Join-Path (Split-Path -Parent $PSScriptRoot) 'pet.ps1'
$parseErrors = $null
$tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw 'Pet script has syntax errors.' }
$nativeSource = $ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $node.Value -like '*namespace SpiritNative*'
}, $true) | Select-Object -First 1
if ($null -eq $nativeSource) { throw 'DPI helper source was not found.' }
if (-not ('SpiritNative.Dpi' -as [type])) { Add-Type -TypeDefinition $nativeSource.Value }
try { [void][SpiritNative.Dpi]::SetProcessDpiAwarenessContext([IntPtr](-4)) } catch {}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms
if (-not ('DetailsWindowTest.Native' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace DetailsWindowTest {
    [StructLayout(LayoutKind.Sequential)]
    public struct Rect { public int Left, Top, Right, Bottom; }
    public static class Native {
        [DllImport("user32.dll")]
        public static extern bool GetWindowRect(IntPtr hwnd, out Rect rect);
        [DllImport("user32.dll")]
        public static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int width, int height, uint flags);
    }
}
'@
}

$markup = $ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $node.Value -like '<Window*'
}, $true) | Select-Object -First 1
if ($null -eq $markup) { throw 'Pet window markup was not found.' }
$window = [System.Windows.Markup.XamlReader]::Parse($markup.Value)
foreach ($name in @('Find', 'Initialize-DetailsWindow', 'Update-DetailsPosition', 'Set-Expanded', 'Set-PetScale')) {
    $definition = $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true) | Select-Object -First 1
    if ($null -eq $definition) { throw ('Missing layout function: ' + $name) }
    . ([scriptblock]::Create($definition.Extent.Text))
}
function Save-State {}

function Invoke-LayoutCycle {
    $window.UpdateLayout()
    if ($script:detailsWindow) { $script:detailsWindow.UpdateLayout() }
    $window.Dispatcher.Invoke([System.Windows.Threading.DispatcherPriority]::ContextIdle, [action]{})
}

function Get-TestWindowRect {
    param([System.Windows.Window]$Target)
    $helper = [System.Windows.Interop.WindowInteropHelper]::new($Target)
    $rect = New-Object DetailsWindowTest.Rect
    if (-not [DetailsWindowTest.Native]::GetWindowRect($helper.EnsureHandle(), [ref]$rect)) { throw 'GetWindowRect failed.' }
    return $rect
}

function Assert-PetUnmoved {
    param($Before)
    $after = Get-TestWindowRect $window
    foreach ($edge in @('Left', 'Top', 'Right', 'Bottom')) {
        if ([math]::Abs($after.$edge - $Before.$edge) -gt 1) {
            throw ('Opening or closing details moved the pet: ' + $edge)
        }
    }
}

function Assert-DetailsCorner {
    $petHandle = [System.Windows.Interop.WindowInteropHelper]::new($window).Handle
    $area = [System.Windows.Forms.Screen]::FromHandle($petHandle).WorkingArea
    $detailsHandle = [System.Windows.Interop.WindowInteropHelper]::new($script:detailsWindow).Handle
    $dpi = [SpiritNative.Dpi]::GetDpiForWindow($detailsHandle)
    if ($dpi -lt 96) { $dpi = 96 }
    $margin = 12.0 * $dpi / 96.0
    $rect = Get-TestWindowRect $script:detailsWindow
    if ([math]::Abs($rect.Top - $area.Top - $margin) -gt 3) { throw 'Details are not at the work area top margin.' }
    if ([math]::Abs($area.Right - $rect.Right - $margin) -gt 3) { throw 'Details are not at the work area right margin.' }
    if ($rect.Left -lt ($area.Left - 1) -or $rect.Bottom -gt ($area.Bottom + 1)) { throw 'Details extend beyond the work area.' }
    if (($rect.Right - $rect.Left) -le 0 -or ($rect.Bottom - $rect.Top) -le 0) { throw 'Details window is empty.' }
}

$script:expanded = $false
$script:scale = 0.72
$script:scaleLock = $false
$card = Find 'Card'
$window.Opacity = 0
$window.ShowInTaskbar = $false
$window.ShowActivated = $false
$window.Topmost = $false
$spacer = $null
try {
    Initialize-DetailsWindow
    if ($null -eq $script:detailsWindow) { throw 'Details window was not initialized.' }
    $script:detailsWindow.Opacity = 0
    $script:detailsWindow.ShowInTaskbar = $false
    $script:detailsWindow.ShowActivated = $false
    $window.Show()
    Invoke-LayoutCycle

    $screens = @([System.Windows.Forms.Screen]::PrimaryScreen)
    $negativeScreen = [System.Windows.Forms.Screen]::AllScreens | Where-Object { $_.WorkingArea.Left -lt 0 -or $_.WorkingArea.Top -lt 0 } | Select-Object -First 1
    if ($negativeScreen -and $negativeScreen.DeviceName -ne $screens[0].DeviceName) { $screens += $negativeScreen }
    foreach ($screen in $screens) {
        $petHandle = [System.Windows.Interop.WindowInteropHelper]::new($window).Handle
        if (-not [DetailsWindowTest.Native]::SetWindowPos($petHandle, [IntPtr]::Zero, ($screen.WorkingArea.Left + 60), ($screen.WorkingArea.Top + 60), 0, 0, 0x15)) { throw 'Unable to move the test window.' }
        Invoke-LayoutCycle
        foreach ($scale in @(0.1, 0.72, 1.4)) {
            Set-PetScale $scale
            Invoke-LayoutCycle
            Set-Expanded $false
            Invoke-LayoutCycle
            $before = Get-TestWindowRect $window
            for ($iteration = 0; $iteration -lt 3; $iteration++) {
                Set-Expanded $true
                Invoke-LayoutCycle
                if (-not $script:detailsWindow.IsVisible -or $card.Visibility -ne 'Visible') { throw 'Details did not open.' }
                Assert-DetailsCorner
                Assert-PetUnmoved $before
                $script:detailsWindow.Left += 43
                $script:detailsWindow.Top += 31
                Set-Expanded $false
                Invoke-LayoutCycle
                if ($script:detailsWindow.IsVisible -or $card.Visibility -ne 'Collapsed') { throw 'Details did not close.' }
                Assert-PetUnmoved $before
            }
            Set-Expanded $true
            Invoke-LayoutCycle
            Assert-DetailsCorner
            Assert-PetUnmoved $before
            Write-Output ('DETAILS_CORNER_OK scale={0} negativeOrigin={1}' -f $scale, ($screen.WorkingArea.Left -lt 0 -or $screen.WorkingArea.Top -lt 0))
        }
    }

    $stack = $card.Child -as [System.Windows.Controls.Panel]
    if ($null -eq $stack) { throw 'Details content panel was not found.' }
    $spacer = [System.Windows.Controls.Border]::new()
    $spacer.Height = 5000
    [void]$stack.Children.Add($spacer)
    Update-DetailsPosition
    Invoke-LayoutCycle
    Assert-DetailsCorner
    if ($script:detailsViewport.ScrollableHeight -le 0) { throw 'Tall details must scroll inside the bounded window.' }
    Write-Output 'DETAILS_HEIGHT_BOUND_OK'
} finally {
    if ($spacer -and $spacer.Parent -is [System.Windows.Controls.Panel]) { [void]$spacer.Parent.Children.Remove($spacer) }
    if ($script:detailsWindow) { $script:detailsWindow.Hide() }
    $window.Close()
}
Write-Output 'PET_DETAILS_WINDOW_OK'
