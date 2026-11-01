param(
    [Parameter(Mandatory=$true)][string]$VideoPath,
    [Parameter(Mandatory=$true)][string]$SourceVideo,
    [string]$SourceVideoB = '',
    [Parameter(Mandatory=$true)][string]$ProductName,
    [Parameter(Mandatory=$true)][string]$AppRoot,
    [string]$FontStyle = '醒目粗黑'
)

Add-Type -AssemblyName System.Drawing
$ffmpeg = Join-Path $AppRoot 'runtime\ffmpeg-full\bin\ffmpeg.exe'
$ffprobe = Join-Path $AppRoot 'runtime\ffmpeg-full\bin\ffprobe.exe'
if (!(Test-Path -LiteralPath $ffmpeg) -or !(Test-Path -LiteralPath $ffprobe)) { throw '找不到封面处理组件。' }

$work = Join-Path ([IO.Path]::GetDirectoryName($VideoPath)) ('.cover-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work -Force | Out-Null
try {
    $frames=@()
    $sources=@($SourceVideo,$SourceVideoB)|Where-Object{$_ -and (Test-Path -LiteralPath $_)}
    if(!$sources.Count){$sources=@($VideoPath)}
    foreach($source in $sources) {
        $duration=0.0; $durationText=& $ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 $source 2>$null
        [void][double]::TryParse(([string]$durationText).Trim(),[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$duration)
        if($duration -le 0){continue}
        foreach($ratio in @(0.18,0.30,0.42,0.56,0.70,0.82)) {
            $frame=Join-Path $work ('frame-{0:00}.jpg' -f $frames.Count)
            $seconds=[math]::Max(0.1,[math]::Round($duration*$ratio,3))
            & $ffmpeg -hide_banner -loglevel error -y -ss $seconds -i $source -frames:v 1 -vf 'scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920' -q:v 2 $frame
            if((Test-Path -LiteralPath $frame) -and (Get-Item $frame).Length -gt 15000){$frames+=Get-Item $frame}
        }
    }
    if(!$frames.Count){throw '没有找到可用的封面画面。'}
    $python=Join-Path $AppRoot 'runtime\audio-processing\Scripts\python.exe'
    $selector=Join-Path $AppRoot '制作模板\scripts\select-clean-cover-frame.py'
    $selection=$null
    if((Test-Path $python) -and (Test-Path $selector)) {
        try {$selection=(& $python $selector $work 2>$null | Select-Object -Last 1 | ConvertFrom-Json)} catch {$selection=$null}
    }
    $selected=if($selection -and (Test-Path -LiteralPath $selection.path)){[string]$selection.path}else{($frames|Sort-Object Length -Descending|Select-Object -First 3|Get-Random).FullName}
    if($selection -and $selection.needsCrop) {
        # Every candidate appears to contain baked-in lower text. Zoom the clean upper
        # image region so the old subtitle cannot enter the final cover.
        $cleanFrame=Join-Path $work 'clean-frame.jpg'
        & $ffmpeg -hide_banner -loglevel error -y -i $selected -vf 'crop=iw:ih*0.58:0:0,scale=1080:1920' -frames:v 1 -q:v 2 $cleanFrame
        if((Test-Path $cleanFrame) -and (Get-Item $cleanFrame).Length -gt 15000){$selected=$cleanFrame}
    }
    $cover=Join-Path $work 'product-cover.jpg'
    $image=[Drawing.Image]::FromFile($selected)
    try {
        $bitmap=New-Object Drawing.Bitmap($image.Width,$image.Height)
        $graphics=[Drawing.Graphics]::FromImage($bitmap)
        try {
            $graphics.SmoothingMode=[Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $graphics.TextRenderingHint=[Drawing.Text.TextRenderingHint]::AntiAliasGridFit
            $graphics.DrawImage($image,0,0,$image.Width,$image.Height)
            $title=$ProductName.Trim(); if($title.Length -gt 16){$title=$title.Substring(0,16)}
            $size=if($title.Length -le 6){108}elseif($title.Length -le 10){92}else{76}
            $privateFonts = $null
            $bundledFont = switch($FontStyle){'站酷快乐体' {Join-Path $AppRoot 'runtime\fonts\ZCOOLKuaiLe-Regular.ttf'} '得意黑' {Join-Path $AppRoot 'runtime\fonts\SmileySans-Oblique.ttf'} default {''}}
            try {
                if($bundledFont -and (Test-Path -LiteralPath $bundledFont)) {
                    $privateFonts=New-Object Drawing.Text.PrivateFontCollection
                    $privateFonts.AddFontFile($bundledFont)
                    $font=New-Object Drawing.Font($privateFonts.Families[0],$size,[Drawing.FontStyle]::Regular,[Drawing.GraphicsUnit]::Pixel)
                } else {
                    $fontFamily = switch($FontStyle){'思源黑体' {'思源黑体'} '微软雅黑' {'Microsoft YaHei'} '经典黑体' {'SimHei'} default {'Noto Sans SC Black'}}
                    $font=New-Object Drawing.Font($fontFamily,$size,[Drawing.FontStyle]::Bold,[Drawing.GraphicsUnit]::Pixel)
                }
            } catch {$font=New-Object Drawing.Font('Microsoft YaHei',$size,[Drawing.FontStyle]::Bold,[Drawing.GraphicsUnit]::Pixel)}
            try {
                $format=New-Object Drawing.StringFormat; $format.Alignment=[Drawing.StringAlignment]::Center; $format.LineAlignment=[Drawing.StringAlignment]::Center
                # Keep a comfortable top margin instead of pressing the title against the edge.
                $rect=New-Object Drawing.RectangleF(35,235,1010,210)
                $black=[Drawing.Brushes]::Black; $yellow=New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(255,244,40))
                try {
                    foreach($dx in @(-5,0,5)){foreach($dy in @(-5,0,5)){if($dx -ne 0 -or $dy -ne 0){$shadow=New-Object Drawing.RectangleF(($rect.X+$dx),($rect.Y+$dy),$rect.Width,$rect.Height);$graphics.DrawString($title,$font,$black,$shadow,$format)}}}
                    $graphics.DrawString($title,$font,$yellow,$rect,$format)
                } finally {$yellow.Dispose()}
            } finally {$font.Dispose();if($privateFonts){$privateFonts.Dispose()}}
            $bitmap.Save($cover,[Drawing.Imaging.ImageFormat]::Jpeg)
        } finally {$graphics.Dispose();$bitmap.Dispose()}
    } finally {$image.Dispose()}
    $muxed=Join-Path $work 'with-cover.mp4'
    & $ffmpeg -hide_banner -loglevel error -y -i $VideoPath -i $cover -map 0 -map 1 -c copy -c:v:1 mjpeg -disposition:v:1 attached_pic -movflags +faststart $muxed
    if($LASTEXITCODE -ne 0 -or !(Test-Path $muxed)){throw '视频封面写入失败。'}
    Move-Item -LiteralPath $muxed -Destination $VideoPath -Force
} finally {Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue}

