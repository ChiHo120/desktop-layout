param([string]$OutputDirectory = '')

$ErrorActionPreference = 'Stop'
if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    throw 'Run this check with powershell.exe -STA.'
}
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$source = Join-Path (Split-Path -Parent $PSScriptRoot) 'pet.ps1'
$parseErrors = $null
$tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw 'Pet script has syntax errors.' }
$markup = $ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $node.Value -like '<Window*'
}, $true) | Select-Object -First 1
if ($null -eq $markup) { throw 'Pet window markup was not found.' }
$window = [System.Windows.Markup.XamlReader]::Parse($markup.Value)

# Exercise the real UI functions without starting workers or reading credentials.
foreach ($name in @('Find', 'Initialize-DetailsWindow', 'Set-QuotaDisplay', 'Set-CursorQuotaDisplay')) {
    $definition = $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true) | Select-Object -First 1
    if ($null -eq $definition) { throw ('Missing display function: ' + $name) }
    . ([scriptblock]::Create($definition.Extent.Text))
}
$card = Find 'Card'
if ($card.Visibility -ne 'Collapsed') { throw 'Details must be collapsed on launch.' }
Initialize-DetailsWindow

$quotaControls = @(
    'CursorAutoQuotaBar', 'CursorAutoQuotaVal',
    'CursorAdvancedQuotaBar', 'CursorAdvancedQuotaVal',
    'CursorGrokQuotaBar', 'CursorGrokQuotaVal', 'CursorQuotaHint',
    'TokenQuotaBar', 'TokenQuotaVal', 'TokenQuotaHint'
)
$headControls = @('QuotaHeadBadge', 'CursorAutoBadge', 'CursorAutoHeadVal', 'CursorAutoHeadBar', 'TokenQuotaBadge', 'TokenQuotaHeadVal', 'TokenQuotaHeadBar', 'PetArt')
$controlMap = @{}
foreach ($name in ($quotaControls + $headControls)) {
    $controlMap[$name] = $window.FindName($name)
    if ($null -eq $controlMap[$name]) { throw ('Missing quota control: ' + $name) }
}
$content = $window.Content
$window.Content = $null
$renderRoot = New-Object System.Windows.Controls.Border
$renderRoot.Background = [System.Windows.Media.Brushes]::Transparent
$renderRoot.Child = $content
$detailsContent = $detailsWindow.Content
$detailsWindow.Content = $null
$detailsRenderRoot = New-Object System.Windows.Controls.Border
$detailsRenderRoot.Background = [System.Windows.Media.Brushes]::Transparent
$detailsRenderRoot.Child = $detailsContent

function Update-TestLayout {
    $renderRoot.Measure([System.Windows.Size]::new(1600, 1600))
    $script:width = [math]::Ceiling($renderRoot.DesiredSize.Width)
    $script:height = [math]::Ceiling($renderRoot.DesiredSize.Height)
    if ($width -le 0 -or $height -le 0 -or $width -gt 1600 -or $height -gt 1600) {
        throw ('Unexpected pet window size: {0}x{1}' -f $width, $height)
    }
    $renderRoot.Arrange([System.Windows.Rect]::new(0, 0, $width, $height))
    $renderRoot.UpdateLayout()
    $detailsRenderRoot.Measure([System.Windows.Size]::new(1600, 1600))
    $script:detailsWidth = [math]::Ceiling($detailsRenderRoot.DesiredSize.Width)
    $script:detailsHeight = [math]::Ceiling($detailsRenderRoot.DesiredSize.Height)
    $detailsRenderRoot.Arrange([System.Windows.Rect]::new(0, 0, $detailsWidth, $detailsHeight))
    $detailsRenderRoot.UpdateLayout()
}

function Get-ControlBounds {
    param([string]$Name)
    $control = $controlMap[$Name]
    $ancestor = $renderRoot
    if ($card.IsAncestorOf($control)) { $ancestor = $detailsRenderRoot }
    return $control.TransformToAncestor($ancestor).TransformBounds([System.Windows.Rect]::new($control.RenderSize))
}

