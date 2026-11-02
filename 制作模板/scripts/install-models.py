import argparse
from pathlib import Path

from audio_separator.separator import Separator
from faster_whisper import WhisperModel


parser = argparse.ArgumentParser()
parser.add_argument("--runtime", required=True)
args = parser.parse_args()
runtime = Path(args.runtime)
audio_models = runtime / "audio-models"
whisper_models = runtime / "whisper-models"
audio_models.mkdir(parents=True, exist_ok=True)
whisper_models.mkdir(parents=True, exist_ok=True)

print("Downloading source-audio separation model...", flush=True)
separator = Separator(log_level=20, output_format="WAV", model_file_dir=str(audio_models))
separator.load_model("UVR-MDX-NET-Inst_HQ_3.onnx")

print("Downloading speech recognition model...", flush=True)
WhisperModel("tiny", device="cpu", compute_type="int8", download_root=str(whisper_models))
print("Models are ready.", flush=True)
