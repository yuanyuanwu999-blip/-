param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectFolder,

    [ValidateSet('Preview', 'Final')]
    [string]$Mode = 'Preview'
)

Add-Type -AssemblyName System.Windows.Forms

function Notify([string]$message, [bool]$success) {
    $icon = if ($success) {
        [System.Windows.Forms.MessageBoxIcon]::Information
    } else {
        [System.Windows.Forms.MessageBoxIcon]::Error
    }
    [System.Windows.Forms.MessageBox]::Show(
        $message,
        '视频批量制作助手',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        $icon
    ) | Out-Null
}

try {
    $outputFolder = Join-Path $ProjectFolder '输出'
    New-Item -ItemType Directory -Path $outputFolder -Force | Out-Null
    $stateFolder = Join-Path $ProjectFolder '.video-assistant'
    New-Item -ItemType Directory -Path $stateFolder -Force | Out-Null
    $lockPath = Join-Path $stateFolder 'render.lock'
    $ownsLock = $false
    try {
        $lockStream = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $lockBytes = [System.Text.Encoding]::UTF8.GetBytes([string]$PID)
        $lockStream.Write($lockBytes, 0, $lockBytes.Length)
        $lockStream.Flush()
        $ownsLock = $true
    } catch {
        throw '已有一个制作任务正在运行，请等待完成后再操作。'
    }
    Set-Content -LiteralPath (Join-Path $stateFolder 'last-mode.txt') -Value $Mode -Encoding UTF8
    Remove-Item -LiteralPath (Join-Path $stateFolder 'failed') -Force -ErrorAction SilentlyContinue

    $isPreview = $Mode -eq 'Preview'
    $logName = if ($isPreview) { '预览制作记录.txt' } else { '正式制作记录.txt' }
    $logPath = Join-Path $outputFolder $logName
    $completeMarkerName = if ($isPreview) { 'preview-complete' } else { 'final-complete' }
    $completeMarker = Join-Path $stateFolder $completeMarkerName
    Remove-Item -LiteralPath $completeMarker -Force -ErrorAction SilentlyContinue

    $projectNode = Join-Path $ProjectFolder '.tools\node22\PFiles64\nodejs\node.exe'
    if (Test-Path -LiteralPath $projectNode) {
        $node = $projectNode
    } else {
        $codexNode = Get-ChildItem 'C:\Program Files\WindowsApps\OpenAI.Codex_*\app\resources\cua_node\bin\node.exe' -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending |
            Select-Object -First 1
        if (-not $codexNode) { throw '找不到兼容的视频运行环境，请重新安装或更新 Codex。' }
        $node = $codexNode.FullName
    }

    Set-Location -LiteralPath $ProjectFolder
    $taskName = if ($isPreview) { '生成预览' } else { '正式生成' }
    "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $taskName：$ProjectFolder" | Set-Content -LiteralPath $logPath -Encoding UTF8

    # 单条制作是用户已经选好素材后直接生成，不再要求预览或人工审核。

    # Release the render lock before showing a modal result message. Otherwise
    # an unread/hidden message box keeps the worker alive and blocks the next job.
    if ($lockStream) { $lockStream.Dispose(); $lockStream = $null }
    if ($ownsLock -and $lockPath) { Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue; $ownsLock = $false }
    if ($isPreview) {
        & $node (Join-Path $ProjectFolder 'scripts\render.mjs') --preview *>> $logPath
    } else {
        & $node (Join-Path $ProjectFolder 'scripts\render.mjs') *>> $logPath
    }
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        $progressPath = Join-Path $stateFolder 'progress.json'
        $detail = $null
        if (Test-Path -LiteralPath $progressPath) {
            try { $detail = [string]((Get-Content -LiteralPath $progressPath -Raw -Encoding UTF8 | ConvertFrom-Json).message) } catch {}
        }
        if (-not $detail -and (Test-Path -LiteralPath $logPath)) {
            $detail = Get-Content -LiteralPath $logPath -Encoding UTF8 | Where-Object { $_ -match 'Error:|失败|无法' } | Select-Object -Last 1
            $detail = ([string]$detail -replace '^.*?Error:\s*','').Trim()
        }
        if ($detail) { throw $detail }
        throw "制作命令返回错误代码 $exitCode，请查看制作记录。"
    }

    if (-not $isPreview) {
        $config = Get-Content -LiteralPath (Join-Path $ProjectFolder 'video.config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $safeName = ([string]$config.productName -replace '[<>:"/\\|?*]','_').Trim()
        if (-not $safeName) { $safeName = '成品视频' }
        $category = ($safeName -replace '[\s_\-]*\d+$','').Trim()
        if (-not $category) { $category = $safeName }
        $progressFile = Join-Path $stateFolder 'progress.json'
        if (Test-Path -LiteralPath $progressFile) {
            $progress = Get-Content -LiteralPath $progressFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $sourceOutput = @($progress.outputs)[0]
            if (-not $sourceOutput) { $sourceOutput = [string]$progress.output }
            if ($sourceOutput -and (Test-Path -LiteralPath $sourceOutput)) {
                $appRoot = Split-Path -Parent $ProjectFolder
                $destinationFolder = Join-Path $appRoot ("生成的视频\" + $category)
                New-Item -ItemType Directory -Path $destinationFolder -Force | Out-Null
                $destinationVideo = Join-Path $destinationFolder ($safeName + '.mp4')
                Copy-Item -LiteralPath $sourceOutput -Destination $destinationVideo -Force
                $sourceForCover = [string]$config.segments.a.sourcePath
                if (-not [IO.Path]::IsPathRooted($sourceForCover)) { $sourceForCover = Join-Path $ProjectFolder $sourceForCover }
                $sourceForCoverB = [string]$config.segments.b.sourcePath
                if (-not [IO.Path]::IsPathRooted($sourceForCoverB)) { $sourceForCoverB = Join-Path $ProjectFolder $sourceForCoverB }
                $coverScript = Join-Path $ProjectFolder 'scripts\set-product-cover.ps1'
                $coverFont = if($config.cover -and $config.cover.fontStyle){[string]$config.cover.fontStyle}else{'醒目粗黑'}
                & $coverScript -VideoPath $destinationVideo -SourceVideo $sourceForCover -SourceVideoB $sourceForCoverB -ProductName ([string]$config.productName) -AppRoot $appRoot -FontStyle $coverFont
            }
        }
    }

    Set-Content -LiteralPath $completeMarker -Value (Get-Date -Format o) -Encoding UTF8
    "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $taskName 完成" | Add-Content -LiteralPath $logPath -Encoding UTF8

    if ($isPreview) {
        Notify "预览视频已生成。`r`n`r`n请返回小程序，点击“3 审核确认”完整查看预览。" $true
    } else {
        Notify "正式高清成片已生成。`r`n`r`n成片保存在：`r`n$outputFolder" $true
    }
} catch {
    $errorMessage = $_.Exception.Message
    if ($logPath) {
        "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] 制作失败：$errorMessage" | Add-Content -LiteralPath $logPath -Encoding UTF8
    }
    if ($stateFolder) {
        Set-Content -LiteralPath (Join-Path $stateFolder 'failed') -Value $errorMessage -Encoding UTF8
    }
    # A failure notification must not keep the exclusive render lock open.
    if ($lockStream) { $lockStream.Dispose(); $lockStream = $null }
    if ($ownsLock -and $lockPath) { Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue; $ownsLock = $false }
    Notify "视频制作失败。`r`n`r`n$errorMessage" $false
    exit 1
} finally {
    if ($lockStream) { $lockStream.Dispose() }
    if ($ownsLock -and $lockPath) { Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue }
}
