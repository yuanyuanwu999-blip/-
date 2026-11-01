param(
    [Parameter(Mandatory = $true)][string]$RequestBase64
)

$ErrorActionPreference = 'Stop'
$appDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$desktop = 'C:\Users\Administrator\Desktop'
$catalogPath = Join-Path $desktop '员工知识库投喂\02产品资料\九款产品事实表.md'
$bLibrary = Join-Path $desktop '九款B段素材库'
$queueFolder = Join-Path $appDir '批量任务'
$queuePath = Join-Path $queueFolder 'queue.json'
$statePath = Join-Path $queueFolder 'ai-workflow-state.json'
$workflowLockPath = Join-Path $queueFolder 'ai-workflow.lock'
$workerPath = Join-Path $appDir '后台批量制作.ps1'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$workflowLock = $null

function Write-JsonResult($value) {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    [Console]::WriteLine(($value | ConvertTo-Json -Depth 30 -Compress))
}

function Read-JsonFile([string]$path, $fallback) {
    if (-not (Test-Path -LiteralPath $path)) { return $fallback }
    return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Save-JsonFile([string]$path, $value) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
    $temp = $path + '.tmp'
    [System.IO.File]::WriteAllText($temp, ($value | ConvertTo-Json -Depth 30), $utf8NoBom)
    Move-Item -LiteralPath $temp -Destination $path -Force
}

function Lock-Workflow {
    if (Test-Path -LiteralPath (Join-Path $appDir '制作模板\.video-assistant\render.lock')) {
        throw '视频助手正在处理其他任务，请等待当前任务完成后再加入新任务。'
    }
    try {
        $script:workflowLock = [System.IO.File]::Open($workflowLockPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    } catch {
        throw '另一个AI视频任务正在写入队列，请稍后再试。'
    }
}

function Get-ProductCatalog {
    if (-not (Test-Path -LiteralPath $catalogPath)) { throw "找不到九款产品事实表：$catalogPath" }
    $text = Get-Content -LiteralPath $catalogPath -Raw -Encoding UTF8
    $matches = [regex]::Matches($text, '(?ms)^##\s+(?<id>P\d{3})\s+[^\r\n]+\r?\n(?<body>.*?)(?=^##\s+P\d{3}\s+|\z)')
    $products = foreach ($match in $matches) {
        $body = $match.Groups['body'].Value
        $nameMatch = [regex]::Match($body, '(?m)^- 标准产品名称：(?<value>.+?)\s*$')
        $bMatch = [regex]::Match($body, '(?m)^- B 段文件名：`(?<value>[^`]+)`')
        if ($nameMatch.Success -and $bMatch.Success) {
            $fileName = $bMatch.Groups['value'].Value.Trim()
            [PSCustomObject][ordered]@{
                productId = $match.Groups['id'].Value
                productName = $nameMatch.Groups['value'].Value.Trim()
                bFileName = $fileName
                bPath = Join-Path $bLibrary $fileName
                available = Test-Path -LiteralPath (Join-Path $bLibrary $fileName)
            }
        }
    }
    return @($products)
}

function Resolve-Product($request, $catalog) {
    $wanted = ([string]$request.product).Trim()
    if (-not $wanted) { throw '缺少产品编号或正式产品名称。' }
    $found = @($catalog | Where-Object { $_.productId -eq $wanted -or $_.productName -eq $wanted })
    if ($found.Count -ne 1) { throw "产品必须使用九款产品事实表中的编号或正式名称，无法唯一匹配：$wanted" }
    return $found[0]
}

function Get-Hash([string]$value) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($value)
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
}

function Select-Voice {
    $voices = @(
        [PSCustomObject]@{ name='温柔生活女声'; voice='zh-CN-XiaoyiNeural'; rate='+28%'; pitch='-2Hz' },
        [PSCustomObject]@{ name='温柔成熟女声'; voice='zh-CN-XiaoxiaoNeural'; rate='+28%'; pitch='-3Hz' },
        [PSCustomObject]@{ name='自然青年男声'; voice='zh-CN-YunxiNeural'; rate='+28%'; pitch='-2Hz' }
    )
    $state = Read-JsonFile $statePath ([PSCustomObject]@{ lastVoice=''; updatedAt='' })
    $available = @($voices | Where-Object { $_.voice -ne [string]$state.lastVoice })
    if (-not $available.Count) { $available = $voices }
    $selected = $available | Get-Random
    $state.lastVoice = $selected.voice
    $state.updatedAt = Get-Date -Format o
    Save-JsonFile $statePath $state
    return $selected
}

function Get-Queue {
    return Read-JsonFile $queuePath ([PSCustomObject]@{ version=1; updatedAt=(Get-Date -Format o); jobs=@() })
}

