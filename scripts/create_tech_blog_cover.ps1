$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Drawing

$width = 1600
$height = 900
$out = Resolve-Path '.'
$outputPath = Join-Path $out 'docs\marketing\softerplease-tech-blog-cover.png'
$logoPath = Join-Path $out 'mobile\flutter_app\assets\branding\softerplease-logo.png'

$bitmap = New-Object System.Drawing.Bitmap($width, $height)
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
$graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit

function ColorFromHex([string]$hex) {
  $hex = $hex.TrimStart('#')
  return [System.Drawing.Color]::FromArgb(
    [Convert]::ToInt32($hex.Substring(0, 2), 16),
    [Convert]::ToInt32($hex.Substring(2, 2), 16),
    [Convert]::ToInt32($hex.Substring(4, 2), 16)
  )
}

function Brush([string]$hex) {
  return New-Object System.Drawing.SolidBrush((ColorFromHex $hex))
}

function Font([float]$size, [System.Drawing.FontStyle]$style = [System.Drawing.FontStyle]::Regular) {
  return New-Object System.Drawing.Font('Microsoft YaHei UI', $size, $style, [System.Drawing.GraphicsUnit]::Pixel)
}

function RoundedRect([System.Drawing.Graphics]$g, [System.Drawing.RectangleF]$rect, [float]$radius, [System.Drawing.Brush]$brush) {
  $path = New-Object System.Drawing.Drawing2D.GraphicsPath
  $diameter = $radius * 2
  $path.AddArc($rect.X, $rect.Y, $diameter, $diameter, 180, 90)
  $path.AddArc($rect.Right - $diameter, $rect.Y, $diameter, $diameter, 270, 90)
  $path.AddArc($rect.Right - $diameter, $rect.Bottom - $diameter, $diameter, $diameter, 0, 90)
  $path.AddArc($rect.X, $rect.Bottom - $diameter, $diameter, $diameter, 90, 90)
  $path.CloseFigure()
  $g.FillPath($brush, $path)
  $path.Dispose()
}

$bg = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
  (New-Object System.Drawing.Point 0, 0),
  (New-Object System.Drawing.Point $width, $height),
  (ColorFromHex '#07120D'),
  (ColorFromHex '#10271B')
)
$graphics.FillRectangle($bg, 0, 0, $width, $height)
$bg.Dispose()

# Soft brand color fields.
$greenGlow = New-Object System.Drawing.Drawing2D.GraphicsPath
$greenGlow.AddEllipse(-220, 80, 780, 760)
$graphics.FillPath((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(46, 39, 163, 101))), $greenGlow)
$greenGlow.Dispose()

$orangeGlow = New-Object System.Drawing.Drawing2D.GraphicsPath
$orangeGlow.AddEllipse(1090, 80, 720, 720)
$graphics.FillPath((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(44, 248, 118, 76))), $orangeGlow)
$orangeGlow.Dispose()

# Technical network lines, intentionally restrained.
$linePen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(58, 150, 207, 167), 2)
$nodeBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(120, 236, 255, 241))
$points = @(
  @(1020, 185), @(1180, 250), @(1350, 190), @(1430, 355), @(1250, 430), @(1110, 350),
  @(910, 610), @(1085, 690), @(1270, 610), @(1390, 720)
)
for ($i = 0; $i -lt $points.Count - 1; $i++) {
  $a = $points[$i]
  $b = $points[$i + 1]
  $graphics.DrawLine($linePen, $a[0], $a[1], $b[0], $b[1])
}
foreach ($p in $points) {
  $graphics.FillEllipse($nodeBrush, $p[0] - 5, $p[1] - 5, 10, 10)
}
$linePen.Dispose()
$nodeBrush.Dispose()

# Logo card.
$logoCardBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(228, 8, 24, 16))
RoundedRect $graphics (New-Object System.Drawing.RectangleF 84, 78, 320, 320) 38 $logoCardBrush
$logoCardBrush.Dispose()

$logo = [System.Drawing.Image]::FromFile($logoPath)
$graphics.DrawImage($logo, 124, 118, 240, 240)
$logo.Dispose()

$tagBrush = Brush '#CDEBDD'
$tagFont = Font 28 ([System.Drawing.FontStyle]::Bold)
$graphics.DrawString('SofterPlease', $tagFont, $tagBrush, 440, 92)
$tagFont.Dispose()
$tagBrush.Dispose()

$subBrush = Brush '#89A897'
$subFont = Font 25
$graphics.DrawString('家庭沟通 AI 语音助手', $subFont, $subBrush, 440, 134)
$subFont.Dispose()
$subBrush.Dispose()

# Main title.
$titleBrush = Brush '#F5FFF7'
$titleFont = Font 78 ([System.Drawing.FontStyle]::Bold)
$graphics.DrawString('从长录音到', $titleFont, $titleBrush, 92, 465)
$graphics.DrawString('家庭沟通建议', $titleFont, $titleBrush, 92, 558)
$titleFont.Dispose()
$titleBrush.Dispose()

$accentBrush = Brush '#FFC23C'
$accentFont = Font 34 ([System.Drawing.FontStyle]::Bold)
$graphics.DrawString('SenseVoice + CAM++ + 可纠正声纹档案', $accentFont, $accentBrush, 96, 680)
$accentFont.Dispose()
$accentBrush.Dispose()

$descBrush = Brush '#D8E8DE'
$descFont = Font 28
$graphics.DrawString('一个 AI 家庭沟通助手的产品架构与算法实现', $descFont, $descBrush, 96, 735)
$descFont.Dispose()
$descBrush.Dispose()

# Right side product/architecture keywords.
$pillFont = Font 25 ([System.Drawing.FontStyle]::Bold)
$pillTextBrush = Brush '#E8FFF1'
$pillBg = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(180, 34, 75, 52))
$pillItems = @('VAD 自动切句', '情绪三分类', '说话人归属', '逐句可回放', '大模型建议')
$x = 980
$y = 505
foreach ($item in $pillItems) {
  RoundedRect $graphics (New-Object System.Drawing.RectangleF $x, $y, 258, 54) 18 $pillBg
  $graphics.DrawString($item, $pillFont, $pillTextBrush, $x + 22, $y + 11)
  $y += 70
}
$pillFont.Dispose()
$pillTextBrush.Dispose()
$pillBg.Dispose()

# Footer line.
$footerPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(120, 255, 194, 60), 3)
$graphics.DrawLine($footerPen, 96, 830, 560, 830)
$footerPen.Dispose()

$footerBrush = Brush '#AFCBBB'
$footerFont = Font 22
$graphics.DrawString('让家里的话，被更温柔地听见', $footerFont, $footerBrush, 96, 846)
$footerFont.Dispose()
$footerBrush.Dispose()

$graphics.Dispose()
$bitmap.Save($outputPath, [System.Drawing.Imaging.ImageFormat]::Png)
$bitmap.Dispose()

Write-Output $outputPath
