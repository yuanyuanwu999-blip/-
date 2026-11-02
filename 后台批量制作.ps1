param(
    [Parameter(Mandatory = $true)][string]$AppDir,
    [ValidateSet('Preview', 'Final')][string]$Mode = 'Preview',
    [string]$Platform = 'universal',
    [string]$JobId = '',
    [switch]$Silent
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Notify([string]$message, [bool]$success) {
    if ($Silent) { return }
    $icon = if ($success) { [System.Windows.Forms.MessageBoxIcon]::Information } else { [System.Windows.Forms.MessageBoxIcon]::Error }
    [System.Windows.Forms.MessageBox]::Show($message, '批量生产中心', 'OK', $icon) | Out-Null
}

function Save-Queue($queue, [string]$path) {
    $temp = $path + '.tmp'
    [System.IO.File]::WriteAllText($temp, ($queue | ConvertTo-Json -Depth 20), (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $temp -Destination $path -Force
}

function Import-TranscriptFile([string]$source, [string]$target) {
    $extension = [System.IO.Path]::GetExtension($source).ToLowerInvariant()
    if ($extension -eq '.txt') {
        $text = Get-Content -LiteralPath $source -Raw -Encoding UTF8
    } elseif ($extension -eq '.docx') {
        $archive = [System.IO.Compression.ZipFile]::OpenRead($source)
        try {
            $entry = $archive.GetEntry('word/document.xml')
            if (-not $entry) { throw 'Word文档中找不到正文。' }
            $reader = New-Object System.IO.StreamReader($entry.Open())
            try { $xml = $reader.ReadToEnd() } finally { $reader.Close() }
            $text = $xml -replace '</w:p>', "`n" -replace '<w:tab[^>]*/>', ' ' -replace '<[^>]+>', ''
            $text = [System.Net.WebUtility]::HtmlDecode($text)
        } finally { $archive.Dispose() }
    } else { throw '配音稿只支持TXT或DOCX。' }
    $lines = @($text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($lines.Count -gt 1 -and $lines[0] -match '稿$') { $lines = $lines[1..($lines.Count - 1)] }
    if ($lines.Count -eq 0) { throw '配音稿没有可用文字。' }
    [System.IO.File]::WriteAllText($target, (($lines -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
}

function Set-AutomaticProductCover([string]$videoPath, [string]$sourceVideo, [string]$sourceVideoB, [string]$productName, [string]$fontStyle='醒目粗黑') {
    & (Join-Path $AppDir '制作模板\scripts\set-product-cover.ps1') -VideoPath $videoPath -SourceVideo $sourceVideo -SourceVideoB $sourceVideoB -ProductName $productName -AppRoot $AppDir -FontStyle $fontStyle
    return $videoPath
    <# Legacy implementation retained below for rollback reference.
    $ffmpeg = Join-Path $AppDir 'runtime\ffmpeg-full\bin\ffmpeg.exe'
    $ffprobe = Join-Path $AppDir 'runtime\ffmpeg-full\bin\ffprobe.exe'
    if (-not (Test-Path -LiteralPath $ffmpeg) -or -not (Test-Path -LiteralPath $ffprobe)) { throw '找不到封面提取组件。' }
    $durationText = & $ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 $sourceVideo 2>$null
    $duration = 0.0
    [void][double]::TryParse(([string]$durationText).Trim(), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$duration)
    if ($duration -le 0) {
        $durationText = & $ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 $videoPath 2>$null
        [void][double]::TryParse(([string]$durationText).Trim(), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$duration)
        $sourceVideo = $videoPath
    }
    if ($duration -le 0) { throw '无法读取视频时长，未能生成封面。' }
    $candidateFolder = Join-Path ([IO.Path]::GetDirectoryName($videoPath)) ('.cover-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $candidateFolder -Force | Out-Null
    try {
        $candidates = @()
        foreach ($ratio in @(0.22,0.36,0.50,0.64,0.78)) {
            $seconds = [math]::Max(0.1, [math]::Round($duration * $ratio, 3))
            $candidate = Join-Path $candidateFolder (('frame-{0:00}.jpg' -f $candidates.Count))
            & $ffmpeg -hide_banner -loglevel error -y -ss $seconds -i $sourceVideo -frames:v 1 -vf 'scale=1080:-2' -q:v 2 $candidate
            if ((Test-Path -LiteralPath $candidate) -and (Get-Item -LiteralPath $candidate).Length -gt 15000) {
                $candidates += Get-Item -LiteralPath $candidate
            }
        }
        if (-not $candidates.Count) { throw '没有找到可用的清晰封面画面。' }
        # JPEG文件较大的帧通常细节更完整；在最清晰的三张中随机，避免批量封面时间点完全一致。
        $bestPool = @($candidates | Sort-Object Length -Descending | Select-Object -First 3)
        $selectedCover = ($bestPool | Get-Random).FullName
        $muxedVideo = Join-Path $candidateFolder 'with-cover.mp4'
        & $ffmpeg -hide_banner -loglevel error -y -i $videoPath -i $selectedCover -map 0 -map 1 -c copy -c:v:1 mjpeg -disposition:v:1 attached_pic -movflags +faststart $muxedVideo
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $muxedVideo)) { throw '视频封面写入失败。' }
        Move-Item -LiteralPath $muxedVideo -Destination $videoPath -Force
        return $videoPath
    } finally {
        Remove-Item -LiteralPath $candidateFolder -Recurse -Force -ErrorAction SilentlyContinue
    }
    #>
}

$project = Join-Path $AppDir '制作模板'
$queueFolder = Join-Path $AppDir '批量任务'
$queuePath = Join-Path $queueFolder 'queue.json'
$controlPath = Join-Path $queueFolder 'control.json'
$stateFolder = Join-Path $project '.video-assistant'
$lockPath = Join-Path $stateFolder 'render.lock'
$configPath = Join-Path $project 'video.config.json'
$transcriptPath = Join-Path $project '配音稿.txt'
$ownsLock = $false

try {
    if (-not (Test-Path -LiteralPath $queuePath)) { throw '批量队列不存在，请先添加任务。' }
    New-Item -ItemType Directory -Path $stateFolder -Force | Out-Null
    try {
        $lockStream = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $lockBytes = [System.Text.Encoding]::UTF8.GetBytes("batch:$PID")
        $lockStream.Write($lockBytes, 0, $lockBytes.Length)
        $lockStream.Flush()
        $ownsLock = $true
    } catch { throw '已有制作任务正在运行，请等待完成。' }

    $node = Join-Path $project '.tools\node22\PFiles64\nodejs\node.exe'
    if (-not (Test-Path -LiteralPath $node)) { throw '找不到视频运行组件。' }
    $configBackup = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
    $transcriptBackup = Get-Content -LiteralPath $transcriptPath -Raw -Encoding UTF8
    $queue = Get-Content -LiteralPath $queuePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $jobs = @($queue.jobs)
    foreach ($recoverJob in $jobs) {
        if ($recoverJob.status -in @('正在生成预览', '正在生成高清待审核成片')) { $recoverJob.status = '等待预览' }
        elseif ($recoverJob.status -eq '正在正式生成') { $recoverJob.status = if ($recoverJob.approved) { '已通过' } else { '待审核' } }
    }
    Save-Queue $queue $queuePath
    $processed = 0
    $failed = 0

    foreach ($job in $jobs) {
        if ($JobId -and $job.id -ne $JobId) { continue }
        $controlState = 'running'
        if (Test-Path -LiteralPath $controlPath) { try { $controlState = (Get-Content -LiteralPath $controlPath -Raw -Encoding UTF8 | ConvertFrom-Json).state } catch {} }
        if ($controlState -in @('paused','cancelled')) { break }
        $shouldRun = if ($Mode -eq 'Preview') {
            $job.status -in @('等待预览', '失败', '合规拦截')
        } else {
            [bool]$job.approved -and $job.status -in @('已通过', '正式生成失败')
        }
        if (-not $shouldRun) { continue }
        $processed++
        try {
            $elapsedProperty = if ($Mode -eq 'Preview') { 'previewElapsedSeconds' } else { 'finalElapsedSeconds' }
            $history = @($jobs | ForEach-Object { [double]($_.$elapsedProperty) } | Where-Object { $_ -gt 0 })
            $estimate = if ($history.Count) { [math]::Round(($history | Measure-Object -Average).Average) } elseif ($Mode -eq 'Preview') { 120 } else { 300 }
            $job | Add-Member -NotePropertyName startedAt -NotePropertyValue (Get-Date -Format o) -Force
            $job | Add-Member -NotePropertyName finishedAt -NotePropertyValue '' -Force
            $job | Add-Member -NotePropertyName estimatedSeconds -NotePropertyValue $estimate -Force
            $job | Add-Member -NotePropertyName preflightReport -NotePropertyValue '' -Force
            $job.status = if ($Mode -eq 'Preview') { '正在生成高清待审核成片' } else { '正在正式生成' }
            $job.lastError = ''
            $job.updatedAt = (Get-Date -Format o)
            Save-Queue $queue $queuePath
            if (-not (Test-Path -LiteralPath $job.aPath) -or -not (Test-Path -LiteralPath $job.bPath)) { throw 'A段或B段素材已被移动。' }
            if (-not (Test-Path -LiteralPath $job.transcriptPath)) { throw '配音稿已被移动。' }
            Import-TranscriptFile $job.transcriptPath $transcriptPath

            $importOutput = & $node (Join-Path $project 'scripts\import-assets.mjs') $job.aPath $job.bPath 2>&1
            if ($LASTEXITCODE -ne 0) { throw ($importOutput -join "`r`n") }
            $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $config.productName = $job.name
    if ($job.durationSeconds) { $config.duration.targetSeconds = [int]$job.durationSeconds }
            if ($job.voiceAudioPath -and (Test-Path -LiteralPath $job.voiceAudioPath)) {
                $config.voiceover.mode = 'human'
                $config.voiceover.humanAudioPath = ([string]$job.voiceAudioPath).Replace('\', '/')
            } elseif ($job.voiceConfig -and [string]$job.voiceConfig.mode -eq 'source') {
                $config.voiceover.mode = 'source'
                $config.voiceover.humanAudioPath = ''
            } else {
                $config.voiceover.mode = 'ai'
                $config.voiceover.humanAudioPath = ''
    if ($job.voiceConfig) {
                    $config.voiceover.voice = [string]$job.voiceConfig.voice
                    $config.voiceover.rate = [string]$job.voiceConfig.rate
                    $config.voiceover.pitch = [string]$job.voiceConfig.pitch
                }
            }
            [System.IO.File]::WriteAllText($configPath, ($config | ConvertTo-Json -Depth 20), (New-Object System.Text.UTF8Encoding($false)))

            $reportFolder = Join-Path $queueFolder '审核报告'
            & $node (Join-Path $project 'scripts\preflight-check.mjs') --config $configPath --mode $Mode --platform $Platform --output-dir $reportFolder *>$null
            $preflightExit = $LASTEXITCODE
            $safeReportName = ([string]$job.name) -replace '[<>:"/\\|?*]', '_'
            $job.preflightReport = Join-Path $reportFolder ($safeReportName + '_生成前体检.txt')
            if ($preflightExit -ne 0) { throw '生成前体检未通过，请查看任务详情中的体检报告。' }

            if ($Mode -eq 'Final') {
                if (-not $job.approvalManifest -or -not (Test-Path -LiteralPath $job.approvalManifest)) { throw '缺少审核版本锁定记录，请重新查看并通过预览。' }
                $verifyConfig = $config | ConvertTo-Json -Depth 20 | ConvertFrom-Json
                $verifyConfig.voiceover.sourcePath = ([string]$job.transcriptPath).Replace('\', '/')
                $verifyConfigPath = Join-Path $stateFolder ('verify-' + $job.id + '.json')
                [System.IO.File]::WriteAllText($verifyConfigPath, ($verifyConfig | ConvertTo-Json -Depth 20), (New-Object System.Text.UTF8Encoding($false)))
                & $node (Join-Path $project 'scripts\approval-lock.mjs') --verify --config $verifyConfigPath --manifest $job.approvalManifest 2>&1 | Out-Null
                $verifyExit = $LASTEXITCODE
                Remove-Item -LiteralPath $verifyConfigPath -Force -ErrorAction SilentlyContinue
                if ($verifyExit -ne 0) { throw '审核通过后的素材或设置发生变化，请重新生成预览并审核。' }
            }

            $complianceOutput = & $node (Join-Path $project 'scripts\compliance-check.mjs') --text $transcriptPath --product $job.name --output-dir $reportFolder 2>&1
            $complianceExit = $LASTEXITCODE
            $reportJsonLine = @($complianceOutput | Where-Object { $_ -match '^\{' }) | Select-Object -Last 1
            if ($reportJsonLine) {
                try { $job.complianceReport = ($reportJsonLine | ConvertFrom-Json).textReportPath } catch {}
            }
            if ($complianceExit -eq 2) {
                $job.status = '合规拦截'
                $job.lastError = '文案存在必须修改项，请查看合规报告。'
                $elapsed = [math]::Round(((Get-Date) - [datetime]$job.startedAt).TotalSeconds)
                $job | Add-Member -NotePropertyName $elapsedProperty -NotePropertyValue $elapsed -Force
                $job.finishedAt = Get-Date -Format o
                $failed++
                Save-Queue $queue $queuePath
                continue
            } elseif ($complianceExit -ne 0) { throw ($complianceOutput -join "`r`n") }

            $safeName = $job.name -replace '[<>:"/\\|?*]', '_'
            $categoryName = ($safeName -replace '[\s_\-]*\d+$','').Trim()
            if (-not $categoryName) { $categoryName = $safeName }
            $output = Join-Path (Join-Path $AppDir "生成的视频\$categoryName") ($safeName + '.mp4')
            New-Item -ItemType Directory -Path (Split-Path -Parent $output) -Force | Out-Null
            $logFolder = Join-Path $queueFolder '制作记录'
            New-Item -ItemType Directory -Path $logFolder -Force | Out-Null
            $logPath = Join-Path $logFolder ($safeName + '_' + $Mode + '.txt')
            if ($Mode -eq 'Preview') {
                & $node (Join-Path $project 'scripts\render.mjs') --review --output $output *>&1 | Tee-Object -FilePath $logPath | Out-Null
            } else {
                & $node (Join-Path $project 'scripts\render.mjs') --platform $Platform --output $output *>&1 | Tee-Object -FilePath $logPath | Out-Null
            }
            if ($LASTEXITCODE -ne 0) {
                $progressPath = Join-Path $stateFolder 'progress.json'
                $message = if (Test-Path -LiteralPath $progressPath) { (Get-Content -LiteralPath $progressPath -Raw -Encoding UTF8 | ConvertFrom-Json).message } else { '制作失败' }
                throw $message
            }
            $coverFont = if($job.coverFont){[string]$job.coverFont}else{'醒目粗黑'}
            Set-AutomaticProductCover $output $job.aPath $job.bPath $job.name $coverFont | Out-Null
            $progress = Get-Content -LiteralPath (Join-Path $stateFolder 'progress.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($Mode -eq 'Preview') {
                $job.previewPath = [string]$progress.output
                $job.finalPaths = @([string]$progress.output)
                $job.status = '已完成'
                $job.approved = $true
                $job | Add-Member -NotePropertyName previewConfig -NotePropertyValue $config -Force
                $job | Add-Member -NotePropertyName approvalManifest -NotePropertyValue '' -Force
            } else {
                $job.finalPaths = @($progress.outputs)
                $job.status = '已完成'
            }
            $job.qualityReports = @($progress.qualityReports)
            $elapsed = [math]::Round(((Get-Date) - [datetime]$job.startedAt).TotalSeconds)
            $job | Add-Member -NotePropertyName $elapsedProperty -NotePropertyValue $elapsed -Force
            $job.finishedAt = Get-Date -Format o
            $job.updatedAt = (Get-Date -Format o)
            Save-Queue $queue $queuePath
            if ($Mode -eq 'Preview' -and $job.notifyChannel -eq 'feishu' -and $job.notifyTarget) {
                try {
                    $openClawNode = (Get-Command node.exe -ErrorAction Stop).Source
                    $npmRoot = (& npm root -g 2>$null | Select-Object -Last 1).Trim()
                    $openClawCli = Join-Path $npmRoot 'openclaw\openclaw.mjs'
                    if (-not (Test-Path -LiteralPath $openClawCli)) { throw '此电脑没有安装OpenClaw，已跳过飞书通知。' }
                    $accountId = if ($job.notifyAccount) { [string]$job.notifyAccount } else { 'default' }
                    $transcriptForNotice = (Get-Content -LiteralPath $job.transcriptPath -Raw -Encoding UTF8).Trim()
                    $voiceNameForNotice = if ($job.voiceConfig -and $job.voiceConfig.name) { [string]$job.voiceConfig.name } else { '已配置配音' }
                    $notice = @"
【员工完整交付】
产品：$($job.productName)
版本：$($job.version)

小文最终配音稿：
$transcriptForNotice

【视频制作内容】
A段：$($job.productName) A段
B段：$($job.productName) B段素材库
配音：$voiceNameForNotice（随机）
结构：A段在前，B段在后
规格：1080×1920，约15秒，高清竖屏
本次耗时：$elapsed 秒
视频生成API费用：0元（本地合成）

【小总验收】
高清待审核成片已完成并附在本消息中。
任务：$($job.id)
回复“通过”可将同一文件直接转正；回复“不通过＋原因”只返工对应环节。
"@
                    $sendArgs = @($openClawCli,'message','send','--channel','feishu','--account',$accountId,'--target',[string]$job.notifyTarget,'--message',$notice,'--media',[string]$job.previewPath,'--json')
                    $sendOutput = & $openClawNode @sendArgs 2>&1
                    if ($LASTEXITCODE -ne 0) { throw ($sendOutput -join "`r`n") }
                    $job | Add-Member -NotePropertyName notificationStatus -NotePropertyValue '已发送' -Force
                    $job | Add-Member -NotePropertyName notificationError -NotePropertyValue '' -Force
                } catch {
                    $job | Add-Member -NotePropertyName notificationStatus -NotePropertyValue '发送失败' -Force
                    $job | Add-Member -NotePropertyName notificationError -NotePropertyValue $_.Exception.Message -Force
                }
                $job.updatedAt = Get-Date -Format o
                Save-Queue $queue $queuePath
            }
        } catch {
            $failed++
            $job.status = if ($Mode -eq 'Preview') { '失败' } else { '正式生成失败' }
            $job.lastError = $_.Exception.Message
            if ($job.startedAt) {
                $elapsed = [math]::Round(((Get-Date) - [datetime]$job.startedAt).TotalSeconds)
                $job | Add-Member -NotePropertyName $elapsedProperty -NotePropertyValue $elapsed -Force
                $job.finishedAt = Get-Date -Format o
            }
            $job.updatedAt = (Get-Date -Format o)
            Save-Queue $queue $queuePath
        }
    }
    if ($job.musicConfig) {
        $config.music.mode = [string]$job.musicConfig.mode
        $config.music.sourcePath = [string]$job.musicConfig.sourcePath
    }
    if ($job.captionBottom) { $config.captions.bottom = [int]$job.captionBottom }
    if ($job.captionStyle) {
        $config.captions.fontFamily = [string]$job.captionStyle.fontFamily
        $config.captions.color = [string]$job.captionStyle.color
        $config.captions.fontWeight = [int]$job.captionStyle.fontWeight
        $config.captions.strokeWidth = [int]$job.captionStyle.strokeWidth
    }

    Save-Queue $queue $queuePath
    $finalControl = 'running'
    if (Test-Path -LiteralPath $controlPath) { try { $finalControl = (Get-Content -LiteralPath $controlPath -Raw -Encoding UTF8 | ConvertFrom-Json).state } catch {} }
    if ($finalControl -eq 'paused') {
        Notify "批量任务已暂停。`r`n`r`n已处理：$processed 条`r`n点击“继续队列”可恢复。" $true
    } elseif ($finalControl -eq 'cancelled') {
        Notify "批量任务已停止。`r`n`r`n未处理任务仍保留在队列中。" $true
    } else {
        Notify "批量任务已处理完成。`r`n`r`n处理：$processed 条`r`n失败或拦截：$failed 条" ($failed -eq 0)
    }
} catch {
    Notify $_.Exception.Message $false
} finally {
    if ($configBackup) { [System.IO.File]::WriteAllText($configPath, $configBackup, (New-Object System.Text.UTF8Encoding($false))) }
    if ($transcriptBackup) { [System.IO.File]::WriteAllText($transcriptPath, $transcriptBackup, (New-Object System.Text.UTF8Encoding($false))) }
    if ($lockStream) { $lockStream.Dispose() }
    if ($ownsLock) { Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue }
}