function Get-Job($queue, [string]$jobId) {
    $job = @($queue.jobs | Where-Object { $_.id -eq $jobId }) | Select-Object -First 1
    if (-not $job) { throw "找不到视频任务：$jobId" }
    return $job
}

function Prepare-Job($request) {
    Lock-Workflow
    $catalog = Get-ProductCatalog
    $product = Resolve-Product $request $catalog
    if (-not $product.available) { throw "找不到对应B段素材：$($product.bPath)" }

    $aPath = [System.IO.Path]::GetFullPath(([string]$request.aPath).Trim())
    if (-not (Test-Path -LiteralPath $aPath -PathType Leaf)) { throw "找不到A段视频：$aPath" }
    if ([System.IO.Path]::GetExtension($aPath).ToLowerInvariant() -notin @('.mp4','.mov','.mkv','.avi','.webm')) { throw 'A段不是支持的视频格式。' }
    $transcript = ([string]$request.transcript).Trim()
    if (-not $transcript) { throw '配音稿不能为空。' }

    $queue = Get-Queue
    $sourceInfo = Get-Item -LiteralPath $aPath
    $dedupe = Get-Hash("$($product.productId)|$($sourceInfo.FullName)|$($sourceInfo.Length)|$($sourceInfo.LastWriteTimeUtc.Ticks)|$transcript")
    $existing = @($queue.jobs | Where-Object { $_.idempotencyKey -eq $dedupe }) | Select-Object -First 1
    if ($existing) {
        return [PSCustomObject][ordered]@{ ok=$true; duplicate=$true; jobId=$existing.id; status=$existing.status; message='相同素材和文案的任务已经存在，未重复加入。' }
    }

    $version = @($queue.jobs | Where-Object { $_.aiWorkflow -and $_.productId -eq $product.productId }).Count + 1
    $versionText = 'V{0:D2}' -f $version
    $jobId = '{0}-{1}-{2}' -f $product.productId,(Get-Date -Format 'yyyyMMddHHmmss'),([guid]::NewGuid().ToString('N').Substring(0,6))
    $displayName = '{0}_{1}' -f $product.productName,$versionText
    $taskFolder = Join-Path $queueFolder ('素材\' + $jobId)
    New-Item -ItemType Directory -Path $taskFolder -Force | Out-Null
    try {
        $aTarget = Join-Path $taskFolder ('A段' + [System.IO.Path]::GetExtension($aPath).ToLowerInvariant())
        $bTarget = Join-Path $taskFolder ('B段' + [System.IO.Path]::GetExtension($product.bPath).ToLowerInvariant())
        $transcriptTarget = Join-Path $taskFolder '配音稿.txt'
        Copy-Item -LiteralPath $aPath -Destination $aTarget -Force
        Copy-Item -LiteralPath $product.bPath -Destination $bTarget -Force
        [System.IO.File]::WriteAllText($transcriptTarget, ($transcript + "`r`n"), $utf8NoBom)
        $voice = Select-Voice
        $metadata = [PSCustomObject][ordered]@{
            jobId=$jobId; productId=$product.productId; productName=$product.productName; version=$versionText
            sourceAPath=$aPath; sourceBPath=$product.bPath; voice=$voice; createdAt=(Get-Date -Format o)
            paidVideoApiCalled=$false
            notifyChannel=([string]$request.notifyChannel); notifyTarget=([string]$request.notifyTarget); notifyAccount=([string]$request.notifyAccount)
        }
        Save-JsonFile (Join-Path $taskFolder '素材信息.json') $metadata

        $job = [PSCustomObject][ordered]@{
            id=$jobId; name=$displayName; productId=$product.productId; productName=$product.productName; version=$versionText
            folder=$taskFolder; originalFolder=(Split-Path -Parent $aPath); aPath=$aTarget; bPath=$bTarget
            transcriptPath=$transcriptTarget; voiceAudioPath=''; voiceConfig=$voice; status='等待预览'; approved=$false
            previewPath=''; finalPaths=@(); complianceReport=''; qualityReports=@(); approvalManifest=''
            previewConfig=$null; preflightReport=''; startedAt=''; finishedAt=''; estimatedSeconds=0
            lastError=''; updatedAt=(Get-Date -Format o); aiWorkflow=$true; idempotencyKey=$dedupe
            paidVideoApiCalled=$false
            notifyChannel=([string]$request.notifyChannel); notifyTarget=([string]$request.notifyTarget); notifyAccount=([string]$request.notifyAccount)
            notificationStatus='未配置'; notificationError=''
        }
        $queue.jobs = @($queue.jobs) + @($job)
        $queue.updatedAt = Get-Date -Format o
        Save-JsonFile $queuePath $queue

        $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$workerPath,'-AppDir',$appDir,'-Mode','Preview','-JobId',$jobId,'-Silent')
        Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WindowStyle Hidden | Out-Null
        return [PSCustomObject][ordered]@{
            ok=$true; duplicate=$false; jobId=$jobId; productId=$product.productId; productName=$product.productName
            version=$versionText; voice=$voice.name; status='正在生成高清待审核成片'; paidVideoApiCalled=$false
            message='任务已加入并开始本地高清合成；未调用Sora或Veo。'
        }
    } catch {
        if (Test-Path -LiteralPath $taskFolder) { Remove-Item -LiteralPath $taskFolder -Recurse -Force -ErrorAction SilentlyContinue }
        throw
    }
}

