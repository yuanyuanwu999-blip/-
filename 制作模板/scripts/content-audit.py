import argparse
import json
import re
import subprocess
import tempfile
from difflib import SequenceMatcher
from pathlib import Path

from faster_whisper import WhisperModel
from rapidocr import RapidOCR


def normalize(text):
    return re.sub(r"[^\u4e00-\u9fffA-Za-z0-9]", "", text or "").lower()


def ocr_text(result):
    if result is None:
        return []
    if hasattr(result, "txts"):
        return [str(item) for item in (result.txts or []) if item]
    if isinstance(result, tuple):
        result = result[0]
    texts = []
    for item in result or []:
        if isinstance(item, (list, tuple)) and len(item) >= 2:
            texts.append(str(item[1]))
    return texts


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--video", required=True)
    parser.add_argument("--transcript", required=True)
    parser.add_argument("--rules", required=True)
    parser.add_argument("--ffmpeg", required=True)
    parser.add_argument("--whisper-dir", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--product", required=True)
    args = parser.parse_args()

    video = Path(args.video)
    transcript = Path(args.transcript).read_text(encoding="utf-8")
    rules = json.loads(Path(args.rules).read_text(encoding="utf-8"))["rules"]
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    print("PROGRESS:98:正在识别成片中的画面文字", flush=True)
    frame_texts = []
    with tempfile.TemporaryDirectory(prefix="video-content-audit-") as temp_name:
        pattern = str(Path(temp_name) / "frame-%03d.jpg")
        extract = subprocess.run(
            [args.ffmpeg, "-y", "-i", str(video), "-vf", "fps=1/2,scale=540:-2", "-q:v", "3", pattern],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
        if extract.returncode != 0:
            raise RuntimeError(extract.stderr[-2000:])
        engine = RapidOCR()
        for index, frame in enumerate(sorted(Path(temp_name).glob("frame-*.jpg"))):
            texts = ocr_text(engine(str(frame)))
            if texts:
                frame_texts.append({"timeSeconds": index * 2, "texts": texts})

    combined_ocr = "\n".join(" ".join(item["texts"]) for item in frame_texts)
    ocr_findings = []
    for rule in rules:
        if rule["term"] in combined_ocr:
            ocr_findings.append({
                "term": rule["term"],
                "level": rule["level"],
                "category": rule["category"],
                "suggestion": rule["suggestion"],
            })

    print("PROGRESS:99:正在核对最终配音与文案", flush=True)
    model = WhisperModel("tiny", device="cpu", compute_type="int8", download_root=args.whisper_dir)
    segments, _ = model.transcribe(str(video), language="zh", beam_size=1, vad_filter=True, condition_on_previous_text=False)
    recognized = "".join(segment.text for segment in segments).strip()
    expected_normalized = normalize(transcript)
    recognized_normalized = normalize(recognized)
    similarity = SequenceMatcher(None, expected_normalized, recognized_normalized).ratio() if expected_normalized else 0.0
    missing_fragments = []
    for line in [normalize(line) for line in transcript.splitlines() if normalize(line)]:
        if len(line) >= 4 and line not in recognized_normalized:
            missing_fragments.append(line)

    blocked = any(item["level"] == "block" for item in ocr_findings)
    needs_review = bool(ocr_findings) or similarity < 0.72
    result = "blocked" if blocked else "manual-review" if needs_review else "passed"
    report = {
        "productName": args.product,
        "videoPath": str(video),
        "result": result,
        "ocr": {"sampleIntervalSeconds": 2, "framesWithText": frame_texts, "combinedText": combined_ocr, "findings": ocr_findings},
        "speech": {
            "expected": transcript.strip(),
            "recognized": recognized,
            "similarity": round(similarity, 4),
            "missingFragments": missing_fragments,
            "notice": "语音识别结果用于自动复核，低相似度需要人工试听确认。",
        },
    }
    safe_name = re.sub(r'[<>:"/\\|?*]', "_", args.product)
    json_path = output_dir / f"{safe_name}_成片内容复核.json"
    text_path = output_dir / f"{safe_name}_成片内容复核.txt"
    json_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    lines = [
        f"产品：{args.product}",
        f"结果：{'存在必须修改内容' if result == 'blocked' else '需要人工复核' if result == 'manual-review' else '通过自动复核'}",
        f"画面识别文字：{combined_ocr or '未识别到文字'}",
        f"画面敏感词：{', '.join(item['term'] for item in ocr_findings) or '未发现'}",
        f"配音识别相似度：{similarity:.1%}",
        f"识别到的配音：{recognized or '未识别到有效配音'}",
        "",
        "说明：OCR和语音识别属于自动复核，正式发布前仍需人工确认。",
    ]
    text_path.write_text("\r\n".join(lines), encoding="utf-8")
    report["jsonPath"] = str(json_path)
    report["textReportPath"] = str(text_path)
    print(json.dumps(report, ensure_ascii=False), flush=True)
    if result == "blocked":
        raise SystemExit(2)


if __name__ == "__main__":
    main()
