param([switch]$SkipHeavyAudioTools)

$ErrorActionPreference = 'Stop'
$appDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$runtime = Join-Path $appDir 'runtime'
$template = Join-Path $appDir '制作模板'
$logPath = Join-Path $appDir '安装记录.log'

function Write-Step([string]$message) {
    $line = ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $message)
    Write-Host "`n$line" -ForegroundColor Cyan
    Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
}

function Refresh-Path {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$machine;$user"
}

function Install-WingetPackage([string]$id, [string]$title) {
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        throw ('缺少{0}，且此电脑没有winget。请先安装应用安装程序，再重新运行本安装程序。' -f $title)
    }
    Write-Step "正在安装$title"
    & winget.exe install --id $id --exact --silent --accept-package-agreements --accept-source-agreements --disable-interactivity
    if ($LASTEXITCODE -ne 0) { throw "$title 安装失败，退出代码：$LASTEXITCODE" }
    Refresh-Path
}

function Find-Python311 {
    $launcher = Get-Command py.exe -ErrorAction SilentlyContinue
    if ($launcher) {
        $path = (& $launcher.Source -3.11 -c 'import sys; print(sys.executable)' 2>$null | Select-Object -Last 1)
        if ($LASTEXITCODE -eq 0 -and $path -and (Test-Path -LiteralPath $path.Trim())) { return $path.Trim() }
    }
    $python = Get-Command python.exe -ErrorAction SilentlyContinue
    if ($python) {
        $version = (& $python.Source -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>$null | Select-Object -Last 1)
        if ($version -eq '3.11') { return $python.Source }
    }
    return $null
}

