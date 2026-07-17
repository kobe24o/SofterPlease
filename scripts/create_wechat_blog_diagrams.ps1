$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Drawing

$root = Resolve-Path '.'
$outDir = Join-Path $root 'docs\marketing\wechat-diagrams'
New-Item -ItemType Directory -Force $outDir | Out-Null

function C([string]$hex, [int]$alpha = 255) {
  $hex = $hex.TrimStart('#')
  return [System.Drawing.Color]::FromArgb(
    $alpha,
    [Convert]::ToInt32($hex.Substring(0, 2), 16),
    [Convert]::ToInt32($hex.Substring(2, 2), 16),
    [Convert]::ToInt32($hex.Substring(4, 2), 16)
  )
}

function B([string]$hex, [int]$alpha = 255) {
  return New-Object System.Drawing.SolidBrush((C $hex $alpha))
}

function F([float]$size, [System.Drawing.FontStyle]$style = [System.Drawing.FontStyle]::Regular) {
  return New-Object System.Drawing.Font('Microsoft YaHei UI', $size, $style, [System.Drawing.GraphicsUnit]::Pixel)
}

function RoundedRect($g, [System.Drawing.RectangleF]$rect, [float]$radius, $brush, $pen = $null) {
  $path = New-Object System.Drawing.Drawing2D.GraphicsPath
  $d = $radius * 2
  $path.AddArc($rect.X, $rect.Y, $d, $d, 180, 90)
  $path.AddArc($rect.Right - $d, $rect.Y, $d, $d, 270, 90)
  $path.AddArc($rect.Right - $d, $rect.Bottom - $d, $d, $d, 0, 90)
  $path.AddArc($rect.X, $rect.Bottom - $d, $d, $d, 90, 90)
  $path.CloseFigure()
  if ($brush) { $g.FillPath($brush, $path) }
  if ($pen) { $g.DrawPath($pen, $path) }
  $path.Dispose()
}

function DrawText($g, [string]$text, [float]$x, [float]$y, [float]$w, [float]$h, $font, $brush, [string]$align = 'center') {
  $sf = New-Object System.Drawing.StringFormat
  $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
  $sf.Alignment = if ($align -eq 'left') { [System.Drawing.StringAlignment]::Near } elseif ($align -eq 'right') { [System.Drawing.StringAlignment]::Far } else { [System.Drawing.StringAlignment]::Center }
  $g.DrawString($text, $font, $brush, (New-Object System.Drawing.RectangleF $x, $y, $w, $h), $sf)
  $sf.Dispose()
}

function DrawArrow($g, [float]$x1, [float]$y1, [float]$x2, [float]$y2, $pen) {
  $g.DrawLine($pen, $x1, $y1, $x2, $y2)
  $angle = [Math]::Atan2($y2 - $y1, $x2 - $x1)
  $len = 14
  $a1 = $angle + [Math]::PI * 0.82
  $a2 = $angle - [Math]::PI * 0.82
  $p1 = New-Object System.Drawing.PointF (($x2 + [Math]::Cos($a1) * $len)), (($y2 + [Math]::Sin($a1) * $len))
  $p2 = New-Object System.Drawing.PointF (($x2 + [Math]::Cos($a2) * $len)), (($y2 + [Math]::Sin($a2) * $len))
  $g.DrawLine($pen, $x2, $y2, $p1.X, $p1.Y)
  $g.DrawLine($pen, $x2, $y2, $p2.X, $p2.Y)
}

function NewCanvas([string]$title, [string]$subtitle, [string]$file) {
  $bmp = New-Object System.Drawing.Bitmap 1400, 900
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
  $g.FillRectangle((B '#F7FAF6'), 0, 0, 1400, 900)
  $g.FillEllipse((B '#DFF1E7'), -180, -160, 500, 500)
  $g.FillEllipse((B '#FFE8CF'), 1120, -100, 410, 410)
  DrawText $g $title 70 42 1260 58 (F 42 ([System.Drawing.FontStyle]::Bold)) (B '#10261A') 'left'
  DrawText $g $subtitle 72 100 1240 40 (F 23) (B '#607168') 'left'
  return @{ Bitmap = $bmp; Graphics = $g; File = (Join-Path $outDir $file) }
}

function SaveCanvas($canvas) {
  $canvas.Graphics.Dispose()
  $canvas.Bitmap.Save($canvas.File, [System.Drawing.Imaging.ImageFormat]::Png)
  $canvas.Bitmap.Dispose()
  Write-Output $canvas.File
}