function Test-ControlShown {
    param([string]$Name)
    $node = $controlMap[$Name]
    while ($null -ne $node) {
        if ($node -is [System.Windows.UIElement] -and $node.Visibility -ne 'Visible') { return $false }
        $node = [System.Windows.Media.VisualTreeHelper]::GetParent($node)
    }
    return $true
}

function Assert-ControlsFit {
    param([string[]]$Names)
    foreach ($name in $Names) {
        $bounds = Get-ControlBounds $name
        $limitWidth = $width
        $limitHeight = $height
        if ($card.IsAncestorOf($controlMap[$name])) { $limitWidth = $detailsWidth; $limitHeight = $detailsHeight }
        if (-not (Test-ControlShown $name) -or $bounds.Width -le 0 -or $bounds.Height -le 0 -or $bounds.Left -lt -0.5 -or $bounds.Top -lt -0.5 -or $bounds.Right -gt ($limitWidth + 0.5) -or $bounds.Bottom -gt ($limitHeight + 0.5)) {
            throw ('Quota control is outside its window: {0}, window={1}x{2}, bounds={3},{4},{5},{6}' -f $name, $limitWidth, $limitHeight, $bounds.Left, $bounds.Top, $bounds.Right, $bounds.Bottom)
        }
    }
}

function Assert-Equal {
    param($Actual, $Expected, [string]$Label)
    if ($Actual -ne $Expected) { throw ('{0}: expected {1}, got {2}' -f $Label, $Expected, $Actual) }
}

function Assert-HeadReading {
    param([string]$Prefix, [string]$Text, [double]$Percent, [string]$Color)
    $headValue = $controlMap[$Prefix + 'HeadVal']
    $headBar = $controlMap[$Prefix + 'HeadBar']
    Assert-Equal $headValue.Text $Text ($Prefix + ' text')
    Assert-Equal $headValue.Foreground.Color.ToString() $Color ($Prefix + ' color')
    $expectedWidth = $headBar.Parent.ActualWidth * ($Percent / 100.0)
    if ([math]::Abs($headBar.Width - $expectedWidth) -gt 0.01) { throw ($Prefix + ' progress is incorrect.') }
}