function Get-Status($request) {
    $queue = Get-Queue
    $jobId = ([string]$request.jobId).Trim()
    $job = if ($jobId) { Get-Job $queue $jobId } else { @($queue.jobs | Where-Object { $_.aiWorkflow } | Sort-Object updatedAt -Descending) | Select-Object -First 1 }
    if (-not $job) { return [PSCustomObject]@{ ok=$true; found=$false; message='还没有AI视频任务。' } }
    return [PSCustomObject][ordered]@{
        ok=$true; found=$true; jobId=$job.id; productId=$job.productId; productName=$job.productName
        version=$job.version; voice=$job.voiceConfig.name; status=$job.status; reviewPath=$job.previewPath
        finalPaths=@($job.finalPaths); lastError=$job.lastError; paidVideoApiCalled=[bool]$job.paidVideoApiCalled
        notificationStatus=$job.notificationStatus; notificationError=$job.notificationError
    }
}

function Approve-Job($request) {
    Lock-Workflow
    $queue = Get-Queue
    $job = Get-Job $queue ([string]$request.jobId)
    if ($job.status -eq '已完成' -and @($job.finalPaths).Count) {
        return [PSCustomObject]@{ ok=$true; duplicate=$true; jobId=$job.id; finalPath=@($job.finalPaths)[0]; message='该任务已经转正，未重复处理。' }
    }
    if ($job.status -ne '待审核') { throw "当前状态不是待审核：$($job.status)" }
    if (-not $job.previewPath -or -not (Test-Path -LiteralPath $job.previewPath)) { throw '找不到高清待审核成片。' }
    $safeName = ([string]$job.name) -replace '[<>:"/\\|?*]', '_'
    $finalFolder = Join-Path $queueFolder '输出\正式成片'
    New-Item -ItemType Directory -Path $finalFolder -Force | Out-Null
    $finalPath = Join-Path $finalFolder ($safeName + '.mp4')
    Copy-Item -LiteralPath $job.previewPath -Destination $finalPath -Force
    $job.approved = $true
    $job.status = '已完成'
    $job.finalPaths = @($finalPath)
    $job.updatedAt = Get-Date -Format o
    $job | Add-Member -NotePropertyName promotedWithoutRerender -NotePropertyValue $true -Force
    $queue.updatedAt = Get-Date -Format o
    Save-JsonFile $queuePath $queue
    return [PSCustomObject][ordered]@{ ok=$true; duplicate=$false; jobId=$job.id; finalPath=$finalPath; rerendered=$false; paidVideoApiCalled=$false; message='审核通过，已将同一高清文件直接转正。' }
}

function Reject-Job($request) {
    Lock-Workflow
    $queue = Get-Queue
    $job = Get-Job $queue ([string]$request.jobId)
    if ($job.status -ne '待审核') { throw "当前状态不是待审核：$($job.status)" }
    $job.status = '待修改'
    $job.approved = $false
    $job.lastError = ([string]$request.reason).Trim()
    $job.updatedAt = Get-Date -Format o
    $queue.updatedAt = Get-Date -Format o
    Save-JsonFile $queuePath $queue
    return [PSCustomObject][ordered]@{ ok=$true; jobId=$job.id; status=$job.status; reason=$job.lastError; message='已标记为待修改；不会自动重新生成或重新调用员工。' }
}

try {
    $json = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($RequestBase64))
    $request = $json | ConvertFrom-Json
    switch ([string]$request.action) {
        'catalog' { Write-JsonResult ([PSCustomObject]@{ ok=$true; products=(Get-ProductCatalog) }) }
        'prepare' { Write-JsonResult (Prepare-Job $request) }
        'status' { Write-JsonResult (Get-Status $request) }
        'approve' { Write-JsonResult (Approve-Job $request) }
        'reject' { Write-JsonResult (Reject-Job $request) }
        default { throw "不支持的操作：$($request.action)" }
    }
} catch {
    Write-JsonResult ([PSCustomObject]@{ ok=$false; error=$_.Exception.Message })
    exit 1
} finally {
    if ($workflowLock) {
        $workflowLock.Dispose()
        if (Test-Path -LiteralPath $workflowLockPath) {
            Remove-Item -LiteralPath $workflowLockPath -Force -ErrorAction SilentlyContinue
        }
    }
}