function DrawBox($g, [string]$text, [float]$x, [float]$y, [float]$w, [float]$h, [string]$fill = '#FFFFFF', [string]$stroke = '#A9C8B5') {
  $pen = New-Object System.Drawing.Pen((C $stroke), 2)
  RoundedRect $g (New-Object System.Drawing.RectangleF $x, $y, $w, $h) 22 (B $fill) $pen
  DrawText $g $text $x $y $w $h (F 25 ([System.Drawing.FontStyle]::Bold)) (B '#153523')
  $pen.Dispose()
}

# 1 Product flow
$c = NewCanvas '图 1：从真实对话到沟通建议' '产品体验链路：一次录音如何变成可执行建议' '01-product-flow.png'
$g = $c.Graphics
$items = @('真实家庭对话','手机端长录音','后端自动切句',"文本/情绪识别`n声纹/说话人归属",'逐句记录','趋势统计','AI 沟通建议','更温和的表达')
$positions = @(
  @(72,235), @(380,235), @(688,235), @(996,235),
  @(996,465), @(688,465), @(380,465), @(72,465)
)
$w = 260; $h = 96
for ($i = 0; $i -lt $items.Count; $i++) {
  $bx = $positions[$i][0]
  $by = $positions[$i][1]
  $fill = '#FFFFFF'
  if ($i -eq 6) { $fill = '#E8F5ED' }
  DrawBox $g $items[$i] $bx $by $w $h $fill
}
$pen = New-Object System.Drawing.Pen((C '#5A8D70'), 3)
DrawArrow $g 332 283 368 283 $pen
DrawArrow $g 640 283 676 283 $pen
DrawArrow $g 948 283 984 283 $pen
DrawArrow $g 1126 331 1126 453 $pen
DrawArrow $g 996 513 960 513 $pen
DrawArrow $g 688 513 652 513 $pen
DrawArrow $g 380 513 344 513 $pen
$pen.Dispose()
SaveCanvas $c

# 2 Architecture
$c = NewCanvas '图 2：SofterPlease 系统架构' 'Flutter 客户端 + FastAPI 后端 + AI 推理层 + 数据层' '02-system-architecture.png'
$g = $c.Graphics
$cols = @(
  @{title='用户侧'; items=@('Flutter 移动端','家庭与成员','长录音采集','逐句回放','统计与建议')},
  @{title='应用服务层'; items=@('FastAPI 后端','会话 API','长录音分析 API','说话人管理 API','统计与建议 API')},
  @{title='AI 推理层'; items=@('VAD 自动切句','SenseVoice 情绪识别','CAM++ 声纹','聚类与声纹档案','大模型建议')},
  @{title='数据层'; items=@('Session','ConvSegment','SpeakerIdentity','EmotionEvent','AdviceReport')}
)
$startX = 78; $colW = 285; $colGap = 46
for ($i=0; $i -lt $cols.Count; $i++) {
  $cx = $startX + $i * ($colW + $colGap)
  DrawBox $g $cols[$i].title $cx 210 $colW 64 '#1F6B46' '#1F6B46'
  DrawText $g $cols[$i].title $cx 210 $colW 64 (F 26 ([System.Drawing.FontStyle]::Bold)) (B '#FFFFFF')
  $yy = 310
  foreach ($it in $cols[$i].items) {
    DrawBox $g $it $cx $yy $colW 58 '#FFFFFF' '#BDD7C6'
    $yy += 78
  }
  if ($i -lt $cols.Count - 1) { DrawArrow $g ($cx + $colW + 8) 520 ($cx + $colW + $colGap - 14) 520 (New-Object System.Drawing.Pen((C '#5A8D70'), 3)) }
}
SaveCanvas $c

# 3 Data model
$c = NewCanvas '图 3：核心数据模型关系' '一句话就是一个最小证据单元，可回放、可修正、可复盘' '03-data-model.png'
$g = $c.Graphics
DrawBox $g "Family`n家庭" 100 380 210 110 '#E8F5ED'
DrawBox $g "Session`n一次连续沟通记录" 420 250 280 92
DrawBox $g "ConversationSegment`n一句可回放的对话片段" 780 250 360 92 '#FFFDF7' '#E1C36E'
DrawBox $g "EmotionEvent`n对应情绪事件" 780 430 360 92
DrawBox $g "SpeakerIdentity`n家庭成员声纹档案" 420 560 280 92
DrawBox $g "AdviceReport`n当天沟通建议" 780 640 360 92 '#E8F5ED'
$pen = New-Object System.Drawing.Pen((C '#5A8D70'), 3)
DrawArrow $g 310 425 420 300 $pen
DrawArrow $g 700 296 780 296 $pen
DrawArrow $g 960 342 960 430 $pen
DrawArrow $g 960 522 960 640 $pen
DrawArrow $g 310 435 420 604 $pen
DrawArrow $g 700 604 780 320 $pen
$pen.Dispose()
SaveCanvas $c