try {
    Set-Content -LiteralPath $logPath -Value '视频批量制作助手安装记录' -Encoding UTF8
    New-Item -ItemType Directory -Path $runtime -Force | Out-Null

    if (-not (Get-Command node.exe -ErrorAction SilentlyContinue)) {
        Install-WingetPackage 'OpenJS.NodeJS.LTS' 'Node.js'
    }
    $systemNode = (Get-Command node.exe -ErrorAction Stop).Source
    $npm = (Get-Command npm.cmd -ErrorAction Stop).Source
    $node = Join-Path $template '.tools\node22\PFiles64\nodejs\node.exe'
    if (-not (Test-Path -LiteralPath $node)) {
        $nodeArchive = Join-Path $template '.tools\node-runtime.zip'
        if (-not (Test-Path -LiteralPath $nodeArchive)) { throw '安装包中缺少便携Node运行组件，请重新下载完整ZIP。' }
        New-Item -ItemType Directory -Path (Split-Path -Parent $node) -Force | Out-Null
        Expand-Archive -LiteralPath $nodeArchive -DestinationPath (Split-Path -Parent $node) -Force
    }
    if (-not (Test-Path -LiteralPath $node)) { throw '便携Node运行组件解压失败。' }
    Write-Step "Node.js 已就绪：$systemNode；视频助手使用：$node"

    $python = Find-Python311
    if (-not $python) {
        Install-WingetPackage 'Python.Python.3.11' 'Python 3.11'
        $python = Find-Python311
    }
    if (-not $python) { throw '安装后仍找不到Python 3.11。请重新启动电脑后再次运行本安装程序。' }
    Write-Step "Python 已就绪：$python"

    $ffmpeg = Join-Path $runtime 'ffmpeg-full\bin\ffmpeg.exe'
    $ffprobe = Join-Path $runtime 'ffmpeg-full\bin\ffprobe.exe'
    if (-not (Test-Path -LiteralPath $ffmpeg) -or -not (Test-Path -LiteralPath $ffprobe)) {
        Write-Step '正在下载FFmpeg视频处理组件（约100MB）'
        $tempRoot = Join-Path $env:TEMP ('video-assistant-ffmpeg-' + [guid]::NewGuid().ToString('N'))
        $zip = Join-Path $tempRoot 'ffmpeg.zip'
        $expanded = Join-Path $tempRoot 'expanded'
        New-Item -ItemType Directory -Path $expanded -Force | Out-Null
        Invoke-WebRequest -UseBasicParsing -Uri 'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip' -OutFile $zip
        Expand-Archive -LiteralPath $zip -DestinationPath $expanded -Force
        $downloadedFfmpeg = Get-ChildItem -LiteralPath $expanded -Filter 'ffmpeg.exe' -File -Recurse | Select-Object -First 1
        $downloadedFfprobe = Get-ChildItem -LiteralPath $expanded -Filter 'ffprobe.exe' -File -Recurse | Select-Object -First 1
        if (-not $downloadedFfmpeg -or -not $downloadedFfprobe) { throw '下载包中没有找到FFmpeg组件。' }
        New-Item -ItemType Directory -Path (Split-Path -Parent $ffmpeg) -Force | Out-Null
        Copy-Item -LiteralPath $downloadedFfmpeg.FullName -Destination $ffmpeg -Force
        Copy-Item -LiteralPath $downloadedFfprobe.FullName -Destination $ffprobe -Force
        $resolvedTemp = [IO.Path]::GetFullPath($tempRoot)
        $resolvedTempBase = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
        if (-not $resolvedTemp.StartsWith($resolvedTempBase, [StringComparison]::OrdinalIgnoreCase)) {
            throw '临时目录校验失败，未执行清理。'
        }
        Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
    }
    Write-Step 'FFmpeg 已就绪'

    $ttsPython = Join-Path $runtime 'edge-tts\Scripts\python.exe'
    if (-not (Test-Path -LiteralPath $ttsPython)) {
        Write-Step '正在安装AI配音组件'
        & $python -m venv (Join-Path $runtime 'edge-tts')
        if ($LASTEXITCODE -ne 0) { throw '无法创建AI配音环境。' }
    }
    & $ttsPython -m pip install --disable-pip-version-check --upgrade pip edge-tts gTTS
    if ($LASTEXITCODE -ne 0) { throw 'AI配音组件安装失败。' }

    Write-Step '正在英文临时目录安装视频渲染组件'
    $stageBase = Join-Path $env:ProgramData 'VideoAssistantInstall'
    $stage = Join-Path $stageBase ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $template 'package.json') -Destination $stage -Force
    Push-Location $stage
    try {
        & $npm install --no-audit --no-fund
        if ($LASTEXITCODE -ne 0) { throw 'Remotion依赖安装失败。' }
        Copy-Item -LiteralPath (Join-Path $stage 'node_modules') -Destination $template -Recurse -Force
    } finally { Pop-Location }
    Push-Location $template
    try {
        & $node (Join-Path $template 'node_modules\@remotion\cli\remotion-cli.js') browser ensure
        if ($LASTEXITCODE -ne 0) { throw 'Remotion浏览器组件安装失败。' }
    } finally { Pop-Location }
    $resolvedStage = [IO.Path]::GetFullPath($stage)
    $resolvedStageBase = [IO.Path]::GetFullPath($stageBase).TrimEnd('\') + '\'
    if ($resolvedStage.StartsWith($resolvedStageBase, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolvedStage -Recurse -Force
    }

    if (-not $SkipHeavyAudioTools) {
        $audioPython = Join-Path $runtime 'audio-processing\Scripts\python.exe'
        if (-not (Test-Path -LiteralPath $audioPython)) {
            Write-Step '正在创建音频处理环境'
            & $python -m venv (Join-Path $runtime 'audio-processing')
            if ($LASTEXITCODE -ne 0) { throw '无法创建音频处理环境。' }
        }
        Write-Step '正在安装原视频人声处理、封面识别和语音检查组件（这一步时间较长）'
        & $audioPython -m pip install --disable-pip-version-check --upgrade pip
        & $audioPython -m pip install --disable-pip-version-check numpy soundfile 'audio-separator[cpu]' faster-whisper opencv-python rapidocr
        if ($LASTEXITCODE -ne 0) { throw '音频处理组件安装失败。' }
        Write-Step '正在预下载AI模型（首次安装时间较长）'
        & $audioPython (Join-Path $template 'scripts\install-models.py') --runtime $runtime
        if ($LASTEXITCODE -ne 0) { throw 'AI模型下载失败。' }
    }

    Write-Step '正在执行完整自检'
    $required = @(
        $ffmpeg,
        $ffprobe,
        (Join-Path $runtime 'edge-tts\Scripts\edge-tts.exe'),
        (Join-Path $template 'node_modules\@remotion\cli\remotion-cli.js')
    )
    $missing = @($required | Where-Object { -not (Test-Path -LiteralPath $_) })
    if ($missing.Count) { throw ('仍缺少组件：' + ($missing -join '；')) }

    Write-Step '安装完成'
    Add-Type -AssemblyName System.Windows.Forms
    [Windows.Forms.MessageBox]::Show('安装完成。现在可以双击“启动视频助手.cmd”。','视频批量制作助手','OK','Information') | Out-Null
} catch {
    $message = $_.Exception.Message
    Add-Content -LiteralPath $logPath -Value ("安装失败：$message") -Encoding UTF8
    Add-Type -AssemblyName System.Windows.Forms
    [Windows.Forms.MessageBox]::Show("安装没有完成：`r`n$message`r`n`r`n详细信息请查看：$logPath",'视频批量制作助手','OK','Error') | Out-Null
    exit 1
}

