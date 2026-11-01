import argparse
import json
import shutil
import subprocess
import tempfile
from pathlib import Path

import numpy as np
import soundfile as sf
from audio_separator.separator import Separator
from faster_whisper import WhisperModel


def emit(progress, message):
    print(f"PROGRESS:{progress}:{message}", flush=True)


def rms(path):
    audio, _ = sf.read(path, always_2d=True)
    if len(audio) == 0:
        return 0.0
    return float(np.sqrt(np.mean(np.square(audio.astype(np.float64)))))


def extract_audio(ffmpeg, source, target):
    result = subprocess.run(
        [ffmpeg, "-y", "-i", str(source), "-vn", "-ac", "2", "-ar", "44100", "-c:a", "pcm_s16le", str(target)],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    return result.returncode == 0 and target.exists() and target.stat().st_size > 4096


def choose_instrumental(paths):
    candidates = [Path(p) for p in paths]
    for path in candidates:
        lowered = path.name.lower()
        if "instrumental" in lowered or "no_vocals" in lowered or "karaoke" in lowered:
            return path
    return candidates[0] if candidates else None


def has_speech(model, path):
    segments, _ = model.transcribe(
        str(path),
        language="zh",
        beam_size=1,
        vad_filter=True,
        vad_parameters={"min_silence_duration_ms": 300},
        condition_on_previous_text=False,
    )
    findings = []
    for segment in segments:
        text = segment.text.strip()
        if text and segment.no_speech_prob < 0.62 and segment.avg_logprob > -1.25:
            findings.append({
                "start": round(segment.start, 2),
                "end": round(segment.end, 2),
                "text": text,
                "confidence": round(1 - segment.no_speech_prob, 3),
            })
    return findings


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--ffmpeg", required=True)
    parser.add_argument("--model-dir", required=True)
    parser.add_argument("--whisper-dir", required=True)
    parser.add_argument("--report", required=True)
    args = parser.parse_args()

    manifest = json.loads(Path(args.manifest).read_text(encoding="utf-8"))
    model_dir = Path(args.model_dir)
    whisper_dir = Path(args.whisper_dir)
    model_dir.mkdir(parents=True, exist_ok=True)
    whisper_dir.mkdir(parents=True, exist_ok=True)
    report = {"policy": "separate-detect-or-mute", "segments": {}}

    emit(12, "正在加载原人声分离模型")
    separator = Separator(
        log_level=20,
        output_format="WAV",
        model_file_dir=str(model_dir),
    )
    separator.load_model("UVR-MDX-NET-Inst_HQ_3.onnx")

    emit(16, "正在加载人声残留检测模型")
    whisper = WhisperModel(
        "tiny",
        device="cpu",
        compute_type="int8",
        download_root=str(whisper_dir),
    )

    for index, item in enumerate(manifest["segments"]):
        key = item["key"]
        source = Path(item["source"])
        output = Path(item["output"])
        base_progress = 18 + index * 16
        result = {"status": "muted", "reason": "安全静音", "speech": []}
        output.parent.mkdir(parents=True, exist_ok=True)

        with tempfile.TemporaryDirectory(prefix=f"video-assistant-{key}-") as temp_name:
            temp = Path(temp_name)
            extracted = temp / f"{key}-source.wav"
            if not extract_audio(args.ffmpeg, source, extracted):
                result["reason"] = "素材没有可用音轨"
                report["segments"][key] = result
                emit(base_progress + 14, f"{key.upper()}段无可用音轨 已安全静音")
                continue

            emit(base_progress, f"正在分离{key.upper()}段原有人声")
            separator.output_dir = str(temp)
            separated = separator.separate(str(extracted))
            instrumental = choose_instrumental(separated)
            if instrumental is None or not instrumental.exists():
                result["reason"] = "分离结果不可用"
                report["segments"][key] = result
                emit(base_progress + 14, f"{key.upper()}段分离失败 已安全静音")
                continue

            emit(base_progress + 10, f"正在检查{key.upper()}段人声残留")
            findings = has_speech(whisper, instrumental)
            result["speech"] = findings
            result["sourceRms"] = round(rms(extracted), 6)
            result["environmentRms"] = round(rms(instrumental), 6)
            if findings:
                result["reason"] = "检测到疑似人声残留"
                emit(base_progress + 14, f"{key.upper()}段仍疑似有人声 已安全静音")
            else:
                shutil.copy2(instrumental, output)
                result["status"] = "environment-preserved"
                result["reason"] = "分离通过且未检测到人声残留"
                result["output"] = str(output)
                emit(base_progress + 14, f"{key.upper()}段环境音处理完成")
            report["segments"][key] = result

    Path(args.report).write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