# 4 Algorithm
$c = NewCanvas '图 4：从长录音到家庭建议的算法链路' 'VAD、SenseVoice、CAM++ 和大模型建议如何协同' '04-algorithm-flow.png'
$g = $c.Graphics
$steps = @('0-10 分钟家庭录音',"音频标准化`nmono / 16kHz","VAD 切句`n静音检测 + 合并",'单句长度控制','ConversationSegment 入库','按人/天聚合统计','大模型生成建议')
$x = 90; $y = 190
for ($i=0; $i -lt 4; $i++) {
  DrawBox $g $steps[$i] ($x + $i*305) $y 250 78
  if ($i -lt 3) { DrawArrow $g ($x+$i*305+250) ($y+39) ($x+$i*305+292) ($y+39) (New-Object System.Drawing.Pen((C '#5A8D70'), 3)) }
}
DrawBox $g "SenseVoice`nASR + 情绪标签" 310 380 310 92 '#FFFDF7' '#E1C36E'
DrawBox $g "CAM++`n声纹 embedding" 780 380 310 92 '#FFFDF7' '#E1C36E'
DrawText $g '并行分析' 610 330 180 40 (F 24 ([System.Drawing.FontStyle]::Bold)) (B '#5A6B60')
$pen = New-Object System.Drawing.Pen((C '#5A8D70'), 3)
DrawArrow $g 705 268 465 380 $pen
DrawArrow $g 705 268 935 380 $pen
DrawBox $g "情绪三分类`n多维指标" 310 540 310 92
DrawBox $g "相似度匹配`n聚类与声纹档案" 780 540 310 92
DrawArrow $g 465 472 465 540 $pen
DrawArrow $g 935 472 935 540 $pen
DrawBox $g $steps[4] 545 690 310 78 '#E8F5ED'
DrawArrow $g 465 632 545 725 $pen
DrawArrow $g 935 632 855 725 $pen
DrawBox $g $steps[5] 900 690 270 78
DrawBox $g $steps[6] 120 690 310 78 '#E8F5ED'
DrawArrow $g 855 729 900 729 $pen
DrawArrow $g 545 729 430 729 $pen
$pen.Dispose()
SaveCanvas $c

# 5 Speaker learning
$c = NewCanvas '图 5：说话人识别与学习流程' '模型先判断，用户可修正，系统持续学习家庭声纹' '05-speaker-learning.png'
$g = $c.Graphics
DrawBox $g '单句音频' 100 225 220 75
DrawBox $g "CAM++ 提取`n声纹 embedding" 420 225 260 75
DrawBox $g 'L2 归一化' 790 225 220 75
DrawBox $g "与家庭声纹档案`n计算余弦相似度" 1080 225 260 75 '#FFFDF7' '#E1C36E'
$pen = New-Object System.Drawing.Pen((C '#5A8D70'), 3)
DrawArrow $g 320 262 420 262 $pen
DrawArrow $g 680 262 790 262 $pen
DrawArrow $g 1010 262 1080 262 $pen
DrawBox $g '超过阈值？' 590 410 240 80 '#E8F5ED'
DrawArrow $g 1210 300 710 410 $pen
DrawBox $g "是：归属到`n已知家庭成员" 250 585 300 90
DrawBox $g "否：进入本次录音聚类`n生成临时 speaker_id" 735 555 360 108
DrawArrow $g 590 450 550 610 $pen
DrawArrow $g 830 450 915 555 $pen
DrawBox $g '用户确认说话人' 735 710 360 72 '#FFFDF7' '#E1C36E'
DrawArrow $g 915 663 915 710 $pen
DrawBox $g "更新家庭声纹中心`n下次识别更准确" 250 710 300 92 '#E8F5ED'
DrawArrow $g 735 746 550 746 $pen
$pen.Dispose()
SaveCanvas $c
