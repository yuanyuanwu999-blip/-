param(
    [Parameter(Mandatory = $true)][string]$TextBase64,
    [Parameter(Mandatory = $true)][string]$OutputPath,
    [int]$Rate = 2
)

$ErrorActionPreference = 'Stop'
$text = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($TextBase64))
$voice = New-Object -ComObject SAPI.SpVoice
$chineseVoice = $voice.GetVoices() | Where-Object {
    $_.GetDescription() -match 'Huihui|Xiaoxiao|Chinese|中文'
} | Select-Object -First 1
if ($chineseVoice) { $voice.Voice = $chineseVoice }
$voice.Rate = $Rate
$voice.Volume = 100
$stream = New-Object -ComObject SAPI.SpFileStream
$stream.Open($OutputPath, 3, $false)
$voice.AudioOutputStream = $stream
[void]$voice.Speak($text)
$stream.Close()
