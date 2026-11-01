Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName WindowsFormsIntegration

[System.Windows.Forms.Application]::EnableVisualStyles()

$appDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$settingsPath = Join-Path $appDir '上次项目.txt'
$iconPath = Join-Path $appDir '程序图标.ico'
$mascotPath = Join-Path $appDir '程序图标.png'
$builtInProject = Join-Path $appDir '制作模板'
$defaultProject = $builtInProject

if (Test-Path -LiteralPath $settingsPath) {
    $savedProject = (Get-Content -LiteralPath $settingsPath -Raw -ErrorAction SilentlyContinue).Trim()
    if ($savedProject -and
        (Test-Path -LiteralPath (Join-Path $savedProject 'video.config.json')) -and
        (Test-Path -LiteralPath (Join-Path $savedProject 'package.json'))) {
        $defaultProject = $savedProject
    }
}

$blue = [System.Drawing.Color]::FromArgb(26, 126, 214)
$deepBlue = [System.Drawing.Color]::FromArgb(14, 86, 150)
$lightBlue = [System.Drawing.Color]::FromArgb(232, 247, 255)
$softBlue = [System.Drawing.Color]::FromArgb(206, 237, 252)
$mutedBlue = [System.Drawing.Color]::FromArgb(93, 137, 169)
$white = [System.Drawing.Color]::White

function Show-Info([string]$message, [string]$title = '视频批量制作助手') {
    [System.Windows.Forms.MessageBox]::Show($message, $title, 'OK', 'Information') | Out-Null
}

function Show-Error([string]$message) {
    [System.Windows.Forms.MessageBox]::Show($message, '无法执行', 'OK', 'Error') | Out-Null
}

function Get-ProjectFolder { return $builtInProject }

function Save-ProjectFolder([string]$folder) {
    Set-Content -LiteralPath $settingsPath -Value $folder -Encoding UTF8
}

function Get-NodeExecutable([string]$folder) {
    $projectNode = Join-Path $folder '.tools\node22\PFiles64\nodejs\node.exe'
    if (Test-Path -LiteralPath $projectNode) { return $projectNode }

    $codexNode = Get-ChildItem 'C:\Program Files\WindowsApps\OpenAI.Codex_*\app\resources\cua_node\bin\node.exe' -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending |
        Select-Object -First 1
    if ($codexNode) { return $codexNode.FullName }

    throw '找不到兼容的视频运行环境，请重新安装或更新 Codex。'
}

function Import-Transcript([string]$path) {
    $extension = [System.IO.Path]::GetExtension($path).ToLowerInvariant()
    if ($extension -eq '.txt') {
        $text = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    } elseif ($extension -eq '.docx') {
        $archive = [System.IO.Compression.ZipFile]::OpenRead($path)
        try {
            $entry = $archive.GetEntry('word/document.xml')
            if (-not $entry) { throw 'Word文档中找不到正文。' }
            $reader = New-Object System.IO.StreamReader($entry.Open())
            try { $xml = $reader.ReadToEnd() } finally { $reader.Close() }
            $text = $xml -replace '</w:p>', "`n" -replace '<w:tab[^>]*/>', ' ' -replace '<[^>]+>', ''
            $text = [System.Net.WebUtility]::HtmlDecode($text)
        } finally { $archive.Dispose() }
    } else {
        throw '只支持 TXT 或 DOCX 配音稿。'
    }

    $lines = @($text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($lines.Count -gt 1 -and $lines[0] -match '稿$') { $lines = $lines[1..($lines.Count - 1)] }
    if ($lines.Count -eq 0) { throw '配音稿没有可用文字。' }
    [System.IO.File]::WriteAllText(
        (Join-Path $builtInProject '配音稿.txt'),
        (($lines -join "`r`n") + "`r`n"),
        (New-Object System.Text.UTF8Encoding($false))
    )
    Reset-ReviewState $builtInProject
    return $lines.Count
}

function Save-TranscriptText([string]$text, [string]$targetPath) {
    $lines = @($text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if (-not $lines.Count) { throw '请先粘贴配音稿。' }
    [System.IO.File]::WriteAllText($targetPath, (($lines -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    return $lines.Count
}

function Get-AiVoiceCatalog {
    return @(
        [PSCustomObject]@{Name='自然生活女声'; Voice='zh-CN-XiaoyiNeural'; Rate='+12%'; Pitch='+0Hz'},
        [PSCustomObject]@{Name='自然成熟女声'; Voice='zh-CN-XiaoxiaoNeural'; Rate='+10%'; Pitch='+0Hz'},
        [PSCustomObject]@{Name='自然青年男声'; Voice='zh-CN-YunxiNeural'; Rate='+12%'; Pitch='+0Hz'},
        [PSCustomObject]@{Name='沉稳运动男声'; Voice='zh-CN-YunjianNeural'; Rate='+10%'; Pitch='+0Hz'},
        [PSCustomObject]@{Name='自然讲解男声'; Voice='zh-CN-YunyangNeural'; Rate='+10%'; Pitch='+0Hz'}
    )
}

function Set-ResolvedRandomVoice($config) {
    $picked = Get-AiVoiceCatalog | Get-Random
    $config.voiceover.voice = $picked.Voice
    $config.voiceover.rate = $picked.Rate
    $config.voiceover.pitch = $picked.Pitch
    return $picked
}

function Show-TranscriptEditor([string]$targetPath, [string]$title = '配音稿输入') {
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = $title
    $dialog.StartPosition = 'CenterParent'
    $dialog.ClientSize = New-Object System.Drawing.Size(720, 500)
    $dialog.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10)
    $hint = New-Object System.Windows.Forms.Label
    $hint.Text = '直接粘贴配音稿，建议按自然停顿分行；字幕会按每行逐句同步。'
    $hint.AutoSize = $true; $hint.Location = New-Object System.Drawing.Point(18,16); $dialog.Controls.Add($hint)
    $box = New-Object System.Windows.Forms.TextBox
    $box.Multiline = $true; $box.ScrollBars = 'Vertical'; $box.AcceptsReturn = $true
    $box.Location = New-Object System.Drawing.Point(18,48); $box.Size = New-Object System.Drawing.Size(684,380)
    if (Test-Path -LiteralPath $targetPath) { $box.Text = Get-Content -LiteralPath $targetPath -Raw -Encoding UTF8 }
    $dialog.Controls.Add($box)
    $save = New-Object System.Windows.Forms.Button
    $save.Text = '保存配音稿'; $save.Location = New-Object System.Drawing.Point(562,444); $save.Size = New-Object System.Drawing.Size(140,38)
    Style-MainButton $save $blue
    $save.Add_Click({ try { Save-TranscriptText $box.Text $targetPath | Out-Null; $dialog.DialogResult = 'OK'; $dialog.Close() } catch { Show-Error $_.Exception.Message } })
    $dialog.Controls.Add($save)
    return $dialog.ShowDialog()
}

function Show-QuickSettings {
    $folder = Get-ProjectFolder; $config = Get-Config $folder
    $dialog = New-Object Windows.Forms.Form; $dialog.Text = '成片设置'; $dialog.StartPosition = 'CenterParent'; $dialog.ClientSize = New-Object Drawing.Size(520,300); $dialog.Font = New-Object Drawing.Font('Microsoft YaHei UI',10)
    $labels=@('视频时长','背景音乐','字幕位置'); for($i=0;$i -lt 3;$i++){ $l=New-Object Windows.Forms.Label; $l.Text=$labels[$i]; $l.AutoSize=$true; $l.Location=New-Object Drawing.Point(28,(38+$i*62)); $dialog.Controls.Add($l) }
    $duration=New-Object Windows.Forms.ComboBox; $duration.DropDownStyle='DropDownList'; [void]$duration.Items.AddRange(@('15秒','20秒')); $duration.SelectedItem=([string]$config.duration.targetSeconds+'秒'); if($duration.SelectedIndex -lt 0){$duration.SelectedIndex=0}; $duration.Location=New-Object Drawing.Point(145,32); $duration.Size=New-Object Drawing.Size(320,30); $dialog.Controls.Add($duration)
    $music=New-Object Windows.Forms.ComboBox; $music.DropDownStyle='DropDownList'; [void]$music.Items.Add('关闭音乐'); [void]$music.Items.Add('随机选择'); [void]$music.Items.Add('顺序轮换'); Get-ChildItem -LiteralPath (Join-Path $folder 'public\music') -File -ErrorAction SilentlyContinue | Where-Object {$_.Extension -match '^\.(wav|mp3|m4a|aac)$'} | ForEach-Object {[void]$music.Items.Add($_.BaseName)}; $music.SelectedIndex=if($config.music.mode -eq 'off'){0}elseif($config.music.selectionMode -eq 'rotate'){2}else{1}; $music.Location=New-Object Drawing.Point(145,94); $music.Size=New-Object Drawing.Size(320,30); $dialog.Controls.Add($music)
    $caption=New-Object Windows.Forms.ComboBox; $caption.DropDownStyle='DropDownList'; [void]$caption.Items.AddRange(@('偏下','居中偏下（推荐）','居中')); $bottom=[int]$config.captions.bottom; $caption.SelectedIndex=if($bottom -ge 330){2}elseif($bottom -ge 220){1}else{0}; $caption.Location=New-Object Drawing.Point(145,156); $caption.Size=New-Object Drawing.Size(320,30); $dialog.Controls.Add($caption)
    $hint=New-Object Windows.Forms.Label; $hint.Text='音乐在人声出现时会自动降低，不会盖住配音。'; $hint.ForeColor=$mutedBlue; $hint.AutoSize=$true; $hint.Location=New-Object Drawing.Point(145,198); $dialog.Controls.Add($hint)
    $save=New-Object Windows.Forms.Button; $save.Text='保存设置'; $save.Location=New-Object Drawing.Point(325,240); $save.Size=New-Object Drawing.Size(140,38); Style-MainButton $save $blue
    $save.Add_Click({ $config.duration.targetSeconds=[int]($duration.SelectedItem.ToString().Replace('秒','')); if(-not $config.music.PSObject.Properties['selectionMode']){$config.music|Add-Member -NotePropertyName selectionMode -NotePropertyValue 'fixed'}; if($music.SelectedItem -eq '关闭音乐'){$config.music.mode='off';$config.music.sourcePath='';$config.music.selectionMode='off'}else{$choices=@(Get-ChildItem -LiteralPath (Join-Path $folder 'public\music') -File|Where-Object{$_.Extension -match '^\.(wav|mp3|m4a|aac)$'});$selected=if($music.SelectedItem -eq '随机选择'){$config.music.selectionMode='random';$choices|Get-Random}elseif($music.SelectedItem -eq '顺序轮换'){$config.music.selectionMode='rotate';$choices|Select-Object -First 1}else{$config.music.selectionMode='fixed';$choices|Where-Object{$_.BaseName -eq $music.SelectedItem}|Select-Object -First 1};$config.music.mode='auto';$config.music.sourcePath=('public/music/'+$selected.Name)}; $config.captions.bottom=@(150,260,380)[$caption.SelectedIndex]; Save-Config $folder $config; Reset-ReviewState $folder; $dialog.DialogResult='OK'; $dialog.Close() }); $dialog.Controls.Add($save)
    return $dialog.ShowDialog()
}

function Import-Videos([string[]]$paths) {
    if ($paths.Count -lt 2) { throw '请同时拖入或选择 A 段和 B 段两个视频。' }
    # Explicit slot order is authoritative; filenames must never override A/B.
    $videos = @($paths)
    $node = Get-NodeExecutable $builtInProject
    $result = & $node (Join-Path $builtInProject 'scripts\import-assets.mjs') $videos[0] $videos[1] 2>&1
    if ($LASTEXITCODE -ne 0) { throw ($result -join "`r`n") }
    $duration = ($result | Select-Object -Last 1 | ConvertFrom-Json)
    Reset-ReviewState $builtInProject
    return $duration
}

function Import-VoiceAudio([string]$path) {
    $extension = [System.IO.Path]::GetExtension($path).ToLowerInvariant()
    if (@('.mp3', '.wav', '.m4a', '.aac', '.flac') -notcontains $extension) {
        throw '真人录音仅支持 MP3、WAV、M4A、AAC 或 FLAC。'
    }
    $inputFolder = Join-Path $builtInProject 'input'
    New-Item -ItemType Directory -Path $inputFolder -Force | Out-Null
    Get-ChildItem -LiteralPath $inputFolder -Filter '真人录音.*' -File -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
    $target = Join-Path $inputFolder ('真人录音' + $extension)
    Copy-Item -LiteralPath $path -Destination $target -Force
    $config = Get-Config $builtInProject
    $config.voiceover.mode = 'human'
    $config.voiceover.humanAudioPath = $target.Replace('\', '/')
    Save-Config $builtInProject $config
    Reset-ReviewState $builtInProject
    return [System.IO.Path]::GetFileName($path)
}

function Handle-DroppedFiles([string[]]$paths) {
    try {
        $videoExtensions = @('.mp4', '.mov', '.mkv', '.avi', '.webm')
        $videos = @($paths | Where-Object { $videoExtensions -contains [System.IO.Path]::GetExtension($_).ToLowerInvariant() })
        $documents = @($paths | Where-Object { @('.txt', '.docx') -contains [System.IO.Path]::GetExtension($_).ToLowerInvariant() })
        $audios = @($paths | Where-Object { @('.mp3', '.wav', '.m4a', '.aac', '.flac') -contains [System.IO.Path]::GetExtension($_).ToLowerInvariant() })
        $messages = @()
        if ($videos.Count -gt 0) {
            $duration = Import-Videos $videos
            $messages += ('视频已导入：A段 {0:N1}秒，B段 {1:N1}秒' -f $duration.aDuration, $duration.bDuration)
        }
        if ($documents.Count -gt 0) {
            $lineCount = Import-Transcript $documents[0]
            $messages += "配音稿已导入：$lineCount 句"
        }
        if ($audios.Count -gt 0) {
            $audioName = Import-VoiceAudio $audios[0]
            $messages += "真人录音已导入：$audioName"
        }
        if ($messages.Count -eq 0) { throw '没有识别到视频、配音稿或真人录音。' }
        $statusLabel.Text = $messages -join '；'
        Refresh-State
        Show-Info (($messages -join "`r`n") + "`r`n`r`n现在可以点击第2步生成预览。")
    } catch { Show-Error $_.Exception.Message }
}

function Get-StateFolder([string]$folder) { return (Join-Path $folder '.video-assistant') }
function Get-PreviewMarker([string]$folder) { return (Join-Path (Get-StateFolder $folder) 'preview-complete') }
function Get-ApprovedMarker([string]$folder) { return (Join-Path (Get-StateFolder $folder) 'approved') }
function Get-ApprovalManifest([string]$folder) { return (Join-Path (Get-StateFolder $folder) 'approved-manifest.json') }

function New-ApprovalLock([string]$folder, [string]$previewPath) {
    $node = Get-NodeExecutable $folder
    $manifest = Get-ApprovalManifest $folder
    $result = & $node (Join-Path $folder 'scripts\approval-lock.mjs') --create --config (Join-Path $folder 'video.config.json') --manifest $manifest --preview $previewPath 2>&1
    if ($LASTEXITCODE -ne 0) { throw ($result -join "`r`n") }
    return $manifest
}

function Test-ApprovalLock([string]$folder) {
    $manifest = Get-ApprovalManifest $folder
    if (-not (Test-Path -LiteralPath $manifest)) { throw '找不到审核锁定记录，请重新审核预览。' }
    $node = Get-NodeExecutable $folder
    $result = & $node (Join-Path $folder 'scripts\approval-lock.mjs') --verify --config (Join-Path $folder 'video.config.json') --manifest $manifest 2>&1
    if ($LASTEXITCODE -ne 0) {
        $jsonLine = @($result | Where-Object { $_ -match '^\{' }) | Select-Object -Last 1
        if ($jsonLine) {
            $report = $jsonLine | ConvertFrom-Json
            $details = @($report.changes | ForEach-Object { "$($_.role)：$($_.reason)" }) -join "`r`n"
            throw "审核通过后的内容发生变化：`r`n$details`r`n`r`n请重新生成预览并审核。"
        }
        throw ($result -join "`r`n")
    }
    return $true
}

function Reset-ReviewState([string]$folder) {
    $stateFolder = Get-StateFolder $folder
    New-Item -ItemType Directory -Path $stateFolder -Force | Out-Null
    Remove-Item -LiteralPath (Get-PreviewMarker $folder) -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Get-ApprovedMarker $folder) -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Get-ApprovalManifest $folder) -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $stateFolder 'failed') -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $stateFolder 'progress.json') -Force -ErrorAction SilentlyContinue
}

function Test-VideoProject([string]$folder) {
    if (-not (Test-Path -LiteralPath $folder -PathType Container)) {
        Show-Error '项目文件夹不存在，请重新选择。'
        return $false
    }
    $required = @('package.json', 'video.config.json', '配音稿.txt')
    $missing = @($required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $folder $_)) })
    if ($missing.Count -gt 0) {
        Show-Error ("该文件夹不是完整的视频项目，缺少：`r`n" + ($missing -join '、'))
        return $false
    }
    return $true
}