function Save-Preview {
    param([string]$Name)
    if (-not $OutputDirectory) { return }
    $imagePath = Join-Path $OutputDirectory ($Name + '.png')
    $previewWidth = $width
    $previewHeight = $height
    if ($card.Visibility -eq 'Visible') {
        $previewWidth += $detailsWidth
        $previewHeight = [math]::Max($height, $detailsHeight)
    }
    $visual = New-Object System.Windows.Media.DrawingVisual
    $drawing = $visual.RenderOpen()
    try {
        $drawing.DrawRectangle([System.Windows.Media.VisualBrush]::new($renderRoot), $null, [System.Windows.Rect]::new(0, ($previewHeight - $height) / 2, $width, $height))
        if ($card.Visibility -eq 'Visible') {
            $drawing.DrawRectangle([System.Windows.Media.VisualBrush]::new($detailsRenderRoot), $null, [System.Windows.Rect]::new($width, 0, $detailsWidth, $detailsHeight))
        }
    } finally { $drawing.Close() }
    $bitmap = [System.Windows.Media.Imaging.RenderTargetBitmap]::new([int]$previewWidth * 2, [int]$previewHeight * 2, 192, 192, [System.Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($visual)
    $encoder = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream = [System.IO.File]::Open($imagePath, [System.IO.FileMode]::CreateNew)
    try { $encoder.Save($stream) } finally { $stream.Dispose() }
    Write-Output $imagePath
}

$stamp = [datetime]'2026-10-27T12:00:00'
$cursor = @{
    State = 'ok'; Text = 'TOTAL-99'; Detail = 'COMBINED-DETAIL'; RemainingPercent = 99; UpdatedAt = $stamp
    Buckets = @{
        Auto = @{ State = 'ok'; Text = 'AUTO-DETAIL'; Detail = 'AUTO-CYCLE'; RemainingPercent = 78.43; UpdatedAt = $stamp }
        Advanced = @{ State = 'ok'; Text = 'ADVANCED-11'; RemainingPercent = 11 }
        Grok = @{ State = 'ok'; Text = 'GROK-22'; RemainingPercent = 22 }
    }
}
# Avoid non-ASCII literals so this test also works without a UTF-8 BOM on PS5.1.
$dailyPrefix = -join @([char]0x4eca, [char]0x65e5, [char]0x5269, [char]0x4f59, ' ')
$cachedPrefix = -join @([char]0x7f13, [char]0x5b58, ' ')
$token = @{ State = 'ok'; Text = ($dailyPrefix + '$324.56'); Detail = 'DAILY-ONLY'; RemainingPercent = 81.1; UpdatedAt = $stamp }

Update-TestLayout
Set-CursorQuotaDisplay $cursor
Set-QuotaDisplay 'Token' $token '#A78BFA'
Assert-HeadReading 'CursorAuto' '78.43%' 78.43 '#FF67E8F9'
Assert-HeadReading 'TokenQuota' '$324.56' 81.1 '#FFA78BFA'
if ($controlMap.CursorAutoBadge.ToolTip -match 'COMBINED|ADVANCED|GROK') { throw 'Auto badge leaks other quota details.' }
if ($controlMap.TokenQuotaBadge.ToolTip -notmatch 'DAILY-ONLY|12:00:00') { throw 'Daily badge must include detail and update time.' }

foreach ($percent in @(0, 100, 20, 8, -10, 120)) {
    $cursor.Buckets.Auto.RemainingPercent = $percent
    $token.RemainingPercent = $percent
    Set-CursorQuotaDisplay $cursor
    Set-QuotaDisplay 'Token' $token '#A78BFA'
    $fill = [math]::Max([double]0, [math]::Min([double]100, [double]$percent))
    $autoColor = '#FF67E8F9'
    $apiColor = '#FFA78BFA'
    if ($fill -le 10) { $autoColor = $apiColor = '#FFFB7185' }
    elseif ($fill -le 25) { $autoColor = $apiColor = '#FFFBBF24' }
    Assert-HeadReading 'CursorAuto' ($fill.ToString('0.##', [System.Globalization.CultureInfo]::InvariantCulture) + '%') $fill $autoColor
    Assert-HeadReading 'TokenQuota' '$324.56' $fill $apiColor
}

$cursor.Buckets.Auto.RemainingPercent = 78.43
$token.RemainingPercent = 81.1
$cursor.State = 'stale'
$token.State = 'stale'
Set-CursorQuotaDisplay $cursor
Set-QuotaDisplay 'Token' $token '#A78BFA'
Assert-HeadReading 'CursorAuto' ($cachedPrefix + '78.43%') 78.43 '#FFFBBF24'
Assert-HeadReading 'TokenQuota' ($cachedPrefix + '$324.56') 81.1 '#FFFBBF24'
$cursor.State = 'ok'
$cursor.Buckets.Auto.State = 'stale'
Set-CursorQuotaDisplay $cursor
Assert-HeadReading 'CursorAuto' ($cachedPrefix + '78.43%') 78.43 '#FFFBBF24'

foreach ($state in @('quota-exhausted', 'window-exhausted', 'auth', 'disabled', 'loading', 'unsupported', 'insecure', 'error')) {
    $cursor.Buckets.Auto.State = $state
    $cursor.Buckets.Auto.Text = 'STATE-ONLY'
    $cursor.Buckets.Auto.RemainingPercent = $null
    $token.State = $state
    $token.Text = 'STATE-ONLY'
    $token.RemainingPercent = $null
    $autoText = $apiText = 'STATE-ONLY'
    $color = '#FF8EA0B8'
    if ($state -in @('quota-exhausted', 'window-exhausted')) {
        $cursor.Buckets.Auto.RemainingPercent = 0
        $token.RemainingPercent = 0
        $autoText = '0%'
        $apiText = '$0.00'
        $color = '#FFFB7185'
    }
    Set-CursorQuotaDisplay $cursor
    Set-QuotaDisplay 'Token' $token '#A78BFA'
    Assert-HeadReading 'CursorAuto' $autoText 0 $color
    Assert-HeadReading 'TokenQuota' $apiText 0 $color
}
$cursor.Buckets.Remove('Auto')
Set-CursorQuotaDisplay $cursor
if ($controlMap.CursorAutoHeadVal.Text -match '99|11|22|%') { throw 'Missing Auto must not use total, advanced or Grok.' }
$cursor.Buckets.Auto = @{ State = 'ok'; Text = 'AUTO-DETAIL'; Detail = 'AUTO-CYCLE'; RemainingPercent = 78.43; UpdatedAt = $stamp }
$token.State = 'ok'
$token.Text = $dailyPrefix + '$324.56'
$token.RemainingPercent = 81.1

foreach ($scale in @(0.1, 0.72, 1.4)) {
    (Find 'RootScale').ScaleX = $scale
    (Find 'RootScale').ScaleY = $scale
    $detailsScale.ScaleX = $scale
    $detailsScale.ScaleY = $scale
    foreach ($show in @($false, $true, $false)) {
        # Positioning and the real Show/Hide path are covered in test-pet-details-window.ps1.
        $card.Visibility = 'Collapsed'
        if ($show) { $card.Visibility = 'Visible' }
        Update-TestLayout
        Set-CursorQuotaDisplay $cursor
        Set-QuotaDisplay 'Token' $token '#A78BFA'
        Update-TestLayout
        Assert-ControlsFit $headControls
        $badgeBounds = Get-ControlBounds 'QuotaHeadBadge'
        $artBounds = Get-ControlBounds 'PetArt'
        if ($badgeBounds.Bottom -gt $artBounds.Top) { throw 'Head badge overlaps the pet artwork.' }
        if ((Get-ControlBounds 'CursorAutoHeadBar').Bottom -gt (Get-ControlBounds 'TokenQuotaHeadVal').Top) { throw 'Head quota rows overlap.' }
        foreach ($name in $headControls | Where-Object { $_ -ne 'PetArt' -and $_ -ne 'QuotaHeadBadge' }) {
            $bounds = Get-ControlBounds $name
            if ($bounds.Top -lt ($badgeBounds.Top - 0.5) -or $bounds.Bottom -gt ($badgeBounds.Bottom + 0.5)) { throw ('Badge content clipped: ' + $name) }
        }
        if ($show) {
            Assert-ControlsFit $quotaControls
            $lastBottom = 0.0
            foreach ($name in @('CursorAutoQuotaVal', 'CursorAdvancedQuotaVal', 'CursorGrokQuotaVal', 'CursorQuotaHint', 'TokenQuotaVal', 'TokenQuotaHint')) {
                $bounds = Get-ControlBounds $name
                if ($bounds.Top -lt $lastBottom) { throw ('Quota rows overlap at: ' + $name) }
                $lastBottom = $bounds.Bottom
            }
        } else {
            foreach ($name in $quotaControls) {
                if (Test-ControlShown $name) { throw ('Other quotas must be click-to-open: ' + $name) }
            }
            if ($width -gt [math]::Ceiling(186 * $scale) + 1) { throw 'Collapsed card still occupies window space.' }
        }
        if ($width -gt [math]::Ceiling(186 * $scale) + 1) { throw 'Opening details must not enlarge or move the pet window.' }
        Write-Output ('PET_QUOTA_LAYOUT_OK scale={0} expanded={1} pet={2}x{3} details={4}x{5}' -f $scale, $show, $width, $height, $detailsWidth, $detailsHeight)
        if ($scale -eq 0.72) {
            $previewName = 'pet-compact'
            if ($show) { $previewName = 'pet-expanded' }
            if (-not $script:previewSaved) { $script:previewSaved = @{} }
            if (-not $script:previewSaved[$previewName]) { Save-Preview $previewName; $script:previewSaved[$previewName] = $true }
        }
    }
}
Write-Output 'PET_QUOTA_HEAD_READINGS_OK'
