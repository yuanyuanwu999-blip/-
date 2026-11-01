param(
    [Parameter(Mandatory = $true)][string]$Text,
    [Parameter(Mandatory = $true)][string]$Output,
    [string]$Rate = '+0%'
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Speech

$synthesizer = New-Object System.Speech.Synthesis.SpeechSynthesizer
try {
    $chineseVoice = $synthesizer.GetInstalledVoices() |
        ForEach-Object { $_.VoiceInfo } |
        Where-Object { $_.Culture.Name -eq 'zh-CN' } |
        Select-Object -First 1
    if (-not $chineseVoice) { throw 'No zh-CN system voice is installed.' }

    $ratePercent = 0
    if ($Rate -match '([+-]?\d+)%') { $ratePercent = [int]$Matches[1] }
    $synthesizer.Rate = [Math]::Max(-10, [Math]::Min(10, [Math]::Round($ratePercent / 10)))
    $synthesizer.SelectVoice($chineseVoice.Name)
    $synthesizer.SetOutputToWaveFile($Output)
    $synthesizer.Speak($Text)
} finally {
    $synthesizer.Dispose()
}