function Get-Config([string]$folder) {
    return (Get-Content -LiteralPath (Join-Path $folder 'video.config.json') -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Save-Config([string]$folder, $config) {
    $json = $config | ConvertTo-Json -Depth 20
    [System.IO.File]::WriteAllText(
        (Join-Path $folder 'video.config.json'),
        $json,
        (New-Object System.Text.UTF8Encoding($false))
    )
}

function Find-Preview([string]$folder) {
    $previewFolder = Join-Path $folder '输出\预览'
    if (-not (Test-Path -LiteralPath $previewFolder)) { return $null }
    return Get-ChildItem -LiteralPath $previewFolder -Filter '*.mp4' -File |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
}

function Find-LatestPlayableVideo([string]$folder) {
    $outputFolder = Join-Path $folder '输出'
    if (-not (Test-Path -LiteralPath $outputFolder)) { return $null }
    $ffprobe = Join-Path $appDir 'runtime\ffmpeg-full\bin\ffprobe.exe'
    foreach ($candidate in @(Get-ChildItem -LiteralPath $outputFolder -Recurse -Filter '*.mp4' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 20)) {
        if ($candidate.Length -lt 100KB) { continue }
        & $ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 $candidate.FullName *>$null
        if ($LASTEXITCODE -eq 0) { return $candidate }
    }
    return $null
}

function Invoke-Preflight([string]$folder, [string]$mode, [string]$platform = 'universal', [bool]$showSuccess = $true) {
    $node = Get-NodeExecutable $folder
    $reportFolder = Join-Path $folder '输出\审核报告'
    $startedAt = Get-Date
    & $node (Join-Path $folder 'scripts\preflight-check.mjs') --config (Join-Path $folder 'video.config.json') --mode $mode --platform $platform --output-dir $reportFolder *>$null
    $exitCode = $LASTEXITCODE
    $reportFile = Get-ChildItem -LiteralPath $reportFolder -Filter '*_生成前体检.json' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $startedAt.AddSeconds(-2) } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if (-not $reportFile) { throw '生成前体检没有产生有效报告，请点击“程序自检”后重试。' }
    $report = Get-Content -LiteralPath $reportFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($exitCode -ne 0 -or $report.result -eq 'failed') {
        $details = @($report.items | Where-Object { -not $_.passed -and $_.level -eq 'fail' } | ForEach-Object { "• $($_.name)：$($_.detail)" }) -join "`r`n"
        throw "生成前体检未通过：`r`n`r`n$details`r`n`r`n请修复后再开始。"
    }
    if ($showSuccess) {
        $warningText = @($report.items | Where-Object { -not $_.passed } | ForEach-Object { "• $($_.name)：$($_.detail)" }) -join "`r`n"
        if ($warningText) { Show-Info "生成前体检通过，但有提醒：`r`n`r`n$warningText" }
        else { Show-Info '生成前体检通过：素材、配音稿、磁盘空间和运行组件均正常。' }
    }
    return $report
}

function Invoke-ProgramSelfTest([bool]$showSuccess = $true) {
    $checks = [System.Collections.ArrayList]@()
    $addCheck = { param($name,$passed,$detail) [void]$checks.Add([PSCustomObject]@{name=$name;passed=[bool]$passed;detail=$detail}) }
    try { $point = [Drawing.Point]::new(28,75); & $addCheck '界面坐标组件' ($point.X -eq 28 -and $point.Y -eq 75) '窗口控件可正常创建' } catch { & $addCheck '界面坐标组件' $false $_.Exception.Message }
    try { $testIcon = New-Object Drawing.Icon($iconPath); $testIcon.Dispose(); & $addCheck '程序图标' $true '图标可正常读取' } catch { & $addCheck '程序图标' $false $_.Exception.Message }
    $required = @('视频批量制作助手.ps1','后台制作视频.ps1','后台批量制作.ps1','制作模板\scripts\render.mjs','制作模板\scripts\prepare-assets.mjs','制作模板\scripts\preflight-check.mjs')
    foreach ($relative in $required) { $path = Join-Path $appDir $relative; & $addCheck $relative (Test-Path -LiteralPath $path) $(if(Test-Path -LiteralPath $path){'文件正常'}else{'文件缺失'}) }
    try {
        $node = Get-NodeExecutable $builtInProject
        $syntaxFiles = @('render.mjs','prepare-assets.mjs','preflight-check.mjs')
        $syntaxOk = $true
        foreach ($name in $syntaxFiles) { & $node --check (Join-Path $builtInProject ('scripts\'+$name)) 2>&1 | Out-Null; if($LASTEXITCODE -ne 0){$syntaxOk=$false} }
        & $addCheck '视频脚本语法' $syntaxOk $(if($syntaxOk){'核心脚本正常'}else{'核心脚本存在错误'})
    } catch { & $addCheck '视频脚本语法' $false $_.Exception.Message }
    & $addCheck '视频处理组件' (Test-Path -LiteralPath (Join-Path $appDir 'runtime\ffmpeg-full\bin\ffmpeg.exe')) '高清导出组件'
    & $addCheck '自然配音组件' (Test-Path -LiteralPath (Join-Path $appDir 'runtime\edge-tts\Scripts\edge-tts.exe')) '配音运行组件'
    try {
        $state = Join-Path $builtInProject '.video-assistant'
        New-Item -ItemType Directory -Path $state -Force | Out-Null
        $writeTest = Join-Path $state 'write-test.tmp'
        [IO.File]::WriteAllText($writeTest,'ok',(New-Object Text.UTF8Encoding($false)))
        Remove-Item -LiteralPath $writeTest -Force
        & $addCheck '文件写入权限' $true '可以保存任务和成片'
    } catch { & $addCheck '文件写入权限' $false $_.Exception.Message }
    $failures = @($checks | Where-Object { -not $_.passed })
    $reportFolder = Join-Path $builtInProject '输出\审核报告'
    New-Item -ItemType Directory -Path $reportFolder -Force | Out-Null
    $reportPath = Join-Path $reportFolder '程序自检.txt'
    $lines = @('程序自检','结果：'+$(if($failures.Count){'未通过'}else{'通过'}),'') + @($checks|ForEach-Object{"[$(if($_.passed){'通过'}else{'失败'})] $($_.name)：$($_.detail)"})
    [IO.File]::WriteAllText($reportPath,($lines -join "`r`n"),(New-Object Text.UTF8Encoding($false)))
    if ($failures.Count) {
        $details = @($failures|ForEach-Object{"• $($_.name)：$($_.detail)"}) -join "`r`n"
        throw "程序自检未通过，已经禁止生成：`r`n`r`n$details"
    }
    if ($showSuccess) { Show-Info '程序自检通过，界面、视频、配音和文件保存组件均正常。' '程序自检' }
    return $true
}

function Get-BatchQueuePath { return (Join-Path $appDir '批量任务\queue.json') }
function Get-BatchControlPath { return (Join-Path $appDir '批量任务\control.json') }

function Set-BatchControl([string]$state, [string]$mode = '') {
    $path = Get-BatchControlPath
    New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
    if (-not $mode -and (Test-Path -LiteralPath $path)) {
        try { $mode = (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json).mode } catch {}
    }
    if (-not $mode) { $mode = 'Preview' }
    $control = [PSCustomObject]@{ state = $state; mode = $mode; updatedAt = (Get-Date -Format o) }
    [System.IO.File]::WriteAllText($path, ($control | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
}

function Get-BatchQueue {
    $path = Get-BatchQueuePath
    if (-not (Test-Path -LiteralPath $path)) {
        return [PSCustomObject]@{ version = 1; updatedAt = (Get-Date -Format o); jobs = @() }
    }
    return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Save-BatchQueue($queue) {
    $path = Get-BatchQueuePath
    New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
    $queue.updatedAt = Get-Date -Format o
    $temp = $path + '.tmp'
    [System.IO.File]::WriteAllText($temp, ($queue | ConvertTo-Json -Depth 20), (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $temp -Destination $path -Force
}

function Copy-BatchMaterials([string]$jobId, [string]$productName, [string]$aPath, [string]$bPath, [string]$transcriptPath, [string]$voiceAudioPath = '') {
    $taskFolder = Join-Path $appDir ('批量任务\素材\' + $jobId)
    New-Item -ItemType Directory -Path $taskFolder -Force | Out-Null
    try {
        $aTarget = Join-Path $taskFolder ('A段' + [IO.Path]::GetExtension($aPath).ToLowerInvariant())
        $bTarget = Join-Path $taskFolder ('B段' + [IO.Path]::GetExtension($bPath).ToLowerInvariant())
        $textTarget = Join-Path $taskFolder ('配音稿' + [IO.Path]::GetExtension($transcriptPath).ToLowerInvariant())
        Copy-Item -LiteralPath $aPath -Destination $aTarget -Force
        Copy-Item -LiteralPath $bPath -Destination $bTarget -Force
        Copy-Item -LiteralPath $transcriptPath -Destination $textTarget -Force
        $audioTarget = ''
        if ($voiceAudioPath) {
            $audioTarget = Join-Path $taskFolder ('真人录音' + [IO.Path]::GetExtension($voiceAudioPath).ToLowerInvariant())
            Copy-Item -LiteralPath $voiceAudioPath -Destination $audioTarget -Force
        }
        $metadata = [PSCustomObject]@{ jobId=$jobId; productName=$productName; copiedAt=(Get-Date -Format o); originalFolder=(Split-Path -Parent $aPath) }
        [IO.File]::WriteAllText((Join-Path $taskFolder '素材信息.json'),($metadata|ConvertTo-Json),(New-Object Text.UTF8Encoding($false)))
        return [PSCustomObject]@{Folder=$taskFolder;APath=$aTarget;BPath=$bTarget;TranscriptPath=$textTarget;VoiceAudioPath=$audioTarget}
    } catch {
        Remove-Item -LiteralPath $taskFolder -Recurse -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Confirm-CleanupExpiredBatchMaterials {
    $materialRoot = Join-Path $appDir '批量任务\素材'
    if (-not (Test-Path -LiteralPath $materialRoot)) { return }
    $queue = Get-BatchQueue
    $protectedIds = @{}
    foreach ($job in @($queue.jobs | Where-Object { $_.status -ne '已完成' })) { $protectedIds[[string]$job.id] = $true }
    $deadline = (Get-Date).AddDays(-3)
    $expired = @(Get-ChildItem -LiteralPath $materialRoot -Directory -ErrorAction SilentlyContinue | Where-Object {
        $_.CreationTime -lt $deadline -and -not $protectedIds.ContainsKey($_.Name)
    })
    if (-not $expired.Count) { return }
    $bytes = 0L
    foreach ($folder in $expired) { $bytes += [long](Get-ChildItem -LiteralPath $folder.FullName -File -Recurse -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum }
    $sizeText = if ($bytes -ge 1GB) { '{0:N1}GB' -f ($bytes/1GB) } else { '{0:N0}MB' -f ($bytes/1MB) }
    $answer = [Windows.Forms.MessageBox]::Show("发现 $($expired.Count) 个已保存超过3天的已完成素材，共约 $sizeText。`r`n`r`n现在清理吗？选择【否】会继续保留。",'素材清理确认','YesNo','Question')
    if ($answer -eq [Windows.Forms.DialogResult]::Yes) {
        foreach ($folder in $expired) { Remove-Item -LiteralPath $folder.FullName -Recurse -Force -ErrorAction SilentlyContinue }
        Show-Info '超过3天的已完成素材已经清理。'
    }
}

function Add-BatchFolders([string]$selectedFolder) {
    $videoExtensions = @('.mp4', '.mov', '.mkv', '.avi', '.webm')
    $candidates = @($selectedFolder) + @(Get-ChildItem -LiteralPath $selectedFolder -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
    $queue = Get-BatchQueue
    $jobs = [System.Collections.ArrayList]@(@($queue.jobs))
    $existing = @{}
    foreach ($job in $jobs) {
        $sourceFolder = if ($job.originalFolder) { [string]$job.originalFolder } else { [string]$job.folder }
        $existing[$sourceFolder] = $true
    }
    $added = 0
    foreach ($folder in $candidates | Select-Object -Unique) {
        if ($existing.ContainsKey($folder)) { continue }
        $files = @(Get-ChildItem -LiteralPath $folder -File -ErrorAction SilentlyContinue)
        $videos = @($files | Where-Object { $videoExtensions -contains $_.Extension.ToLowerInvariant() } | Sort-Object {
            if ($_.Name -match '(?i)A段|(^|[^a-z])a([^a-z]|$)') { 0 }
            elseif ($_.Name -match '(?i)B段|(^|[^a-z])b([^a-z]|$)') { 1 }
            else { 2 }
        }, Name)
        $transcript = $files | Where-Object { @('.txt', '.docx') -contains $_.Extension.ToLowerInvariant() } | Sort-Object Name | Select-Object -First 1
        $voiceAudio = $files | Where-Object { @('.mp3', '.wav', '.m4a', '.aac', '.flac') -contains $_.Extension.ToLowerInvariant() } | Sort-Object Name | Select-Object -First 1
        if ($videos.Count -lt 2 -or -not $transcript) { continue }
        $jobId = [guid]::NewGuid().ToString('N')
        $copied = Copy-BatchMaterials $jobId (Split-Path -Leaf $folder) $videos[0].FullName $videos[1].FullName $transcript.FullName $(if($voiceAudio){$voiceAudio.FullName}else{''})
        $job = [PSCustomObject][ordered]@{
            id = $jobId
            name = Split-Path -Leaf $folder
            folder = $copied.Folder
            originalFolder = $folder
            aPath = $copied.APath
            bPath = $copied.BPath
            transcriptPath = $copied.TranscriptPath
            voiceAudioPath = $copied.VoiceAudioPath
            status = '等待预览'
            approved = $false
            previewPath = ''
            finalPaths = @()
            complianceReport = ''
            qualityReports = @()
            approvalManifest = ''
            previewConfig = $null
            preflightReport = ''
            startedAt = ''
            finishedAt = ''
            estimatedSeconds = 0
            previewElapsedSeconds = 0
            finalElapsedSeconds = 0
            lastError = ''
            updatedAt = Get-Date -Format o
        }
        [void]$jobs.Add($job)
        $existing[$folder] = $true
        $added++
    }
    $queue.jobs = @($jobs)
    Save-BatchQueue $queue
    return $added
}

function Start-BatchWorker([string]$mode, [string]$jobId = '') {
    try { Invoke-ProgramSelfTest $false | Out-Null } catch { Show-Error $_.Exception.Message; return $false }
    $platformMap = @{'通用高清'='universal'; '抖音'='douyin'; '视频号'='wechat'; '小红书'='xiaohongshu'; '全部平台'='all'}
    $platform = $platformMap[$platformCombo.SelectedItem.ToString()]
    Set-BatchControl 'running' $mode
    $worker = Join-Path $appDir '后台批量制作.ps1'
    $argumentParts = @(
        '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass',
        '-File', ('"' + $worker + '"'),
        '-AppDir', ('"' + $appDir + '"'),
        '-Mode', $mode,
        '-Platform', $platform
    )
    if ($jobId) { $argumentParts += @('-JobId', $jobId) }
    $arguments = $argumentParts -join ' '
    Start-Process powershell.exe -ArgumentList $arguments -WindowStyle Hidden
    return $true
}

function New-BatchApprovalLock($job) {
    $lockFolder = Join-Path $appDir '批量任务\审核锁定'
    New-Item -ItemType Directory -Path $lockFolder -Force | Out-Null
    $config = if ($job.previewConfig) { $job.previewConfig } else { Get-Config $builtInProject }
    $config.productName = $job.name
    $config.segments.a.sourcePath = ([string]$job.aPath).Replace('\', '/')
    $config.segments.b.sourcePath = ([string]$job.bPath).Replace('\', '/')
    $config.voiceover.sourcePath = ([string]$job.transcriptPath).Replace('\', '/')
    if ($job.voiceAudioPath) {
        $config.voiceover.mode = 'human'
        $config.voiceover.humanAudioPath = ([string]$job.voiceAudioPath).Replace('\', '/')
    } elseif ($job.voiceConfig -and [string]$job.voiceConfig.mode -eq 'source') {
        $config.voiceover.mode = 'source'
        $config.voiceover.humanAudioPath = ''
    } else {
        $config.voiceover.mode = 'ai'
        $config.voiceover.humanAudioPath = ''
    }
    $configPath = Join-Path $lockFolder ($job.id + '-config.json')
    $manifestPath = Join-Path $lockFolder ($job.id + '-manifest.json')
    [System.IO.File]::WriteAllText($configPath, ($config | ConvertTo-Json -Depth 20), (New-Object System.Text.UTF8Encoding($false)))
    $node = Get-NodeExecutable $builtInProject
    $result = & $node (Join-Path $builtInProject 'scripts\approval-lock.mjs') --create --config $configPath --manifest $manifestPath --preview $job.previewPath 2>&1
    if ($LASTEXITCODE -ne 0) { throw ($result -join "`r`n") }
    $job | Add-Member -NotePropertyName approvalManifest -NotePropertyValue $manifestPath -Force
    return $manifestPath
}

function Complete-BatchFromReview($job) {
    if (-not $job.previewPath -or -not (Test-Path -LiteralPath $job.previewPath)) {
        throw '找不到高清待审核成片，不能转正。'
    }
    New-BatchApprovalLock $job | Out-Null
    $safeName = ([string]$job.name) -replace '[<>:"/\\|?*]', '_'
    $finalFolder = Join-Path $appDir '批量任务\输出\正式成片'
    New-Item -ItemType Directory -Path $finalFolder -Force | Out-Null
    $finalPath = Join-Path $finalFolder ($safeName + '.mp4')
    Copy-Item -LiteralPath $job.previewPath -Destination $finalPath -Force
    $job.approved = $true
    $job.status = '已完成'
    $job.finalPaths = @($finalPath)
    $job.updatedAt = Get-Date -Format o
    return $finalPath
}

function Show-BatchCenter {
    $previousMainWindowState = $form.WindowState
    $form.WindowState = [System.Windows.Forms.FormWindowState]::Minimized
    $batchForm = New-Object System.Windows.Forms.Form
    $batchForm.Text = '批量生产中心'
    $batchForm.StartPosition = 'CenterParent'
    $batchForm.ClientSize = New-Object System.Drawing.Size(1040, 780)
    $batchForm.MinimumSize = New-Object System.Drawing.Size(720, 520)
    $batchForm.AutoScroll = $true
    $batchForm.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::Sizable
    $batchForm.BackColor = $lightBlue
    $batchForm.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    $batchForm.AllowDrop = $true
    $batchForm.MinimizeBox = $true
    if (Test-Path -LiteralPath $iconPath) { $batchForm.Icon = New-Object System.Drawing.Icon($iconPath) }

    $batchTitle = New-Object System.Windows.Forms.Label
    $batchTitle.Text = '批量制作  ·  每条任务选择 A段、B段并直接粘贴对应配音稿'
    $batchTitle.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 14, [System.Drawing.FontStyle]::Bold)
    $batchTitle.ForeColor = $deepBlue
    $batchTitle.AutoSize = $true
    $batchTitle.Location = New-Object System.Drawing.Point(22, 18)
    $batchForm.Controls.Add($batchTitle)

    $pauseBatchButton = New-Object System.Windows.Forms.Button
    $pauseBatchButton.Text = '完成当前后暂停'
    $pauseBatchButton.Location = New-Object System.Drawing.Point(676, 10)
    $pauseBatchButton.Size = New-Object System.Drawing.Size(130, 36)
    Style-UtilityButton $pauseBatchButton
    $pauseBatchButton.Add_Click({ Set-BatchControl 'paused'; Show-Info '已请求暂停。当前正在制作的任务完成后会暂停。' '批量生产中心' })
    $batchForm.Controls.Add($pauseBatchButton)
    $pauseBatchButton.Visible = $false

    $resumeBatchButton = New-Object System.Windows.Forms.Button
    $resumeBatchButton.Text = '继续队列'
    $resumeBatchButton.Location = New-Object System.Drawing.Point(816, 10)
    $resumeBatchButton.Size = New-Object System.Drawing.Size(92, 36)
    Style-MainButton $resumeBatchButton $blue
    $resumeBatchButton.Add_Click({
        $mode = 'Preview'
        $path = Get-BatchControlPath
        if (Test-Path -LiteralPath $path) { try { $mode = (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json).mode } catch {} }
        if (Start-BatchWorker $mode) { Show-Info '队列已经继续处理。' '批量生产中心' }
    })
    $batchForm.Controls.Add($resumeBatchButton)
    $resumeBatchButton.Visible = $false

    $cancelBatchButton = New-Object System.Windows.Forms.Button
    $cancelBatchButton.Text = '完成当前后停止'
    $cancelBatchButton.Location = New-Object System.Drawing.Point(918, 10)
    $cancelBatchButton.Size = New-Object System.Drawing.Size(100, 36)
    Style-UtilityButton $cancelBatchButton
    $cancelBatchButton.Add_Click({ Set-BatchControl 'cancelled'; Show-Info '已请求停止。当前正在制作的任务完成后会停止，未处理任务会保留。' '批量生产中心' })
    $batchForm.Controls.Add($cancelBatchButton)
    $cancelBatchButton.Visible = $false

    $hideBatchWindowButton = New-Object System.Windows.Forms.Button
    $hideBatchWindowButton.Text = '隐藏到任务栏'
    $hideBatchWindowButton.Location = New-Object System.Drawing.Point(878, 10)
    $hideBatchWindowButton.Size = New-Object System.Drawing.Size(140, 36)
    Style-UtilityButton $hideBatchWindowButton
    $hideBatchWindowButton.Add_Click({ $batchForm.WindowState = [System.Windows.Forms.FormWindowState]::Minimized })
    $batchForm.Controls.Add($hideBatchWindowButton)

    $stagingState = [PSCustomObject]@{
        ParentFolder = ''
        APath = ''
        BPath = ''
        TranscriptPath = ''
        VoiceAudioPath = ''
    }

    $stagingPanel = New-Object System.Windows.Forms.Panel
    $stagingPanel.Location = New-Object System.Drawing.Point(22, 58)
    $stagingPanel.Size = New-Object System.Drawing.Size(996, 250)
    $stagingPanel.BackColor = $white
    $stagingPanel.BorderStyle = 'FixedSingle'
    $stagingPanel.AllowDrop = $true
    $batchForm.Controls.Add($stagingPanel)

    $productNameLabel = New-Object System.Windows.Forms.Label
    $productNameLabel.Text = '当前产品名称'
    $productNameLabel.AutoSize = $true
    $productNameLabel.ForeColor = $deepBlue
    $productNameLabel.Location = New-Object System.Drawing.Point(16, 15)
    $stagingPanel.Controls.Add($productNameLabel)

    $productNameBox = New-Object System.Windows.Forms.TextBox
    $productNameBox.Location = New-Object System.Drawing.Point(112, 10)
    $productNameBox.Size = New-Object System.Drawing.Size(220, 30)
    $stagingPanel.Controls.Add($productNameBox)

    $coverFontLabel = New-Object Windows.Forms.Label; $coverFontLabel.Text='封面字体'; $coverFontLabel.AutoSize=$true; $coverFontLabel.Location=New-Object Drawing.Point(350,15); $stagingPanel.Controls.Add($coverFontLabel)
    $batchCoverFont = New-Object Windows.Forms.ComboBox; $batchCoverFont.DropDownStyle='DropDownList'; [void]$batchCoverFont.Items.AddRange(@('站酷快乐体（推荐）','得意黑','醒目粗黑','思源黑体','微软雅黑','经典黑体')); $batchCoverFont.SelectedIndex=0; $batchCoverFont.Location=New-Object Drawing.Point(420,10); $batchCoverFont.Size=New-Object Drawing.Size(155,30); $stagingPanel.Controls.Add($batchCoverFont)

    $stagingHint = New-Object System.Windows.Forms.Label
    $stagingHint.Text = '完成当前这一条后加入队列，再继续添加下一条'
    $stagingHint.AutoSize = $true
    $stagingHint.ForeColor = $mutedBlue
    $stagingHint.Text = '加入后继续添加下一条'
    $stagingHint.Location = New-Object System.Drawing.Point(580, 15)
    $stagingPanel.Controls.Add($stagingHint)

    $joinQueueButton = New-Object System.Windows.Forms.Button
    $joinQueueButton.Text = '确认加入队列'
    $joinQueueButton.Location = New-Object System.Drawing.Point(742, 6)
    $joinQueueButton.Size = New-Object System.Drawing.Size(135, 38)
    Style-MainButton $joinQueueButton $blue
    $stagingPanel.Controls.Add($joinQueueButton)

    $clearStagingButton = New-Object System.Windows.Forms.Button
    $clearStagingButton.Text = '清空暂存'
    $clearStagingButton.Location = New-Object System.Drawing.Point(887, 6)
    $clearStagingButton.Size = New-Object System.Drawing.Size(94, 38)
    Style-UtilityButton $clearStagingButton
    $stagingPanel.Controls.Add($clearStagingButton)

    $aSlot = New-Object System.Windows.Forms.Label
    $aSlot.Location = New-Object System.Drawing.Point(16, 54)
    $aSlot.Size = New-Object System.Drawing.Size(230, 55)
    $aSlot.TextAlign = 'MiddleCenter'
    $aSlot.BorderStyle = 'FixedSingle'
    $aSlot.AllowDrop = $true
    $aSlot.Cursor = [System.Windows.Forms.Cursors]::Hand
    $stagingPanel.Controls.Add($aSlot)

    $bSlot = New-Object System.Windows.Forms.Label
    $bSlot.Location = New-Object System.Drawing.Point(260, 54)
    $bSlot.Size = New-Object System.Drawing.Size(230, 55)
    $bSlot.TextAlign = 'MiddleCenter'
    $bSlot.BorderStyle = 'FixedSingle'
    $bSlot.AllowDrop = $true
    $bSlot.Cursor = [System.Windows.Forms.Cursors]::Hand
    $stagingPanel.Controls.Add($bSlot)

    $transcriptSlot = New-Object System.Windows.Forms.Label
    $transcriptSlot.Location = New-Object System.Drawing.Point(504, 54)
    $transcriptSlot.Size = New-Object System.Drawing.Size(230, 55)
    $transcriptSlot.TextAlign = 'MiddleCenter'
    $transcriptSlot.BorderStyle = 'FixedSingle'
    $transcriptSlot.AllowDrop = $true
    $transcriptSlot.Cursor = [System.Windows.Forms.Cursors]::Hand
    $transcriptSlot.Visible = $false
    $stagingPanel.Controls.Add($transcriptSlot)

    $audioSlot = New-Object System.Windows.Forms.Label
    $audioSlot.Location = New-Object System.Drawing.Point(748, 54)
    $audioSlot.Size = New-Object System.Drawing.Size(230, 55)
    $audioSlot.TextAlign = 'MiddleCenter'
    $audioSlot.BorderStyle = 'FixedSingle'
    $audioSlot.AllowDrop = $true
    $audioSlot.Visible = $false
    $stagingPanel.Controls.Add($audioSlot)

    $batchScriptLabel = New-Object System.Windows.Forms.Label
    $batchScriptLabel.Text = '本条视频配音稿（直接粘贴）'
    $batchScriptLabel.AutoSize = $true
    $batchScriptLabel.ForeColor = $deepBlue
    $batchScriptLabel.Location = New-Object System.Drawing.Point(504, 56)
    $stagingPanel.Controls.Add($batchScriptLabel)
    $batchScriptBox = New-Object System.Windows.Forms.TextBox
    $batchScriptBox.Multiline = $true
    $batchScriptBox.ScrollBars = 'Vertical'
    $batchScriptBox.AcceptsReturn = $true
    $batchScriptBox.Location = New-Object System.Drawing.Point(504, 80)
    $batchScriptBox.Size = New-Object System.Drawing.Size(474, 125)
    $stagingPanel.Controls.Add($batchScriptBox)

    $batchConfig = Get-Config $builtInProject
    $batchSettingHint = New-Object Windows.Forms.Label; $batchSettingHint.Text='本批设置'; $batchSettingHint.AutoSize=$true; $batchSettingHint.ForeColor=$deepBlue; $batchSettingHint.Location=New-Object Drawing.Point(16,216); $stagingPanel.Controls.Add($batchSettingHint)
    $batchDuration = New-Object Windows.Forms.ComboBox; $batchDuration.DropDownStyle='DropDownList'; [void]$batchDuration.Items.AddRange(@('15秒','20秒')); $batchDuration.SelectedItem=([string]$batchConfig.duration.targetSeconds+'秒'); if($batchDuration.SelectedIndex -lt 0){$batchDuration.SelectedIndex=1}; $batchDuration.Location=New-Object Drawing.Point(90,210); $batchDuration.Size=New-Object Drawing.Size(90,28); $stagingPanel.Controls.Add($batchDuration)
    $batchAiToggle = New-Object Windows.Forms.Button; $batchAiToggle.Tag=($batchConfig.voiceover.mode -ne 'source'); $batchAiToggle.Location=New-Object Drawing.Point(192,207); $batchAiToggle.Size=New-Object Drawing.Size(84,34); Style-UtilityButton $batchAiToggle; $stagingPanel.Controls.Add($batchAiToggle)
    $batchVoice = New-Object Windows.Forms.ComboBox; $batchVoice.DropDownStyle='DropDownList'; [void]$batchVoice.Items.Add('随机声音'); Get-AiVoiceCatalog|ForEach-Object{[void]$batchVoice.Items.Add($_.Name)}; $batchVoice.SelectedIndex=if($batchConfig.voiceover.selectionMode -eq 'random'){0}else{1}; $batchVoice.Location=New-Object Drawing.Point(284,210); $batchVoice.Size=New-Object Drawing.Size(150,28); $stagingPanel.Controls.Add($batchVoice)
    $updateBatchAiToggle={if([bool]$batchAiToggle.Tag){$batchAiToggle.Text='AI已开启';$batchVoice.Enabled=$true}else{$batchAiToggle.Text='AI已关闭';$batchVoice.Enabled=$false}}; &$updateBatchAiToggle
    $batchAiToggle.Add_Click({$batchAiToggle.Tag=-not [bool]$batchAiToggle.Tag;&$updateBatchAiToggle})
    $batchMusic = New-Object Windows.Forms.ComboBox; $batchMusic.DropDownStyle='DropDownList'; [void]$batchMusic.Items.AddRange(@('关闭音乐','随机音乐','顺序轮换')); Get-ChildItem -LiteralPath (Join-Path $builtInProject 'public\music') -File|Where-Object{$_.Extension -match '^\.(wav|mp3)$'}|ForEach-Object{[void]$batchMusic.Items.Add($_.BaseName)}; $batchMusic.SelectedIndex=if($batchConfig.music.mode -eq 'off'){0}elseif($batchConfig.music.selectionMode -eq 'rotate'){2}elseif($batchConfig.music.selectionMode -eq 'random'){1}else{3}; $batchMusic.Location=New-Object Drawing.Point(446,210); $batchMusic.Size=New-Object Drawing.Size(170,28); $stagingPanel.Controls.Add($batchMusic)
    $batchCaption = New-Object Windows.Forms.ComboBox; $batchCaption.DropDownStyle='DropDownList'; [void]$batchCaption.Items.AddRange(@('字幕偏下','字幕居中偏下','字幕居中')); $batchCaption.SelectedIndex=if([int]$batchConfig.captions.bottom -ge 330){2}elseif([int]$batchConfig.captions.bottom -ge 220){1}else{0}; $batchCaption.Location=New-Object Drawing.Point(628,210); $batchCaption.Size=New-Object Drawing.Size(145,28); $stagingPanel.Controls.Add($batchCaption)
    $batchCaptionStyle = New-Object Windows.Forms.ComboBox; $batchCaptionStyle.DropDownStyle='DropDownList'; [void]$batchCaptionStyle.Items.AddRange(@('现有黄字','粗白字黑边')); $batchCaptionStyle.SelectedIndex=if([string]$batchConfig.captions.color -eq '#FFFFFF'){1}else{0}; $batchCaptionStyle.Location=New-Object Drawing.Point(785,210); $batchCaptionStyle.Size=New-Object Drawing.Size(145,28); $stagingPanel.Controls.Add($batchCaptionStyle)

    $refreshStaging = {
        $aSlot.Text = if ($stagingState.APath) { "A段 已就绪`r`n$([IO.Path]::GetFileName($stagingState.APath))" } else { "A段视频`r`n拖到这里" }
        $bSlot.Text = if ($stagingState.BPath) { "B段 已就绪`r`n$([IO.Path]::GetFileName($stagingState.BPath))" } else { "B段视频`r`n拖到这里" }
        $transcriptSlot.Text = if ($stagingState.TranscriptPath) { "配音稿 已就绪`r`n$([IO.Path]::GetFileName($stagingState.TranscriptPath))" } else { "配音稿 TXT/DOCX`r`n拖到这里" }
        $audioSlot.Text = if ($stagingState.VoiceAudioPath) { "真人录音 已就绪`r`n$([IO.Path]::GetFileName($stagingState.VoiceAudioPath))" } else { "真人录音（可选）`r`n拖到这里" }
        foreach ($pair in @(@($aSlot,$stagingState.APath), @($bSlot,$stagingState.BPath), @($transcriptSlot,$stagingState.TranscriptPath), @($audioSlot,$stagingState.VoiceAudioPath))) {
            $pair[0].BackColor = if ($pair[1]) { $softBlue } else { $lightBlue }
            $pair[0].ForeColor = if ($pair[1]) { $deepBlue } else { $mutedBlue }
        }
    }

    $clearStaging = {
        $stagingState.ParentFolder = ''
        $stagingState.APath = ''
        $stagingState.BPath = ''
        $stagingState.TranscriptPath = ''
        $stagingState.VoiceAudioPath = ''
        $productNameBox.Text = ''
        $batchScriptBox.Clear()
        & $refreshStaging
    }

    $stagingDragEnter = {
        param($sender, $eventArgs)
        if ($eventArgs.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) { $eventArgs.Effect = 'Copy' }
        else { $eventArgs.Effect = 'None' }
    }

    $stagingDrop = {
        param($sender, $eventArgs)
        try {
            $paths = @([string[]]$eventArgs.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
            if (-not $paths.Count) { throw '请拖入文件，不要拖入文件夹。' }
            $parents = @($paths | ForEach-Object { [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($_)) } | Select-Object -Unique)

            $queue = Get-BatchQueue
            $usedPaths = @{}
            foreach ($job in @($queue.jobs)) {
                foreach ($used in @($job.aPath,$job.bPath,$job.transcriptPath,$job.voiceAudioPath)) {
                    if ($used) { $usedPaths[[IO.Path]::GetFullPath([string]$used)] = $true }
                }
            }
            foreach ($path in $paths) {
                if ($usedPaths.ContainsKey([IO.Path]::GetFullPath($path))) { throw "这个素材已经属于队列中的其他产品：$([IO.Path]::GetFileName($path))" }
            }

            $tempA = $stagingState.APath
            $tempB = $stagingState.BPath
            $tempTranscript = $stagingState.TranscriptPath
            $tempAudio = $stagingState.VoiceAudioPath
            $targetKind = if ($sender -eq $aSlot) { 'A' } elseif ($sender -eq $bSlot) { 'B' } elseif ($sender -eq $transcriptSlot) { 'Transcript' } elseif ($sender -eq $audioSlot) { 'Audio' } else { 'Auto' }
            foreach ($path in $paths) {
                $extension = [IO.Path]::GetExtension($path).ToLowerInvariant()
                $name = [IO.Path]::GetFileNameWithoutExtension($path)
                if (@('.mp4','.mov','.mkv','.avi','.webm') -contains $extension) {
                    if ($targetKind -in @('Transcript','Audio')) { throw '视频必须拖到A段或B段位置，已阻止放错素材。' }
                    $isA = $name -match '(?i)A段|(^|[^a-z])a([^a-z]|$)'
                    $isB = $name -match '(?i)B段|(^|[^a-z])b([^a-z]|$)'
                    if ($targetKind -eq 'A') {
                        # 放入哪个区域就按哪个片段处理，文件名不参与判断。
                        $tempA = $path
                    } elseif ($targetKind -eq 'B') {
                        # 允许任意原文件名，也允许重新拖入来替换选错的素材。
                        $tempB = $path
                    } elseif ($isA -and -not $isB) {
                        if ($tempA -and $tempA -ne $path) { throw 'A段位置已经有视频，已阻止覆盖。请先确认当前产品。' }
                        $tempA = $path
                    } elseif ($isB -and -not $isA) {
                        if ($tempB -and $tempB -ne $path) { throw 'B段位置已经有视频，已阻止覆盖。请先确认当前产品。' }
                        $tempB = $path
                    } elseif (-not $tempA) { $tempA = $path }
                    elseif (-not $tempB) { $tempB = $path }
                    else { throw '当前产品已经有两个视频，已阻止加入第三个视频。' }
                } elseif (@('.txt','.docx') -contains $extension) {
                    if ($targetKind -in @('A','B','Audio')) { throw '配音稿必须拖到配音稿位置，已阻止放错素材。' }
                    if ($tempTranscript -and $tempTranscript -ne $path) { throw '当前产品已经有配音稿，已阻止覆盖。' }
                    $tempTranscript = $path
                } elseif (@('.mp3','.wav','.m4a','.aac','.flac') -contains $extension) {
                    if ($targetKind -in @('A','B','Transcript')) { throw '真人录音必须拖到真人录音位置，已阻止放错素材。' }
                    if ($tempAudio -and $tempAudio -ne $path) { throw '当前产品已经有真人录音，已阻止覆盖。' }
                    $tempAudio = $path
                } else { throw "不支持这个文件：$([IO.Path]::GetFileName($path))" }
            }

            if ($tempA -and $tempB -and [IO.Path]::GetFullPath($tempA) -eq [IO.Path]::GetFullPath($tempB)) { throw 'A段和B段不能使用同一个视频。' }
            if (-not $stagingState.ParentFolder -and $parents.Count) { $stagingState.ParentFolder = $parents[0] }
            $stagingState.APath = $tempA
            $stagingState.BPath = $tempB
            $stagingState.TranscriptPath = $tempTranscript
            $stagingState.VoiceAudioPath = $tempAudio
            if (-not $productNameBox.Text.Trim()) {
                $parentName = if ($parents.Count) { Split-Path -Leaf $parents[0] } else { '' }
                if ($parentName -notin @('Desktop','桌面')) { $productNameBox.Text = $parentName }
            }
            & $refreshStaging
        } catch { Show-Error $_.Exception.Message }
    }

    foreach ($control in @($batchForm,$stagingPanel,$aSlot,$bSlot,$transcriptSlot,$audioSlot)) {
        $control.Add_DragEnter($stagingDragEnter)
        $control.Add_DragDrop($stagingDrop)
    }
    $clearStagingButton.Add_Click({ & $clearStaging })
    $aSlot.Add_Click({
        $d=New-Object Windows.Forms.OpenFileDialog;$d.Title='选择本条任务的A段视频';$d.Filter='视频文件|*.mp4;*.mov;*.mkv;*.avi;*.webm';if($d.ShowDialog() -eq 'OK'){$stagingState.APath=$d.FileName;if(-not $stagingState.ParentFolder){$stagingState.ParentFolder=[IO.Path]::GetDirectoryName($d.FileName)};&$refreshStaging}
    })
    $bSlot.Add_Click({
        $d=New-Object Windows.Forms.OpenFileDialog;$d.Title='选择本条任务的B段视频';$d.Filter='视频文件|*.mp4;*.mov;*.mkv;*.avi;*.webm';if($d.ShowDialog() -eq 'OK'){$stagingState.BPath=$d.FileName;if(-not $stagingState.ParentFolder){$stagingState.ParentFolder=[IO.Path]::GetDirectoryName($d.FileName)};&$refreshStaging}
    })
    $transcriptSlot.Add_Click({
        try {
            $inputFolder = Join-Path $appDir '批量任务\输入暂存'
            New-Item -ItemType Directory -Path $inputFolder -Force | Out-Null
            $inputPath = Join-Path $inputFolder '当前配音稿.txt'
            if ((Show-TranscriptEditor $inputPath '当前产品配音稿') -eq 'OK') { $stagingState.TranscriptPath = $inputPath; & $refreshStaging }
        } catch { Show-Error $_.Exception.Message }
    })

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object System.Drawing.Point(22, 320)
    $grid.Size = New-Object System.Drawing.Size(996, 304)
    $grid.ReadOnly = $true
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.AutoSizeColumnsMode = 'Fill'
    $grid.SelectionMode = 'FullRowSelect'
    $grid.MultiSelect = $false
    $grid.BackgroundColor = $white
    [void]$grid.Columns.Add('product', '产品')
    [void]$grid.Columns.Add('aVideo', 'A段')
    [void]$grid.Columns.Add('bVideo', 'B段')
    [void]$grid.Columns.Add('script', '配音稿')
    [void]$grid.Columns.Add('settings', '声音/音乐')
    [void]$grid.Columns.Add('status', '状态')
    [void]$grid.Columns.Add('output', '成品')
    $batchForm.Controls.Add($grid)
    $grid.Add_CellDoubleClick({
        if($grid.SelectedRows.Count){
            $id=[string]$grid.SelectedRows[0].Tag
            $job=@((Get-BatchQueue).jobs)|Where-Object{$_.id -eq $id}|Select-Object -First 1
            $video=@($job.finalPaths)|Where-Object{$_ -and (Test-Path -LiteralPath $_)}|Select-Object -First 1
            if($video){Start-Process -FilePath $video}else{Show-Info '这条任务还没有生成视频。'}
        }
    })

    $refreshGrid = {
        try {
            $selectedId = if ($grid.SelectedRows.Count) { [string]$grid.SelectedRows[0].Tag } else { '' }
            $grid.Rows.Clear()
            $queue = Get-BatchQueue
            foreach ($job in @($queue.jobs)) {
                $scriptPreview = try { ((Get-Content -LiteralPath $job.transcriptPath -Raw -Encoding UTF8).Trim() -replace "`r?`n",' ') } catch { '配音稿已保存' }
                if ($scriptPreview.Length -gt 20) { $scriptPreview = $scriptPreview.Substring(0,20) + '…' }
                $settingText = "$(if($job.voiceConfig.name){$job.voiceConfig.name}else{'AI配音'}) / $(if($job.musicConfig.sourcePath){[IO.Path]::GetFileNameWithoutExtension($job.musicConfig.sourcePath)}else{'无音乐'})"
                $progressText = '—'
                $remainingText = '—'
                if ($job.startedAt -and $job.status -match '^正在') {
                    $elapsed = [math]::Max(0, [math]::Round(((Get-Date) - [datetime]$job.startedAt).TotalSeconds))
                    $estimate = [math]::Max(1, [double]$job.estimatedSeconds)
                    $progressText = ([math]::Min(95, [math]::Round($elapsed / $estimate * 100))).ToString() + '%'
                    $remaining = [math]::Max(0, [math]::Round($estimate - $elapsed))
                    $remainingText = if ($remaining -ge 60) { '约' + [math]::Ceiling($remaining / 60) + '分钟' } else { '约' + $remaining + '秒' }
                } elseif ($job.finishedAt) {
                    $seconds = if ($job.status -eq '已完成') { [double]$job.finalElapsedSeconds } else { [double]$job.previewElapsedSeconds }
                    if ($seconds -gt 0) { $progressText = '用时' + [math]::Round($seconds) + '秒' }
                }
                $outputText = if(@($job.finalPaths).Count){'已生成'}elseif($job.previewPath){'已生成'}else{'—'}
                $index = $grid.Rows.Add($job.name,[IO.Path]::GetFileName($job.aPath),[IO.Path]::GetFileName($job.bPath),$scriptPreview,$settingText,$job.status,$outputText)
                $grid.Rows[$index].Tag = $job.id
                if ($job.lastError) { $grid.Rows[$index].Cells['status'].ToolTipText = $job.lastError }
                if ($selectedId -and $job.id -eq $selectedId) { $grid.Rows[$index].Selected = $true }
            }
        } catch {}
    }

    $joinQueueButton.Add_Click({
        try {
            $name = $productNameBox.Text.Trim()
            if (-not $name) { throw '请填写当前产品名称。' }
            if (-not $stagingState.APath) { throw '当前产品缺少A段视频。' }
            if (-not $stagingState.BPath) { throw '当前产品缺少B段视频。' }
            $jobId = [guid]::NewGuid().ToString('N')
            if ($batchScriptBox.Text.Trim()) {
                $inputFolder = Join-Path $appDir '批量任务\输入暂存'
                New-Item -ItemType Directory -Path $inputFolder -Force | Out-Null
                $inputPath = Join-Path $inputFolder ($jobId + '.txt')
                Save-TranscriptText $batchScriptBox.Text $inputPath | Out-Null
                $stagingState.TranscriptPath = $inputPath
            }
            if (-not $stagingState.TranscriptPath) { throw '当前产品缺少配音稿。' }
            $queue = Get-BatchQueue
            if (@($queue.jobs | Where-Object { $_.name -eq $name }).Count) { throw '队列中已经有同名产品，请修改产品名称后再加入。' }
            $copied = Copy-BatchMaterials $jobId $name $stagingState.APath $stagingState.BPath $stagingState.TranscriptPath $stagingState.VoiceAudioPath
            $currentConfig = Get-Config $builtInProject
            $currentConfig.duration.targetSeconds = [int]$batchDuration.SelectedItem.ToString().Replace('秒','')
            if (-not [bool]$batchAiToggle.Tag) { $currentConfig.voiceover.mode='source'; $currentConfig.voiceover.selectionMode='off' }
            elseif ($batchVoice.SelectedItem -eq '随机声音') { $currentConfig.voiceover.mode='ai'; $currentConfig.voiceover.selectionMode='random'; Set-ResolvedRandomVoice $currentConfig | Out-Null }
            else { $pickedVoice=Get-AiVoiceCatalog|Where-Object{$_.Name -eq $batchVoice.SelectedItem}|Select-Object -First 1; $currentConfig.voiceover.mode='ai';$currentConfig.voiceover.selectionMode='fixed';$currentConfig.voiceover.voice=$pickedVoice.Voice;$currentConfig.voiceover.rate=$pickedVoice.Rate;$currentConfig.voiceover.pitch=$pickedVoice.Pitch }
            $musicFiles = @(Get-ChildItem -LiteralPath (Join-Path $builtInProject 'public\music') -File | Where-Object {$_.Extension -match '^\.(wav|mp3|m4a|aac)$'} | Sort-Object Name)
            if($batchMusic.SelectedItem -eq '关闭音乐'){$currentConfig.music.mode='off';$currentConfig.music.selectionMode='off';$currentConfig.music.sourcePath=''}
            elseif($batchMusic.SelectedItem -eq '随机音乐'){
                $currentConfig.music.mode='auto';$currentConfig.music.selectionMode='random'
                $usedMusic=@($queue.jobs|ForEach-Object{[string]$_.musicConfig.sourcePath}|Where-Object{$_}|Select-Object -Unique)
                $availableMusic=@($musicFiles|Where-Object{$candidate=$_;'public/music/'+$candidate.Name -notin $usedMusic})
                if(-not $availableMusic.Count){$availableMusic=$musicFiles}
                $currentConfig.music.sourcePath='public/music/'+(($availableMusic|Get-Random).Name)
            }
            elseif($batchMusic.SelectedItem -eq '顺序轮换'){$currentConfig.music.mode='auto';$currentConfig.music.selectionMode='rotate';$currentConfig.music.sourcePath='public/music/'+$musicFiles[@($queue.jobs).Count % $musicFiles.Count].Name}
            else{$pickedMusic=$musicFiles|Where-Object{$_.BaseName -eq $batchMusic.SelectedItem}|Select-Object -First 1;$currentConfig.music.mode='auto';$currentConfig.music.selectionMode='fixed';$currentConfig.music.sourcePath='public/music/'+$pickedMusic.Name}
            $currentConfig.captions.bottom=@(150,260,380)[$batchCaption.SelectedIndex]
            if($batchCaptionStyle.SelectedIndex -eq 1){$currentConfig.captions.fontFamily='Noto Sans SC Black, Microsoft YaHei, sans-serif';$currentConfig.captions.color='#FFFFFF';$currentConfig.captions.fontWeight=900;$currentConfig.captions.strokeWidth=3}else{$currentConfig.captions.fontFamily='Microsoft YaHei, sans-serif';$currentConfig.captions.color='#FFD83D';$currentConfig.captions.fontWeight=800;$currentConfig.captions.strokeWidth=2}
            $job = [PSCustomObject][ordered]@{
                id = $jobId
                name = $name
                folder = $copied.Folder
                originalFolder = $stagingState.ParentFolder
                aPath = $copied.APath
                bPath = $copied.BPath
                transcriptPath = $copied.TranscriptPath
                voiceAudioPath = $copied.VoiceAudioPath
                durationSeconds = [int]$currentConfig.duration.targetSeconds
                voiceConfig = [PSCustomObject]@{ name=$batchVoice.SelectedItem.ToString(); mode=$currentConfig.voiceover.mode; voice=$currentConfig.voiceover.voice; rate=$currentConfig.voiceover.rate; pitch=$currentConfig.voiceover.pitch }
                musicConfig = [PSCustomObject]@{ mode=$currentConfig.music.mode; sourcePath=$currentConfig.music.sourcePath }
                captionBottom = [int]$currentConfig.captions.bottom
                captionStyle = [PSCustomObject]@{fontFamily=$currentConfig.captions.fontFamily;color=$currentConfig.captions.color;fontWeight=$currentConfig.captions.fontWeight;strokeWidth=$currentConfig.captions.strokeWidth}
                coverFont = ([string]$batchCoverFont.SelectedItem).Replace('（推荐）','')
                status = '等待预览'
                approved = $false
                previewPath = ''
                finalPaths = @()
                complianceReport = ''
                qualityReports = @()
                approvalManifest = ''
                previewConfig = $null
                preflightReport = ''
                startedAt = ''
                finishedAt = ''
                estimatedSeconds = 0
                previewElapsedSeconds = 0
                finalElapsedSeconds = 0
                lastError = ''
                updatedAt = Get-Date -Format o
            }
            $queue.jobs = @($queue.jobs) + @($job)
            Save-BatchQueue $queue
            & $clearStaging
            & $refreshGrid
            Show-Info "“$name”已经加入队列。输入区已清空，现在可以继续添加下一条。" '批量制作'
        } catch { Show-Error $_.Exception.Message }
    })

    $addBatchButton = New-Object System.Windows.Forms.Button
    $addBatchButton.Text = '添加产品文件夹'
    $addBatchButton.Location = New-Object System.Drawing.Point(22, 650)
    $addBatchButton.Size = New-Object System.Drawing.Size(145, 42)
    Style-MainButton $addBatchButton $blue
    $addBatchButton.Add_Click({
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.Description = '选择一个产品文件夹，或选择包含多个产品子文件夹的总文件夹。每个产品需有两个视频和一份配音稿。'
        if ($dialog.ShowDialog() -eq 'OK') {
            try {
                $count = Add-BatchFolders $dialog.SelectedPath
                & $refreshGrid
                Show-Info "已加入 $count 个新产品任务。" '批量生产中心'
            } catch { Show-Error $_.Exception.Message }
        }
    })
    $batchForm.Controls.Add($addBatchButton)
    $addBatchButton.Visible = $false

    $batchPreviewButton = New-Object System.Windows.Forms.Button
    $batchPreviewButton.Text = '开始生成全部视频'
    $batchPreviewButton.Location = New-Object System.Drawing.Point(22, 650)
    $batchPreviewButton.Size = New-Object System.Drawing.Size(500, 48)
    Style-MainButton $batchPreviewButton $blue
    $batchPreviewButton.Add_Click({ if (Start-BatchWorker 'Preview') { $batchTitle.Text='批量制作已开始，可点击“隐藏到任务栏”，制作不会中断' } })
    $batchForm.Controls.Add($batchPreviewButton)

    $approveJobButton = New-Object System.Windows.Forms.Button
    $approveJobButton.Text = '查看并通过选中项'
    $approveJobButton.Location = New-Object System.Drawing.Point(340, 650)
    $approveJobButton.Size = New-Object System.Drawing.Size(170, 42)
    Style-UtilityButton $approveJobButton
    $approveJobButton.Add_Click({
        if (-not $grid.SelectedRows.Count) { Show-Info '请先选择一条任务。' '批量生产中心'; return }
        $id = [string]$grid.SelectedRows[0].Tag
        $queue = Get-BatchQueue
        $job = @($queue.jobs) | Where-Object { $_.id -eq $id } | Select-Object -First 1
        if (-not $job -or -not $job.previewPath -or -not (Test-Path -LiteralPath $job.previewPath)) { Show-Info '这条任务还没有可用的高清待审核成片。' '批量生产中心'; return }
        Show-EmbeddedPreview $job.previewPath
        $result = [System.Windows.Forms.MessageBox]::Show('这条高清待审核成片是否通过？通过后直接转正，不会重新渲染。', '批量审核', 'YesNo', 'Question')
        $job.approved = $result -eq [System.Windows.Forms.DialogResult]::Yes
        if ($job.approved) {
            try { Complete-BatchFromReview $job | Out-Null } catch { $job.approved = $false; Show-Error $_.Exception.Message; return }
        } else {
            $job | Add-Member -NotePropertyName approvalManifest -NotePropertyValue '' -Force
        }
        if (-not $job.approved) { $job.status = '待修改' }
        $job.updatedAt = Get-Date -Format o
        Save-BatchQueue $queue
        & $refreshGrid
    })
    $batchForm.Controls.Add($approveJobButton)
    $approveJobButton.Visible = $false

    $batchFinalButton = New-Object System.Windows.Forms.Button
    $batchFinalButton.Text = '通过后自动转正'
    $batchFinalButton.Location = New-Object System.Drawing.Point(524, 650)
    $batchFinalButton.Size = New-Object System.Drawing.Size(160, 42)
    Style-MainButton $batchFinalButton $deepBlue
    $batchFinalButton.Add_Click({ Show-Info '现在只生成一次高清待审核成片；审核通过后同一文件会直接转正，不再重复渲染。' '批量生产中心' })
    $batchForm.Controls.Add($batchFinalButton)
    $batchFinalButton.Visible = $false

    $openBatchButton = New-Object System.Windows.Forms.Button
    $openBatchButton.Text = '查看生成的视频'
    $openBatchButton.Location = New-Object System.Drawing.Point(540, 650)
    $openBatchButton.Size = New-Object System.Drawing.Size(220, 48)
    Style-UtilityButton $openBatchButton
    $openBatchButton.Add_Click({
        $folder = Join-Path $appDir '生成的视频'
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        Start-Process explorer.exe ('"' + $folder + '"')
    })
    $batchForm.Controls.Add($openBatchButton)

    $removeJobButton = New-Object System.Windows.Forms.Button
    $removeJobButton.Text = '删除选中任务'
    $removeJobButton.Location = New-Object System.Drawing.Point(780, 650)
    $removeJobButton.Size = New-Object System.Drawing.Size(222, 48)
    Style-UtilityButton $removeJobButton
    $removeJobButton.Add_Click({
        if (-not $grid.SelectedRows.Count) { return }
        $id = [string]$grid.SelectedRows[0].Tag
        $queue = Get-BatchQueue
        $queue.jobs = @($queue.jobs | Where-Object { $_.id -ne $id })
        Save-BatchQueue $queue
        & $refreshGrid
    })
    $batchForm.Controls.Add($removeJobButton)

    $detailJobButton = New-Object System.Windows.Forms.Button
    $detailJobButton.Text = '查看任务详情'
    $detailJobButton.Location = New-Object System.Drawing.Point(22, 710)
    $detailJobButton.Size = New-Object System.Drawing.Size(145, 42)
    Style-UtilityButton $detailJobButton
    $detailJobButton.Add_Click({
        if (-not $grid.SelectedRows.Count) { Show-Info '请先选择一条任务。' '批量生产中心'; return }
        $id = [string]$grid.SelectedRows[0].Tag
        $job = @((Get-BatchQueue).jobs) | Where-Object { $_.id -eq $id } | Select-Object -First 1
        if (-not $job) { return }
        $previewTime = if ([double]$job.previewElapsedSeconds -gt 0) { "$([math]::Round([double]$job.previewElapsedSeconds))秒" } else { '尚未完成' }
        $finalTime = if ([double]$job.finalElapsedSeconds -gt 0) { "$([math]::Round([double]$job.finalElapsedSeconds))秒" } else { '尚未完成' }
        $message = @(
            "产品：$($job.name)",
            "状态：$($job.status)",
            "预览用时：$previewTime",
            "正式生成用时：$finalTime",
            "A段：$($job.aPath)",
            "B段：$($job.bPath)",
            "配音稿：$($job.transcriptPath)",
            "体检报告：$(if($job.preflightReport){$job.preflightReport}else{'尚未生成'})",
            "失败原因：$(if($job.lastError){$job.lastError}else{'无'})"
        ) -join "`r`n`r`n"
        Show-Info $message '任务详情'
    })
    $batchForm.Controls.Add($detailJobButton)
    $detailJobButton.Visible = $false

    $retryJobButton = New-Object System.Windows.Forms.Button
    $retryJobButton.Text = '重试选中任务'
    $retryJobButton.Location = New-Object System.Drawing.Point(181, 710)
    $retryJobButton.Size = New-Object System.Drawing.Size(145, 42)
    Style-MainButton $retryJobButton $blue
    $retryJobButton.Add_Click({
        if (-not $grid.SelectedRows.Count) { Show-Info '请先选择一条任务。' '批量生产中心'; return }
        $id = [string]$grid.SelectedRows[0].Tag
        $queue = Get-BatchQueue
        $job = @($queue.jobs) | Where-Object { $_.id -eq $id } | Select-Object -First 1
        if (-not $job) { return }
        $retryMode = if ($job.status -eq '正式生成失败' -and $job.approved) { 'Final' } else { 'Preview' }
        $job.status = if ($retryMode -eq 'Final') { '已通过' } else { '等待预览' }
        $job.lastError = ''
        $job | Add-Member -NotePropertyName startedAt -NotePropertyValue '' -Force
        $job | Add-Member -NotePropertyName finishedAt -NotePropertyValue '' -Force
        $job.updatedAt = Get-Date -Format o
        Save-BatchQueue $queue
        & $refreshGrid
        if (Start-BatchWorker $retryMode $job.id) { Show-Info "已重新开始：$($job.name)" '批量生产中心' }
    })
    $batchForm.Controls.Add($retryJobButton)
    $retryJobButton.Visible = $false

    $batchTimer = New-Object System.Windows.Forms.Timer
    $batchTimer.Interval = 2000
    $batchTimer.Add_Tick({ & $refreshGrid })
    $batchForm.Add_FormClosed({ $batchTimer.Stop() })
    & $refreshGrid
    & $refreshStaging
    $batchTimer.Start()
    try {
        [void]$batchForm.ShowDialog()
    } finally {
        if (-not $form.IsDisposed) {
            $form.WindowState = if ($previousMainWindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) { [System.Windows.Forms.FormWindowState]::Normal } else { $previousMainWindowState }
            $form.Activate()
        }
    }
}

function Show-EmbeddedPreview([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { throw '找不到要播放的视频文件。' }
    Start-Process -FilePath $path
    [System.Windows.Forms.MessageBox]::Show(
        "视频已经使用系统播放器打开。`r`n`r`n请完整看完视频并关闭系统播放器，然后点击【确定】继续审核。`r`n`r`n文件位置：`r`n$path",
        '观看预览视频',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null
}

function Start-Worker([string]$folder, [string]$mode) {
    $worker = Join-Path $appDir '后台制作视频.ps1'
    $arguments = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', ('"' + $worker + '"'),
        '-ProjectFolder', ('"' + $folder + '"'),
        '-Mode', $mode
    ) -join ' '
    Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WindowStyle Hidden
}

function Show-VoicePicker {
    $edgeTts = Join-Path $appDir 'runtime\edge-tts\Scripts\edge-tts.exe'
    if (-not (Test-Path -LiteralPath $edgeTts)) { throw '自然配音组件不存在，请重新安装程序运行组件。' }
    $sampleFolder = Join-Path $appDir 'runtime\声音试听'
    New-Item -ItemType Directory -Path $sampleFolder -Force | Out-Null
    $options = @(Get-AiVoiceCatalog)
    $picker = New-Object System.Windows.Forms.Form
    $picker.Text = '选择自然配音'
    $picker.StartPosition = 'CenterParent'
    $picker.ClientSize = New-Object System.Drawing.Size(520, 570)
    $picker.BackColor = $lightBlue
    $picker.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10)
    if (Test-Path -LiteralPath $iconPath) { $picker.Icon = New-Object System.Drawing.Icon($iconPath) }
    $title = New-Object System.Windows.Forms.Label
    $title.Text = '逐个试听，选中的声音会用于预览和正式成片'
    $title.Location = New-Object System.Drawing.Point(24, 20)
    $title.AutoSize = $true
    $title.ForeColor = $deepBlue
    $picker.Controls.Add($title)
    for ($index = 0; $index -lt $options.Count; $index++) {
        $option = $options[$index]
        $y = 65 + $index * 58
        $label = New-Object System.Windows.Forms.Label
        $label.Text = $option.Name
        $label.Location = [System.Drawing.Point]::new(28, ($y + 10))
        $label.Size = New-Object System.Drawing.Size(165, 28)
        $picker.Controls.Add($label)
        $listen = New-Object System.Windows.Forms.Button
        $listen.Text = '试听'
        $listen.Location = New-Object System.Drawing.Point(210, $y)
        $listen.Size = New-Object System.Drawing.Size(100, 40)
        $listen.Tag = $option
        Style-UtilityButton $listen
        $listen.Add_Click({
            try {
                $item = $this.Tag
                $target = Join-Path $sampleFolder ($item.Voice + '.mp3')
                if (-not (Test-Path -LiteralPath $target)) {
                    $sample = '你好，这是自然配音试听。希望今天的分享，能给你带来轻松愉快的心情。'
                    $output = & $edgeTts --text $sample --voice $item.Voice --rate $item.Rate --pitch $item.Pitch --write-media $target 2>&1
                    if ($LASTEXITCODE -ne 0) { throw ($output -join "`r`n") }
                }
                Start-Process -FilePath $target
            } catch { Show-Error $_.Exception.Message }
        })
        $picker.Controls.Add($listen)
        $select = New-Object System.Windows.Forms.Button
        $select.Text = '选用这个声音'
        $select.Location = New-Object System.Drawing.Point(326, $y)
        $select.Size = New-Object System.Drawing.Size(155, 40)
        $select.Tag = $option
        Style-MainButton $select $blue
        $select.Add_Click({
            try {
                $item = $this.Tag
                $config = Get-Config (Get-ProjectFolder)
                $config.voiceover.mode = 'ai'
                $config.voiceover.voice = $item.Voice
                $config.voiceover.rate = $item.Rate
                $config.voiceover.pitch = $item.Pitch
                Save-Config (Get-ProjectFolder) $config
                Reset-ReviewState (Get-ProjectFolder)
                $voiceCombo.SelectedItem = $item.Name
                $voiceStatusLabel.Text = '已选用：' + $item.Name + ' · 自然语速'
                $picker.Close()
            } catch { Show-Error $_.Exception.Message }
        })
        $picker.Controls.Add($select)
    }
    [void]$picker.ShowDialog($form)
}

function Style-MainButton($button, [System.Drawing.Color]$color) {
    $button.FlatStyle = 'Flat'
    $button.FlatAppearance.BorderSize = 0
    $button.BackColor = $color
    $button.ForeColor = $white
    $button.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 11, [System.Drawing.FontStyle]::Bold)
    $button.Cursor = 'Hand'
}

function Style-UtilityButton($button) {
    $button.FlatStyle = 'Flat'
    $button.FlatAppearance.BorderColor = $softBlue
    $button.FlatAppearance.BorderSize = 1
    $button.BackColor = $white
    $button.ForeColor = $deepBlue
    $button.Cursor = 'Hand'
}

if ($args -contains '--self-test') {
    try { Invoke-ProgramSelfTest $false | Out-Null; Write-Output 'SELF_TEST_OK'; exit 0 }
    catch { Write-Error $_.Exception.Message; exit 2 }
}

if ($args -contains '--batch-self-test') {
    $testRoot = Join-Path $appDir ('runtime\batch-self-test-' + [guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
        $voices = @(Get-AiVoiceCatalog)
        $musicFiles = @(Get-ChildItem -LiteralPath (Join-Path $builtInProject 'public\music') -Filter '*.wav' -File | Sort-Object Name)
        $jobs = @()
        1..3 | ForEach-Object {
            $index = $_
            $transcript = Join-Path $testRoot ("任务$index-配音稿.txt")
            Save-TranscriptText "这是任务$index 的独立配音稿。`r`n字幕必须对应任务$index。" $transcript | Out-Null
            $voice = $voices[$index - 1]
            $music = $musicFiles[$index - 1]
            $jobs += [PSCustomObject]@{
                id = "test-$index"; name = "测试视频$index"; aPath = "A$index.mp4"; bPath = "B$index.mp4"; transcriptPath = $transcript
                voiceConfig = [PSCustomObject]@{name=$voice.Name;voice=$voice.Voice;rate=$voice.Rate;pitch=$voice.Pitch}
                musicConfig = [PSCustomObject]@{mode='auto';sourcePath=('public/music/'+$music.Name)}
            }
        }
        $roundTrip = (([PSCustomObject]@{jobs=$jobs}) | ConvertTo-Json -Depth 10 | ConvertFrom-Json)
        if (@($roundTrip.jobs).Count -ne 3) { throw '任务数量校验失败。' }
        if (@($roundTrip.jobs | Select-Object -ExpandProperty transcriptPath -Unique).Count -ne 3) { throw '配音稿没有独立保存。' }
        if (@($roundTrip.jobs | ForEach-Object {$_.voiceConfig.voice} | Select-Object -Unique).Count -ne 3) { throw '声音设置没有独立保存。' }
        if (@($roundTrip.jobs | ForEach-Object {$_.musicConfig.sourcePath} | Select-Object -Unique).Count -ne 3) { throw '音乐设置没有独立保存。' }
        foreach($job in $roundTrip.jobs){if(-not(Test-Path -LiteralPath $job.transcriptPath)){throw '测试配音稿不存在。'}}
        Write-Output 'BATCH_SELF_TEST_OK:3_TASKS_3_SCRIPTS_3_VOICES_3_MUSIC'
        exit 0
    } catch { Write-Error $_.Exception.Message; exit 3 }
    finally {
        $resolvedTest = [IO.Path]::GetFullPath($testRoot)
        $resolvedRuntime = [IO.Path]::GetFullPath((Join-Path $appDir 'runtime'))
        if ($resolvedTest.StartsWith($resolvedRuntime,[StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $resolvedTest -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

$script:openBatchOnStart = $args -contains '--open-batch-test'

$form = New-Object System.Windows.Forms.Form
$form.Text = '视频批量制作助手'
$form.StartPosition = 'CenterScreen'
$form.ClientSize = New-Object System.Drawing.Size(1120, 700)
$form.MinimumSize = New-Object System.Drawing.Size(720, 520)
$form.MinimizeBox = $true
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::Sizable
$form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10)
$form.BackColor = $lightBlue
$form.AllowDrop = $true
$form.AutoScroll = $true
if (Test-Path -LiteralPath $iconPath) { $form.Icon = New-Object System.Drawing.Icon($iconPath) }

$header = New-Object System.Windows.Forms.Panel
$header.Dock = 'Top'
$header.Height = 132
$header.BackColor = $white
$form.Controls.Add($header)

if (Test-Path -LiteralPath $mascotPath) {
    $mascot = New-Object System.Windows.Forms.PictureBox
    $mascot.Image = [System.Drawing.Image]::FromFile($mascotPath)
    $mascot.SizeMode = 'Zoom'
    $mascot.Location = New-Object System.Drawing.Point(24, 14)
    $mascot.Size = New-Object System.Drawing.Size(104, 104)
    $header.Controls.Add($mascot)
}

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Text = '视频批量制作助手'
$titleLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 21, [System.Drawing.FontStyle]::Bold)
$titleLabel.ForeColor = $deepBlue
$titleLabel.AutoSize = $true
$titleLabel.Location = New-Object System.Drawing.Point(148, 28)
$header.Controls.Add($titleLabel)

$hintLabel = New-Object System.Windows.Forms.Label
$hintLabel.Text = '导入视频 · 粘贴配音稿 · 选择设置 · 自动生成成片'
$hintLabel.ForeColor = $mutedBlue
$hintLabel.AutoSize = $true
$hintLabel.Location = New-Object System.Drawing.Point(151, 76)
$header.Controls.Add($hintLabel)

$projectLabel = New-Object System.Windows.Forms.Label
$projectLabel.Text = '导入两个视频，在软件里粘贴配音稿，再选择时长、声音和音乐'
$projectLabel.ForeColor = $deepBlue
$projectLabel.AutoSize = $true
$projectLabel.Location = New-Object System.Drawing.Point(28, 157)
$form.Controls.Add($projectLabel)

$projectTextBox = New-Object System.Windows.Forms.TextBox
$projectTextBox.Text = $defaultProject
$projectTextBox.ReadOnly = $true
$projectTextBox.BackColor = $white
$projectTextBox.Location = New-Object System.Drawing.Point(31, 184)
$projectTextBox.Size = New-Object System.Drawing.Size(735, 30)
$projectTextBox.Anchor = 'Top, Left, Right'
$projectTextBox.Visible = $false
$form.Controls.Add($projectTextBox)

$browseButton = New-Object System.Windows.Forms.Button
$browseButton.Text = '切换模板'
$browseButton.Location = New-Object System.Drawing.Point(780, 181)
$browseButton.Size = New-Object System.Drawing.Size(92, 36)
$browseButton.Anchor = 'Top, Right'
$browseButton.Visible = $false
Style-UtilityButton $browseButton
$form.Controls.Add($browseButton)

$dropPanel = New-Object System.Windows.Forms.Panel
$dropPanel.Location = New-Object System.Drawing.Point(31, 181)
$dropPanel.Size = New-Object System.Drawing.Size(1058, 48)
$dropPanel.Anchor = 'Top, Left, Right'
$dropPanel.BackColor = $white
$dropPanel.BorderStyle = 'FixedSingle'
$dropPanel.AllowDrop = $true
$form.Controls.Add($dropPanel)

$dropLabel = New-Object System.Windows.Forms.Label
$dropLabel.Text = 'A段视频：拖到这里或点击选择'
$dropLabel.ForeColor = $blue
$dropLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 11, [System.Drawing.FontStyle]::Bold)
$dropLabel.TextAlign = 'MiddleCenter'
$dropLabel.Location = New-Object System.Drawing.Point(0, 0)
$dropLabel.Size = New-Object System.Drawing.Size(528, 46)
$dropLabel.AllowDrop = $true
$dropLabel.Cursor = [Windows.Forms.Cursors]::Hand
$dropPanel.Controls.Add($dropLabel)

$dropLabelB = New-Object System.Windows.Forms.Label
$dropLabelB.Text = 'B段视频：拖到这里或点击选择'
$dropLabelB.ForeColor = $blue
$dropLabelB.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 11, [System.Drawing.FontStyle]::Bold)
$dropLabelB.TextAlign = 'MiddleCenter'
$dropLabelB.Location = New-Object System.Drawing.Point(529, 0)
$dropLabelB.Size = New-Object System.Drawing.Size(527, 46)
$dropLabelB.BorderStyle = 'FixedSingle'
$dropLabelB.AllowDrop = $true
$dropLabelB.Cursor = [Windows.Forms.Cursors]::Hand
$dropPanel.Controls.Add($dropLabelB)
$script:singleAPath = ''
$script:singleBPath = ''

$flowPanel = New-Object System.Windows.Forms.TableLayoutPanel
$flowPanel.ColumnCount = 3
$flowPanel.RowCount = 1
$flowPanel.Location = New-Object System.Drawing.Point(31, 244)
$flowPanel.Size = New-Object System.Drawing.Size(1058, 112)
$flowPanel.Anchor = 'Top, Left, Right'
$flowPanel.BackColor = $lightBlue
0..2 | ForEach-Object { $flowPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 33.333))) }
$form.Controls.Add($flowPanel)

$importButton = New-Object System.Windows.Forms.Button
$importButton.Text = "1`r`n导入素材"
$importButton.Dock = 'Fill'
$importButton.Margin = New-Object System.Windows.Forms.Padding(0, 0, 10, 0)
Style-MainButton $importButton $blue
$flowPanel.Controls.Add($importButton, 0, 0)

$previewButton = New-Object System.Windows.Forms.Button
$previewButton.Text = "2`r`n可选预览"
$previewButton.Dock = 'Fill'
$previewButton.Margin = New-Object System.Windows.Forms.Padding(4, 0, 10, 0)
Style-MainButton $previewButton $blue
$flowPanel.Controls.Add($previewButton, 1, 0)

$approveButton = New-Object System.Windows.Forms.Button
$approveButton.Text = "3`r`n审核确认"
$approveButton.Dock = 'Fill'
$approveButton.Margin = New-Object System.Windows.Forms.Padding(4, 0, 10, 0)
Style-MainButton $approveButton $mutedBlue
$approveButton.Visible = $false

$finalButton = New-Object System.Windows.Forms.Button
$finalButton.Text = "3`r`n自动完成剪辑"
$finalButton.Dock = 'Fill'
$finalButton.Margin = New-Object System.Windows.Forms.Padding(4, 0, 0, 0)
Style-MainButton $finalButton $mutedBlue
$flowPanel.Controls.Add($finalButton, 2, 0)

$voicePanel = New-Object System.Windows.Forms.Panel
$voicePanel.Location = New-Object System.Drawing.Point(31, 374)
$voicePanel.Size = New-Object System.Drawing.Size(1058, 82)
$voicePanel.Anchor = 'Top, Left, Right'
$voicePanel.BackColor = $white
$form.Controls.Add($voicePanel)

$voiceModeLabel = New-Object System.Windows.Forms.Label
$voiceModeLabel.Text = '人声方式'
$voiceModeLabel.ForeColor = $deepBlue
$voiceModeLabel.AutoSize = $true
$voiceModeLabel.Location = New-Object System.Drawing.Point(18, 29)
$voicePanel.Controls.Add($voiceModeLabel)

$aiRadio = New-Object System.Windows.Forms.RadioButton
$aiRadio.Text = '自然AI配音'
$aiRadio.Location = New-Object System.Drawing.Point(100, 25)
$aiRadio.Size = New-Object System.Drawing.Size(118, 30)
$aiRadio.Checked = $true
$voicePanel.Controls.Add($aiRadio)

$humanRadio = New-Object System.Windows.Forms.RadioButton
$humanRadio.Text = '真人录音'
$humanRadio.Location = New-Object System.Drawing.Point(220, 25)
$humanRadio.Size = New-Object System.Drawing.Size(100, 30)
$voicePanel.Controls.Add($humanRadio)

$voiceCombo = New-Object System.Windows.Forms.ComboBox
$voiceCombo.DropDownStyle = 'DropDownList'
$voiceCombo.Items.AddRange(@('温柔生活女声', '温柔成熟女声', '自然青年男声', '活力运动男声', '专业新闻男声', '可爱年轻男声'))
$voiceCombo.SelectedIndex = 0
$voiceCombo.Location = New-Object System.Drawing.Point(326, 25)
$voiceCombo.Size = New-Object System.Drawing.Size(170, 30)
$voicePanel.Controls.Add($voiceCombo)

$auditionButton = New-Object System.Windows.Forms.Button
$auditionButton.Text = '试听并选择'
$auditionButton.Location = New-Object System.Drawing.Point(512, 20)
$auditionButton.Size = New-Object System.Drawing.Size(120, 40)
Style-UtilityButton $auditionButton
$voicePanel.Controls.Add($auditionButton)

$recordingButton = New-Object System.Windows.Forms.Button
$recordingButton.Text = '选择真人录音'
$recordingButton.Location = New-Object System.Drawing.Point(648, 20)
$recordingButton.Size = New-Object System.Drawing.Size(145, 40)
Style-UtilityButton $recordingButton
$voicePanel.Controls.Add($recordingButton)

$voiceStatusLabel = New-Object System.Windows.Forms.Label
$voiceStatusLabel.Text = 'AI配音优先 · 背景音乐自动压低'
$voiceStatusLabel.ForeColor = $mutedBlue
$voiceStatusLabel.AutoSize = $true
$voiceStatusLabel.Location = New-Object System.Drawing.Point(810, 30)
$voicePanel.Controls.Add($voiceStatusLabel)

$settingsPanel = New-Object System.Windows.Forms.Panel
$settingsPanel.Location = New-Object System.Drawing.Point(31, 470)
$settingsPanel.Size = New-Object System.Drawing.Size(1058, 76)
$settingsPanel.Anchor = 'Top, Left, Right'
$settingsPanel.BackColor = $white
$form.Controls.Add($settingsPanel)

$voiceButton = New-Object System.Windows.Forms.Button
$voiceButton.Text = '输入配音稿'
$voiceButton.Location = New-Object System.Drawing.Point(18, 18)
$voiceButton.Size = New-Object System.Drawing.Size(145, 40)
Style-UtilityButton $voiceButton
$settingsPanel.Controls.Add($voiceButton)

$configButton = New-Object System.Windows.Forms.Button
$configButton.Text = '音乐与声音设置'
$configButton.Location = New-Object System.Drawing.Point(181, 18)
$configButton.Size = New-Object System.Drawing.Size(160, 40)
Style-UtilityButton $configButton
$settingsPanel.Controls.Add($configButton)

$outputButton = New-Object System.Windows.Forms.Button
$outputButton.Text = '播放最新视频'
$outputButton.Location = New-Object System.Drawing.Point(359, 18)
$outputButton.Size = New-Object System.Drawing.Size(160, 40)
Style-UtilityButton $outputButton
$settingsPanel.Controls.Add($outputButton)

$logButton = New-Object System.Windows.Forms.Button
$logButton.Text = '打开成片文件夹'
$logButton.Location = New-Object System.Drawing.Point(537, 18)
$logButton.Size = New-Object System.Drawing.Size(145, 40)
Style-UtilityButton $logButton
$settingsPanel.Controls.Add($logButton)

$preflightButton = New-Object System.Windows.Forms.Button
$preflightButton.Text = '生成前体检'
$preflightButton.Location = New-Object System.Drawing.Point(700, 18)
$preflightButton.Size = New-Object System.Drawing.Size(145, 40)
Style-UtilityButton $preflightButton
$settingsPanel.Controls.Add($preflightButton)

$selfTestButton = New-Object System.Windows.Forms.Button
$selfTestButton.Text = '程序自检'
$selfTestButton.Location = New-Object System.Drawing.Point(863, 18)
$selfTestButton.Size = New-Object System.Drawing.Size(145, 40)
Style-UtilityButton $selfTestButton
$settingsPanel.Controls.Add($selfTestButton)

$companyPanel = New-Object System.Windows.Forms.Panel
$companyPanel.Location = New-Object System.Drawing.Point(31, 560)
$companyPanel.Size = New-Object System.Drawing.Size(1058, 76)
$companyPanel.Anchor = 'Top, Left, Right'
$companyPanel.BackColor = $white
$form.Controls.Add($companyPanel)

$batchButton = New-Object System.Windows.Forms.Button
$batchButton.Text = '批量生产中心'
$batchButton.Location = New-Object System.Drawing.Point(18, 18)
$batchButton.Size = New-Object System.Drawing.Size(160, 40)
Style-MainButton $batchButton $deepBlue
$companyPanel.Controls.Add($batchButton)

$complianceButton = New-Object System.Windows.Forms.Button
$complianceButton.Text = '文案合规初审'
$complianceButton.Location = New-Object System.Drawing.Point(194, 18)
$complianceButton.Size = New-Object System.Drawing.Size(160, 40)
Style-UtilityButton $complianceButton
$companyPanel.Controls.Add($complianceButton)

$qualityButton = New-Object System.Windows.Forms.Button
$qualityButton.Text = '查看质量报告'
$qualityButton.Location = New-Object System.Drawing.Point(370, 18)
$qualityButton.Size = New-Object System.Drawing.Size(160, 40)
Style-UtilityButton $qualityButton
$companyPanel.Controls.Add($qualityButton)

$platformLabel = New-Object System.Windows.Forms.Label
$platformLabel.Text = '导出平台'
$platformLabel.ForeColor = $deepBlue
$platformLabel.AutoSize = $true
$platformLabel.Location = New-Object System.Drawing.Point(558, 29)
$companyPanel.Controls.Add($platformLabel)

$platformCombo = New-Object System.Windows.Forms.ComboBox
$platformCombo.DropDownStyle = 'DropDownList'
$platformCombo.Items.AddRange(@('通用高清', '抖音', '视频号', '小红书', '全部平台'))
$platformCombo.SelectedIndex = 0
$platformCombo.Location = New-Object System.Drawing.Point(638, 24)
$platformCombo.Size = New-Object System.Drawing.Size(145, 30)
$companyPanel.Controls.Add($platformCombo)

$platformHint = New-Object System.Windows.Forms.Label
$platformHint.Text = '正式生成时使用 · 1080×1920竖屏'
$platformHint.ForeColor = $mutedBlue
$platformHint.AutoSize = $true
$platformHint.Location = New-Object System.Drawing.Point(804, 29)
$companyPanel.Controls.Add($platformHint)

$statusPanel = New-Object System.Windows.Forms.Panel
$statusPanel.Location = New-Object System.Drawing.Point(31, 650)
$statusPanel.Size = New-Object System.Drawing.Size(1058, 158)
$statusPanel.Anchor = 'Top, Left, Right'
$statusPanel.BackColor = $white
$form.Controls.Add($statusPanel)

$statusTitle = New-Object System.Windows.Forms.Label
$statusTitle.Text = '当前状态'
$statusTitle.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 11, [System.Drawing.FontStyle]::Bold)
$statusTitle.ForeColor = $deepBlue
$statusTitle.AutoSize = $true
$statusTitle.Location = New-Object System.Drawing.Point(20, 17)
$statusPanel.Controls.Add($statusTitle)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = '把A段、B段和配音稿拖入上方区域'
$statusLabel.ForeColor = $mutedBlue
$statusLabel.AutoSize = $true
$statusLabel.Location = New-Object System.Drawing.Point(20, 52)
$statusPanel.Controls.Add($statusLabel)

$qualityLabel = New-Object System.Windows.Forms.Label
$qualityLabel.Text = '正式成片：1080×1920 · H.264 高画质 · 从原素材重新渲染'
$qualityLabel.ForeColor = $mutedBlue
$qualityLabel.AutoSize = $true
$qualityLabel.Location = New-Object System.Drawing.Point(20, 82)
$statusPanel.Controls.Add($qualityLabel)

$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Location = New-Object System.Drawing.Point(20, 116)
$progressBar.Size = New-Object System.Drawing.Size(840, 23)
$progressBar.Minimum = 0
$progressBar.Maximum = 100
$statusPanel.Controls.Add($progressBar)

$retryButton = New-Object System.Windows.Forms.Button
$retryButton.Text = '失败后重试'
$retryButton.Location = New-Object System.Drawing.Point(883, 106)
$retryButton.Size = New-Object System.Drawing.Size(145, 40)
$retryButton.Enabled = $false
Style-UtilityButton $retryButton
$statusPanel.Controls.Add($retryButton)

$hideWindowButton = New-Object System.Windows.Forms.Button
$hideWindowButton.Text = '隐藏到任务栏'
$hideWindowButton.Location = New-Object System.Drawing.Point(883, 18)
$hideWindowButton.Size = New-Object System.Drawing.Size(145, 40)
Style-UtilityButton $hideWindowButton
$hideWindowButton.Add_Click({ $form.WindowState = [System.Windows.Forms.FormWindowState]::Minimized })
$statusPanel.Controls.Add($hideWindowButton)

# 简洁主页：旧的高级面板继续保留在代码中，主页不再展示。
$flowPanel.Visible = $false
$voicePanel.Visible = $false
$settingsPanel.Visible = $false
$companyPanel.Visible = $false

$scriptPanel = New-Object System.Windows.Forms.Panel
$scriptPanel.Location = New-Object System.Drawing.Point(31, 244)
$scriptPanel.Size = New-Object System.Drawing.Size(1058, 150)
$scriptPanel.BackColor = $white
$form.Controls.Add($scriptPanel)
$scriptTitle = New-Object System.Windows.Forms.Label
$scriptTitle.Text = '配音稿（直接粘贴，按自然停顿分行）'
$scriptTitle.AutoSize = $true; $scriptTitle.ForeColor = $deepBlue; $scriptTitle.Location = New-Object System.Drawing.Point(18, 12); $scriptPanel.Controls.Add($scriptTitle)
$productNameSimpleLabel=New-Object Windows.Forms.Label;$productNameSimpleLabel.Text='产品名称';$productNameSimpleLabel.AutoSize=$true;$productNameSimpleLabel.Location=New-Object Drawing.Point(515,12);$scriptPanel.Controls.Add($productNameSimpleLabel)
$productNameSimple=New-Object Windows.Forms.TextBox;$productNameSimple.Location=New-Object Drawing.Point(590,7);$productNameSimple.Size=New-Object Drawing.Size(175,28);$productNameSimple.Text=[string](Get-Config $builtInProject).productName;$scriptPanel.Controls.Add($productNameSimple)
$coverFontSimpleLabel=New-Object Windows.Forms.Label;$coverFontSimpleLabel.Text='封面字体';$coverFontSimpleLabel.AutoSize=$true;$coverFontSimpleLabel.Location=New-Object Drawing.Point(780,12);$scriptPanel.Controls.Add($coverFontSimpleLabel)
$coverFontSimple=New-Object Windows.Forms.ComboBox;$coverFontSimple.DropDownStyle='DropDownList';[void]$coverFontSimple.Items.AddRange(@('站酷快乐体（推荐）','得意黑','醒目粗黑','思源黑体','微软雅黑','经典黑体'));$savedCoverFont=if($simpleConfig.cover -and $simpleConfig.cover.fontStyle){[string]$simpleConfig.cover.fontStyle}else{'站酷快乐体'};$displayCoverFont=if($savedCoverFont -eq '站酷快乐体'){'站酷快乐体（推荐）'}else{$savedCoverFont};$coverFontSimple.SelectedItem=$displayCoverFont;if($coverFontSimple.SelectedIndex -lt 0){$coverFontSimple.SelectedIndex=0};$coverFontSimple.Location=New-Object Drawing.Point(850,7);$coverFontSimple.Size=New-Object Drawing.Size(190,28);$scriptPanel.Controls.Add($coverFontSimple)
$scriptBox = New-Object System.Windows.Forms.TextBox
$scriptBox.Multiline = $true; $scriptBox.ScrollBars = 'Vertical'; $scriptBox.AcceptsReturn = $true
$scriptBox.Location = New-Object System.Drawing.Point(18, 40); $scriptBox.Size = New-Object System.Drawing.Size(1022, 94)
$transcriptFile = Join-Path $builtInProject '配音稿.txt'
if (Test-Path -LiteralPath $transcriptFile) { $scriptBox.Text = Get-Content -LiteralPath $transcriptFile -Raw -Encoding UTF8 }
$scriptPanel.Controls.Add($scriptBox)

$simpleOptions = New-Object System.Windows.Forms.Panel
$simpleOptions.Location = New-Object System.Drawing.Point(31, 406)
$simpleOptions.Size = New-Object System.Drawing.Size(1058, 88)
$simpleOptions.BackColor = $white
$form.Controls.Add($simpleOptions)
$simpleConfig = Get-Config $builtInProject

$durationSimpleLabel = New-Object Windows.Forms.Label; $durationSimpleLabel.Text='时长'; $durationSimpleLabel.AutoSize=$true; $durationSimpleLabel.Location=New-Object Drawing.Point(18,34); $simpleOptions.Controls.Add($durationSimpleLabel)
$durationSimple = New-Object Windows.Forms.ComboBox; $durationSimple.DropDownStyle='DropDownList'; [void]$durationSimple.Items.AddRange(@('15秒','20秒')); $durationSimple.SelectedItem=([string]$simpleConfig.duration.targetSeconds+'秒'); if($durationSimple.SelectedIndex -lt 0){$durationSimple.SelectedIndex=0}; $durationSimple.Location=New-Object Drawing.Point(62,28); $durationSimple.Size=New-Object Drawing.Size(95,30); $simpleOptions.Controls.Add($durationSimple)

$voiceSimpleLabel = New-Object Windows.Forms.Label; $voiceSimpleLabel.Text='AI声音'; $voiceSimpleLabel.AutoSize=$true; $voiceSimpleLabel.Location=New-Object Drawing.Point(170,34); $simpleOptions.Controls.Add($voiceSimpleLabel)
$aiToggleSimple = New-Object Windows.Forms.Button; $aiToggleSimple.Tag=($simpleConfig.voiceover.mode -ne 'source'); $aiToggleSimple.Location=New-Object Drawing.Point(228,24); $aiToggleSimple.Size=New-Object Drawing.Size(78,38); Style-UtilityButton $aiToggleSimple; $simpleOptions.Controls.Add($aiToggleSimple)
$voiceSimple = New-Object Windows.Forms.ComboBox; $voiceSimple.DropDownStyle='DropDownList'; [void]$voiceSimple.Items.Add('随机声音'); Get-AiVoiceCatalog | ForEach-Object {[void]$voiceSimple.Items.Add($_.Name)}; $voiceSimple.SelectedIndex=if($simpleConfig.voiceover.selectionMode -eq 'random'){0}else{1}; $voiceSimple.Location=New-Object Drawing.Point(312,28); $voiceSimple.Size=New-Object Drawing.Size(130,30); $simpleOptions.Controls.Add($voiceSimple)
$voiceListenSimple = New-Object Windows.Forms.Button; $voiceListenSimple.Text='试听'; $voiceListenSimple.Location=New-Object Drawing.Point(448,24); $voiceListenSimple.Size=New-Object Drawing.Size(58,38); Style-UtilityButton $voiceListenSimple; $simpleOptions.Controls.Add($voiceListenSimple)
$updateSimpleAiToggle={if([bool]$aiToggleSimple.Tag){$aiToggleSimple.Text='AI已开启';$voiceSimple.Enabled=$true;$voiceListenSimple.Enabled=$true}else{$aiToggleSimple.Text='AI已关闭';$voiceSimple.Enabled=$false;$voiceListenSimple.Enabled=$false}}; &$updateSimpleAiToggle
$aiToggleSimple.Add_Click({$aiToggleSimple.Tag=-not [bool]$aiToggleSimple.Tag;&$updateSimpleAiToggle})

$musicSimpleLabel = New-Object Windows.Forms.Label; $musicSimpleLabel.Text='音乐'; $musicSimpleLabel.AutoSize=$true; $musicSimpleLabel.Location=New-Object Drawing.Point(514,34); $simpleOptions.Controls.Add($musicSimpleLabel)
$musicSimple = New-Object Windows.Forms.ComboBox; $musicSimple.DropDownStyle='DropDownList'; [void]$musicSimple.Items.AddRange(@('关闭音乐','随机音乐','顺序轮换')); Get-ChildItem -LiteralPath (Join-Path $builtInProject 'public\music') -File | Where-Object {$_.Extension -match '^\.(wav|mp3)$'} | ForEach-Object {[void]$musicSimple.Items.Add($_.BaseName)}; $musicSimple.SelectedIndex=if($simpleConfig.music.mode -eq 'off'){0}elseif($simpleConfig.music.selectionMode -eq 'rotate'){2}elseif($simpleConfig.music.selectionMode -eq 'random'){1}else{3}; $musicSimple.Location=New-Object Drawing.Point(554,28); $musicSimple.Size=New-Object Drawing.Size(126,30); $simpleOptions.Controls.Add($musicSimple)
if($simpleConfig.music.selectionMode -eq 'fixed' -and $simpleConfig.music.sourcePath){$configuredMusic=[IO.Path]::GetFileNameWithoutExtension([string]$simpleConfig.music.sourcePath);if($musicSimple.Items.Contains($configuredMusic)){$musicSimple.SelectedItem=$configuredMusic}}
$musicListenSimple = New-Object Windows.Forms.Button; $musicListenSimple.Text='试听'; $musicListenSimple.Location=New-Object Drawing.Point(686,24); $musicListenSimple.Size=New-Object Drawing.Size(58,38); Style-UtilityButton $musicListenSimple; $simpleOptions.Controls.Add($musicListenSimple)

$captionSimpleLabel = New-Object Windows.Forms.Label; $captionSimpleLabel.Text='位置'; $captionSimpleLabel.AutoSize=$true; $captionSimpleLabel.Location=New-Object Drawing.Point(752,34); $simpleOptions.Controls.Add($captionSimpleLabel)
$captionSimple = New-Object Windows.Forms.ComboBox; $captionSimple.DropDownStyle='DropDownList'; [void]$captionSimple.Items.AddRange(@('偏下','居中偏下','居中')); $captionSimple.SelectedIndex=if([int]$simpleConfig.captions.bottom -ge 330){2}elseif([int]$simpleConfig.captions.bottom -ge 220){1}else{0}; $captionSimple.Location=New-Object Drawing.Point(794,28); $captionSimple.Size=New-Object Drawing.Size(96,30); $simpleOptions.Controls.Add($captionSimple)
$captionStyleSimpleLabel = New-Object Windows.Forms.Label; $captionStyleSimpleLabel.Text='字体'; $captionStyleSimpleLabel.AutoSize=$true; $captionStyleSimpleLabel.Location=New-Object Drawing.Point(898,34); $simpleOptions.Controls.Add($captionStyleSimpleLabel)
$captionStyleSimple = New-Object Windows.Forms.ComboBox; $captionStyleSimple.DropDownStyle='DropDownList'; [void]$captionStyleSimple.Items.AddRange(@('现有黄字','粗白字黑边')); $captionStyleSimple.SelectedIndex=if([string]$simpleConfig.captions.color -eq '#FFFFFF'){1}else{0}; $captionStyleSimple.Location=New-Object Drawing.Point(940,28); $captionStyleSimple.Size=New-Object Drawing.Size(99,30); $simpleOptions.Controls.Add($captionStyleSimple)

$simpleActions = New-Object System.Windows.Forms.Panel
$simpleActions.Location = New-Object System.Drawing.Point(31, 506)
$simpleActions.Size = New-Object System.Drawing.Size(1058, 66)
$simpleActions.BackColor = $white
$form.Controls.Add($simpleActions)
$simpleImport = New-Object Windows.Forms.Button; $simpleImport.Visible=$false
$simpleGenerate = New-Object Windows.Forms.Button; $simpleGenerate.Text='开始制作这个视频'; $simpleGenerate.Location=New-Object Drawing.Point(18,8); $simpleGenerate.Size=New-Object Drawing.Size(700,50); Style-MainButton $simpleGenerate $blue; $simpleActions.Controls.Add($simpleGenerate)
$simpleBatch = New-Object Windows.Forms.Button; $simpleBatch.Text='批量制作多个视频'; $simpleBatch.Location=New-Object Drawing.Point(738,8); $simpleBatch.Size=New-Object Drawing.Size(302,50); Style-UtilityButton $simpleBatch; $simpleActions.Controls.Add($simpleBatch)
$simpleOpen = New-Object Windows.Forms.Button; $simpleOpen.Text='查看生成的视频'; $simpleOpen.Location=New-Object Drawing.Point(690,9); $simpleOpen.Size=New-Object Drawing.Size(170,38); Style-UtilityButton $simpleOpen

$outputPanelSimple = New-Object System.Windows.Forms.Panel
$outputPanelSimple.Location = New-Object System.Drawing.Point(31, 584)
$outputPanelSimple.Size = New-Object System.Drawing.Size(1058, 56)
$outputPanelSimple.BackColor = $white
$form.Controls.Add($outputPanelSimple)
$outputTitleSimple = New-Object Windows.Forms.Label; $outputTitleSimple.Text='生成完成后，可以在这里播放或查看视频'; $outputTitleSimple.AutoSize=$true; $outputTitleSimple.ForeColor=$deepBlue; $outputTitleSimple.Location=New-Object Drawing.Point(18,19); $outputPanelSimple.Controls.Add($outputTitleSimple)
$outputPathSimple = New-Object Windows.Forms.TextBox; $outputPathSimple.Visible=$false
$outputPanelSimple.Controls.Add($simpleOpen)
$playOutputSimple = New-Object Windows.Forms.Button; $playOutputSimple.Text='播放刚生成的视频'; $playOutputSimple.Location=New-Object Drawing.Point(878,9); $playOutputSimple.Size=New-Object Drawing.Size(164,38); Style-UtilityButton $playOutputSimple; $outputPanelSimple.Controls.Add($playOutputSimple)

$statusPanel.Location = New-Object System.Drawing.Point(31, 650)

function Refresh-State {
    $folder = Get-ProjectFolder
    $latestOutput = Find-LatestPlayableVideo $folder
    $outputPathSimple.Text = if($latestOutput){$latestOutput.FullName}else{'尚未生成成品'}
    $previewReady = $false
    $approved = $false
    if (Test-Path -LiteralPath $folder -PathType Container) {
        $previewReady = Test-Path -LiteralPath (Get-PreviewMarker $folder)
        $approved = Test-Path -LiteralPath (Get-ApprovedMarker $folder)
    }
    $approveButton.Enabled = $previewReady
    $finalButton.Enabled = $true
    $approveButton.BackColor = if ($previewReady) { $blue } else { $mutedBlue }
    $finalButton.BackColor = $blue
    if ($approved) {
        $statusLabel.Text = '审核已通过，可以正式生成高清成片'
    } elseif ($previewReady) {
        $statusLabel.Text = '预览已生成，请点击“审核确认”完整查看'
    }
}

$browseButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = '仅在切换完整制作模板时使用。普通素材请点击“导入素材”。'
    $dialog.SelectedPath = Get-ProjectFolder
    if ($dialog.ShowDialog() -eq 'OK') {
        $selectedConfig = Join-Path $dialog.SelectedPath 'video.config.json'
        $selectedPackage = Join-Path $dialog.SelectedPath 'package.json'
        $selectedVoice = Join-Path $dialog.SelectedPath '配音稿.txt'
        if ((Test-Path -LiteralPath $selectedConfig) -and (Test-Path -LiteralPath $selectedPackage) -and (Test-Path -LiteralPath $selectedVoice)) {
            $projectTextBox.Text = $dialog.SelectedPath
            Save-ProjectFolder $dialog.SelectedPath
            $statusLabel.Text = '已切换制作模板：' + (Split-Path -Leaf $dialog.SelectedPath)
            Refresh-State
        } else {
            Show-Info "你选择的是普通素材文件夹，不是制作模板。`r`n`r`n程序仍使用默认模板；请直接点击“1 导入素材”，依次选择 A 段和 B 段视频。"
        }
    }
})

$importButton.Add_Click({
    $folder = Get-ProjectFolder
    if (-not (Test-VideoProject $folder)) { return }
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = '同时选择 A 段和 B 段视频'
    $dialog.Filter = '视频文件|*.mp4;*.mov;*.mkv;*.avi;*.webm|所有文件|*.*'
    $dialog.Multiselect = $true
    if ($dialog.ShowDialog() -eq 'OK') { Handle-DroppedFiles $dialog.FileNames }
})

$dragEnterHandler = {
    param($sender, $eventArgs)
    if ($eventArgs.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) {
        $eventArgs.Effect = [System.Windows.Forms.DragDropEffects]::Copy
    } else {
        $eventArgs.Effect = [System.Windows.Forms.DragDropEffects]::None
    }
}
$dragDropHandler = {
    param($sender, $eventArgs)
    $paths = [string[]]$eventArgs.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop)
    Handle-DroppedFiles $paths
}
$form.Add_DragEnter($dragEnterHandler)
$form.Add_DragDrop($dragDropHandler)
$singleVideoDragEnter = { param($sender,$eventArgs) if($eventArgs.Data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop)){$eventArgs.Effect='Copy'}else{$eventArgs.Effect='None'} }
$setSingleSegment = {
    param([string]$kind,[string]$path)
    $extension=[IO.Path]::GetExtension($path).ToLowerInvariant()
    if(@('.mp4','.mov','.mkv','.avi','.webm') -notcontains $extension){throw '这里只能放入视频文件。'}
    if($kind -eq 'A'){$script:singleAPath=$path;$dropLabel.Text="A段 已选择：$([IO.Path]::GetFileName($path))"}else{$script:singleBPath=$path;$dropLabelB.Text="B段 已选择：$([IO.Path]::GetFileName($path))"}
    if($script:singleAPath -and $script:singleBPath){Import-Videos @($script:singleAPath,$script:singleBPath)|Out-Null;$statusLabel.Text='A段和B段已准备好，可以开始制作。'}
}
$dropLabel.Add_DragEnter($singleVideoDragEnter); $dropLabelB.Add_DragEnter($singleVideoDragEnter)
$dropLabel.Add_DragDrop({param($s,$e) try{$p=@([string[]]$e.Data.GetData([Windows.Forms.DataFormats]::FileDrop))[0];&$setSingleSegment 'A' $p}catch{Show-Error $_.Exception.Message}})
$dropLabelB.Add_DragDrop({param($s,$e) try{$p=@([string[]]$e.Data.GetData([Windows.Forms.DataFormats]::FileDrop))[0];&$setSingleSegment 'B' $p}catch{Show-Error $_.Exception.Message}})
$dropLabel.Add_Click({$d=New-Object Windows.Forms.OpenFileDialog;$d.Title='选择A段视频';$d.Filter='视频文件|*.mp4;*.mov;*.mkv;*.avi;*.webm';if($d.ShowDialog() -eq 'OK'){try{&$setSingleSegment 'A' $d.FileName}catch{Show-Error $_.Exception.Message}}})
$dropLabelB.Add_Click({$d=New-Object Windows.Forms.OpenFileDialog;$d.Title='选择B段视频';$d.Filter='视频文件|*.mp4;*.mov;*.mkv;*.avi;*.webm';if($d.ShowDialog() -eq 'OK'){try{&$setSingleSegment 'B' $d.FileName}catch{Show-Error $_.Exception.Message}}})

$initializingVoiceControls = $true
$voiceCombo.Add_SelectedIndexChanged({
    if ($initializingVoiceControls) { return }
    try {
        $folder = Get-ProjectFolder
        $config = Get-Config $folder
        $voiceMap = @{
            '温柔生活女声' = @('zh-CN-XiaoyiNeural', '+28%', '-2Hz')
            '温柔成熟女声' = @('zh-CN-XiaoxiaoNeural', '+28%', '-3Hz')
            '自然青年男声' = @('zh-CN-YunxiNeural', '+28%', '-2Hz')
            '活力运动男声' = @('zh-CN-YunjianNeural', '+24%', '-2Hz')
            '专业新闻男声' = @('zh-CN-YunyangNeural', '+22%', '-2Hz')
            '可爱年轻男声' = @('zh-CN-YunxiaNeural', '+26%', '+1Hz')
        }
        $voiceSettings = $voiceMap[$voiceCombo.SelectedItem.ToString()]
        $config.voiceover.voice = $voiceSettings[0]
        $config.voiceover.rate = $voiceSettings[1]
        $config.voiceover.pitch = $voiceSettings[2]
        $config.voiceover.mode = 'ai'
        Save-Config $folder $config
        $aiRadio.Checked = $true
        Reset-ReviewState $folder
        $voiceStatusLabel.Text = '已选择：' + $voiceCombo.SelectedItem.ToString()
    } catch { Show-Error $_.Exception.Message }
})

$aiRadio.Add_CheckedChanged({
    if ($initializingVoiceControls) { return }
    if (-not $aiRadio.Checked) { return }
    try {
        $config = Get-Config (Get-ProjectFolder)
        $config.voiceover.mode = 'ai'
        Save-Config (Get-ProjectFolder) $config
        Reset-ReviewState (Get-ProjectFolder)
        $voiceStatusLabel.Text = '使用自然AI配音 · 音量75%'
    } catch { Show-Error $_.Exception.Message }
})

$humanRadio.Add_CheckedChanged({
    if ($initializingVoiceControls) { return }
    if (-not $humanRadio.Checked) { return }
    try {
        $config = Get-Config (Get-ProjectFolder)
        if (-not $config.voiceover.humanAudioPath) {
            $humanRadio.Checked = $false
            $aiRadio.Checked = $true
            Show-Info '请先拖入真人录音，或点击“选择真人录音”。'
            return
        }
        $config.voiceover.mode = 'human'
        Save-Config (Get-ProjectFolder) $config
        Reset-ReviewState (Get-ProjectFolder)
        $voiceStatusLabel.Text = '使用真人录音 · 字幕按语句自动匹配'
    } catch { Show-Error $_.Exception.Message }
})

$recordingButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = '选择真人录音'
    $dialog.Filter = '音频文件|*.mp3;*.wav;*.m4a;*.aac;*.flac|所有文件|*.*'
    if ($dialog.ShowDialog() -eq 'OK') {
        try {
            $name = Import-VoiceAudio $dialog.FileName
            $humanRadio.Checked = $true
            $voiceStatusLabel.Text = "真人录音：$name"
            Show-Info '真人录音已导入。生成预览后请检查字幕时机。'
        } catch { Show-Error $_.Exception.Message }
    }
})

$auditionButton.Add_Click({
    try { Show-VoicePicker } catch { Show-Error $_.Exception.Message }
})

$previewButton.Add_Click({
    $folder = Get-ProjectFolder
    if (-not (Test-VideoProject $folder)) { return }
    try { Invoke-ProgramSelfTest $false | Out-Null } catch { Show-Error $_.Exception.Message; return }
    try { Invoke-Preflight $folder 'Preview' 'universal' $false | Out-Null } catch { Show-Error $_.Exception.Message; return }
    Reset-ReviewState $folder
    Start-Worker $folder 'Preview'
    $statusLabel.Text = '正在后台生成预览，请保持电脑开机'
    Refresh-State
    Show-Info '预览已开始生成。完成后会自动提示，再点击“审核确认”。'
})

$approveButton.Add_Click({
    $folder = Get-ProjectFolder
    $preview = Find-Preview $folder
    if (-not $preview) {
        Show-Error '找不到预览视频，请重新生成预览。'
        return
    }

    Show-Info '预览将在程序内播放。请完整检查画面、原人声、配音、字幕和音乐。'
    Show-EmbeddedPreview $preview.FullName
    $result = [System.Windows.Forms.MessageBox]::Show(
        '预览是否审核通过？`r`n`r`n选择“是”后才允许正式生成。',
        '审核确认',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )
    if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
        $stateFolder = Get-StateFolder $folder
        New-Item -ItemType Directory -Path $stateFolder -Force | Out-Null
        try { New-ApprovalLock $folder $preview.FullName | Out-Null } catch { Show-Error $_.Exception.Message; return }
        Set-Content -LiteralPath (Get-ApprovedMarker $folder) -Value (Get-Date -Format o) -Encoding UTF8
        $statusLabel.Text = '审核已通过，可以正式生成高清成片'
    } else {
        Remove-Item -LiteralPath (Get-ApprovedMarker $folder) -Force -ErrorAction SilentlyContinue
        $statusLabel.Text = '审核未通过，请调整后重新生成预览'
    }
    Refresh-State
})

$finalButton.Add_Click({
    $folder = Get-ProjectFolder
    try { Invoke-ProgramSelfTest $false | Out-Null } catch { Show-Error $_.Exception.Message; return }
    try {
        $config = Get-Config $folder
        Invoke-Preflight $folder 'Final' ([string]$config.export.platform) $false | Out-Null
    } catch { Show-Error $_.Exception.Message; return }
    Start-Worker $folder 'Final'
    $statusLabel.Text = '正在从原素材正式生成1080×1920高清成片'
    Show-Info "正式高清生成已经开始。`r`n`r`n请保持电脑开机，不要移动素材文件。"
})

$batchButton.Add_Click({ Show-BatchCenter })

$preflightButton.Add_Click({
    try {
        $folder = Get-ProjectFolder
        $config = Get-Config $folder
        Invoke-Preflight $folder 'Final' ([string]$config.export.platform) $true | Out-Null
    } catch { Show-Error $_.Exception.Message }
})

$selfTestButton.Add_Click({
    try { Invoke-ProgramSelfTest $true | Out-Null } catch { Show-Error $_.Exception.Message }
})

$complianceButton.Add_Click({
    try {
        $folder = Get-ProjectFolder
        $node = Get-NodeExecutable $folder
        $result = & $node (Join-Path $folder 'scripts\compliance-check.mjs') 2>&1
        $exitCode = $LASTEXITCODE
        $jsonLine = @($result | Where-Object { $_ -match '^\{' }) | Select-Object -Last 1
        if (-not $jsonLine) { throw ($result -join "`r`n") }
        $report = $jsonLine | ConvertFrom-Json
        $message = if ($report.result -eq 'passed') {
            '文案已通过当前词库初审。发布前仍需人工确认。'
        } elseif ($report.result -eq 'blocked') {
            "发现 $($report.summary.block) 项必须修改内容，正式制作会被自动拦截。"
        } else {
            "发现 $($report.summary.review) 项需要人工复核的内容。"
        }
        Show-Info $message '文案合规初审'
        Start-Process notepad.exe ('"' + $report.textReportPath + '"')
    } catch { Show-Error $_.Exception.Message }
})

$qualityButton.Add_Click({
    try {
        $folder = Get-ProjectFolder
        $reports = Join-Path $folder '输出\审核报告'
        $report = if (Test-Path -LiteralPath $reports) {
            Get-ChildItem -LiteralPath $reports -Filter '*质量检查.txt' -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        } else { $null }
        if (-not $report) { throw '还没有质量检查报告。生成预览或正式成片后会自动创建。' }
        Start-Process notepad.exe ('"' + $report.FullName + '"')
    } catch { Show-Error $_.Exception.Message }
})

$platformCombo.Add_SelectedIndexChanged({
    try {
        $platformMap = @{'通用高清'='universal'; '抖音'='douyin'; '视频号'='wechat'; '小红书'='xiaohongshu'; '全部平台'='all'}
        $config = Get-Config (Get-ProjectFolder)
        if (-not $config.export) {
            $config | Add-Member -NotePropertyName export -NotePropertyValue ([PSCustomObject]@{platform='universal';presets=[PSCustomObject]@{}})
        }
        $config.export.platform = $platformMap[$platformCombo.SelectedItem.ToString()]
        Save-Config (Get-ProjectFolder) $config
        $platformHint.Text = '正式生成：' + $platformCombo.SelectedItem.ToString() + ' · 1080×1920'
    } catch { Show-Error $_.Exception.Message }
})

$voiceButton.Add_Click({
    $folder = Get-ProjectFolder
    if (-not (Test-VideoProject $folder)) { return }
    if ((Show-TranscriptEditor (Join-Path $folder '配音稿.txt')) -eq 'OK') {
        Reset-ReviewState $folder
        $statusLabel.Text = '配音稿已保存，可以生成配音和字幕'
    }
})

$configButton.Add_Click({
    $folder = Get-ProjectFolder
    if (-not (Test-VideoProject $folder)) { return }
    if ((Show-QuickSettings) -eq 'OK') { $statusLabel.Text = '时长、音乐和字幕位置已保存' }
})

$saveSimpleSettings = {
    Save-TranscriptText $scriptBox.Text (Join-Path $builtInProject '配音稿.txt') | Out-Null
    $config = Get-Config $builtInProject
    if(-not $productNameSimple.Text.Trim()){throw '请填写产品名称，例如“牙膏1”或“洗手液1”。'}
    $config.productName=$productNameSimple.Text.Trim()
    if(-not $config.PSObject.Properties['cover']){$config|Add-Member -NotePropertyName cover -NotePropertyValue ([PSCustomObject]@{})}
    if(-not $config.cover.PSObject.Properties['fontStyle']){$config.cover|Add-Member -NotePropertyName fontStyle -NotePropertyValue '醒目粗黑'}
    $config.cover.fontStyle=([string]$coverFontSimple.SelectedItem).Replace('（推荐）','')
    $config.duration.targetSeconds = [int]$durationSimple.SelectedItem.ToString().Replace('秒','')
    if (-not $config.voiceover.PSObject.Properties['selectionMode']) { $config.voiceover | Add-Member -NotePropertyName selectionMode -NotePropertyValue 'fixed' }
    if (-not [bool]$aiToggleSimple.Tag) {
        $config.voiceover.mode = 'source'; $config.voiceover.selectionMode = 'off'
    } elseif ($voiceSimple.SelectedItem -eq '随机声音') {
        $config.voiceover.mode = 'ai'; $config.voiceover.selectionMode = 'random'
    } else {
        $picked = Get-AiVoiceCatalog | Where-Object {$_.Name -eq $voiceSimple.SelectedItem} | Select-Object -First 1
        $config.voiceover.mode = 'ai'; $config.voiceover.selectionMode = 'fixed'; $config.voiceover.voice=$picked.Voice; $config.voiceover.rate=$picked.Rate; $config.voiceover.pitch=$picked.Pitch
    }
    if (-not $config.music.PSObject.Properties['selectionMode']) { $config.music | Add-Member -NotePropertyName selectionMode -NotePropertyValue 'fixed' }
    $musicFiles = @(Get-ChildItem -LiteralPath (Join-Path $builtInProject 'public\music') -File | Where-Object {$_.Extension -match '^\.(wav|mp3)$'} | Sort-Object Name)
    if ($musicSimple.SelectedItem -eq '关闭音乐') { $config.music.mode='off'; $config.music.selectionMode='off'; $config.music.sourcePath='' }
    elseif ($musicSimple.SelectedItem -eq '随机音乐') { $config.music.mode='auto'; $config.music.selectionMode='random'; $config.music.sourcePath='public/music/'+(($musicFiles|Get-Random).Name) }
    elseif ($musicSimple.SelectedItem -eq '顺序轮换') { $config.music.mode='auto'; $config.music.selectionMode='rotate'; $config.music.sourcePath='public/music/'+$musicFiles[0].Name }
    else { $pickedMusic=$musicFiles|Where-Object {$_.BaseName -eq $musicSimple.SelectedItem}|Select-Object -First 1; $config.music.mode='auto'; $config.music.selectionMode='fixed'; $config.music.sourcePath='public/music/'+$pickedMusic.Name }
    $config.captions.bottom = @(150,260,380)[$captionSimple.SelectedIndex]
    if($captionStyleSimple.SelectedIndex -eq 1){$config.captions.fontFamily='Noto Sans SC Black, Microsoft YaHei, sans-serif';$config.captions.color='#FFFFFF';$config.captions.fontWeight=900;$config.captions.strokeWidth=3}else{$config.captions.fontFamily='Microsoft YaHei, sans-serif';$config.captions.color='#FFD83D';$config.captions.fontWeight=800;$config.captions.strokeWidth=2}
    Save-Config $builtInProject $config
}

$simpleImport.Add_Click({
    $dialog=New-Object Windows.Forms.OpenFileDialog;$dialog.Title='同时选择 A 段和 B 段视频';$dialog.Filter='视频文件|*.mp4;*.mov;*.mkv;*.avi;*.webm|所有文件|*.*';$dialog.Multiselect=$true
    if($dialog.ShowDialog() -eq 'OK'){Handle-DroppedFiles $dialog.FileNames}
})
$simpleBatch.Add_Click({ try { & $saveSimpleSettings; Show-BatchCenter } catch { Show-Error $_.Exception.Message } })
$simpleGenerate.Add_Click({
    try {
        if(-not $script:singleAPath -or -not $script:singleBPath){throw '请先分别选择A段和B段视频。文件名不需要包含A或B。'}
        & $saveSimpleSettings
        $config = Get-Config $builtInProject
        if ($config.voiceover.mode -eq 'ai' -and $config.voiceover.selectionMode -eq 'random') { $picked=Set-ResolvedRandomVoice $config; Save-Config $builtInProject $config; $statusLabel.Text='本条视频随机声音：'+$picked.Name }
        Reset-ReviewState $builtInProject
        $folder=Get-ProjectFolder
        Invoke-ProgramSelfTest $false|Out-Null
        $renderConfig=Get-Config $folder
        Invoke-Preflight $folder 'Final' ([string]$renderConfig.export.platform) $false|Out-Null
        Start-Worker $folder 'Final'
        $statusLabel.Text='正在从原素材自动生成高清成片'
    } catch { Show-Error $_.Exception.Message }
})
$simpleOpen.Add_Click({ $folder=Join-Path $appDir '生成的视频'; New-Item -ItemType Directory -Path $folder -Force|Out-Null; Start-Process explorer.exe ('"'+$folder+'"') })
$playOutputSimple.Add_Click({ $latest=Find-LatestPlayableVideo $builtInProject; if($latest){Start-Process $latest.FullName}else{Show-Info '还没有成品，请先点击“开始自动剪辑”。'} })
$voiceListenSimple.Add_Click({
    try {
        $picked = if($voiceSimple.SelectedItem -eq '随机声音'){Get-AiVoiceCatalog|Get-Random}else{Get-AiVoiceCatalog|Where-Object{$_.Name -eq $voiceSimple.SelectedItem}|Select-Object -First 1}
        $sample = Join-Path $appDir ('runtime\声音试听\'+$picked.Voice+'.mp3')
        if(-not(Test-Path $sample)){throw '试听文件不存在，请点击声音选择窗口重新生成。'}
        Start-Process $sample
    } catch { Show-Error $_.Exception.Message }
})
$script:musicPlayer = $null
$musicListenSimple.Add_Click({
    try {
        if($script:musicPlayer){$script:musicPlayer.Stop();$script:musicPlayer.Dispose();$script:musicPlayer=$null;$musicListenSimple.Text='试听';return}
        if($musicSimple.SelectedItem -eq '关闭音乐'){Show-Info '当前已关闭背景音乐。';return}
        $files=@(Get-ChildItem -LiteralPath (Join-Path $builtInProject 'public\music') -File|Where-Object{$_.Extension -match '^\.(wav|mp3)$'}|Sort-Object Name)
        $track=if($musicSimple.SelectedItem -eq '随机音乐'){$files|Get-Random}elseif($musicSimple.SelectedItem -eq '顺序轮换'){$files|Select-Object -First 1}else{$files|Where-Object{$_.BaseName -eq $musicSimple.SelectedItem}|Select-Object -First 1}
        $script:musicPlayer=New-Object System.Media.SoundPlayer($track.FullName);$script:musicPlayer.Load();$script:musicPlayer.Play();$musicListenSimple.Text='停止'
    } catch { Show-Error $_.Exception.Message }
})
$form.Add_FormClosed({if($script:musicPlayer){$script:musicPlayer.Stop();$script:musicPlayer.Dispose()}})

$outputButton.Add_Click({
    $folder = Get-ProjectFolder
    $outputFolder = Join-Path $folder '输出'
    $latestVideo = Find-LatestPlayableVideo $folder
    if (-not $latestVideo) { Show-Info '还没有生成可播放的视频。请先生成预览。'; return }
    try {
        Start-Process -FilePath $latestVideo.FullName
        $statusLabel.Text = '正在播放：' + $latestVideo.Name
    } catch { Show-Error "无法打开系统播放器。视频文件在：`r`n$($latestVideo.FullName)" }
})

$logButton.Add_Click({
    $folder = Get-ProjectFolder
    $outputFolder = Join-Path $folder '输出'
    if (-not (Test-Path -LiteralPath $outputFolder)) { Show-Info '还没有制作记录。'; return }
    Start-Process 'explorer.exe' ('"' + $outputFolder + '"')
})

$retryButton.Add_Click({
    $folder = Get-ProjectFolder
    $lastModePath = Join-Path (Get-StateFolder $folder) 'last-mode.txt'
    $mode = if (Test-Path -LiteralPath $lastModePath) { (Get-Content -LiteralPath $lastModePath -Raw).Trim() } else { 'Preview' }
    if ($mode -notin @('Preview', 'Final')) { $mode = 'Preview' }
    $retryButton.Enabled = $false
    Start-Worker $folder $mode
    $statusLabel.Text = '正在重新尝试制作，请保持电脑开机'
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1500
$timer.Add_Tick({
    Refresh-State
    $folder = Get-ProjectFolder
    $progressPath = Join-Path (Get-StateFolder $folder) 'progress.json'
    if (Test-Path -LiteralPath $progressPath) {
        try {
            $progress = Get-Content -LiteralPath $progressPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $value = [Math]::Max(0, [Math]::Min(100, [int]$progress.progress))
            $progressBar.Value = $value
            if ($progress.status -eq 'running') {
                $statusLabel.Text = $progress.message
                $retryButton.Enabled = $false
            } elseif ($progress.status -eq 'failed') {
                $statusLabel.Text = $progress.message
                $retryButton.Enabled = $true
            } elseif ($progress.status -eq 'complete') {
                $statusLabel.Text = '制作完成：' + $progress.output
                $retryButton.Enabled = $false
            }
        } catch {}
    }
})
$timer.Start()

$form.Add_FormClosing({
    $timer.Stop()
    $folder = Get-ProjectFolder
    if ($folder) { Save-ProjectFolder $folder }
})

try {
    $startupConfig = Get-Config (Get-ProjectFolder)
    $aiToggleSimple.Tag=($startupConfig.voiceover.mode -ne 'source'); &$updateSimpleAiToggle
    if ($startupConfig.voiceover.selectionMode -eq 'random') { $voiceSimple.SelectedIndex=0 }
    else { $voiceName=(Get-AiVoiceCatalog|Where-Object{$_.Voice -eq $startupConfig.voiceover.voice}|Select-Object -First 1).Name; if($voiceName){$voiceSimple.SelectedItem=$voiceName} }
    switch ($startupConfig.voiceover.voice) {
        'zh-CN-XiaoxiaoNeural' { $voiceCombo.SelectedIndex = 1 }
        'zh-CN-YunxiNeural' { $voiceCombo.SelectedIndex = 2 }
        default { $voiceCombo.SelectedIndex = 0 }
    }
    if ($startupConfig.voiceover.mode -eq 'human' -and $startupConfig.voiceover.humanAudioPath) {
        $humanRadio.Checked = $true
        $voiceStatusLabel.Text = '已使用真人录音'
    }
    switch ($startupConfig.export.platform) {
        'douyin' { $platformCombo.SelectedIndex = 1 }
        'wechat' { $platformCombo.SelectedIndex = 2 }
        'xiaohongshu' { $platformCombo.SelectedIndex = 3 }
        'all' { $platformCombo.SelectedIndex = 4 }
        default { $platformCombo.SelectedIndex = 0 }
    }
} catch {}
$initializingVoiceControls = $false
Refresh-State
$form.Add_Shown({
    if ($script:openBatchOnStart) {
        Show-BatchCenter
    } else {
        Confirm-CleanupExpiredBatchMaterials
    }
})
[void]$form.ShowDialog()
