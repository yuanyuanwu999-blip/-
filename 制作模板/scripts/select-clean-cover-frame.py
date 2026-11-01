import json
import sys
from pathlib import Path

import cv2
import numpy as np


def text_score(path: Path) -> float:
    image = cv2.imread(str(path))
    if image is None:
        return 1e9
    h, w = image.shape[:2]
    # Existing short-video subtitles are normally in the center/lower area.
    roi = image[int(h * 0.32):int(h * 0.91), int(w * 0.05):int(w * 0.95)]
    gray = cv2.cvtColor(roi, cv2.COLOR_BGR2GRAY)
    edges = cv2.Canny(gray, 100, 210)
    # Join nearby glyph strokes into word-like horizontal components.
    joined = cv2.morphologyEx(edges, cv2.MORPH_CLOSE, np.ones((5, 19), np.uint8))
    contours, _ = cv2.findContours(joined, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    score = 0.0
    rh, rw = roi.shape[:2]
    for contour in contours:
        x, y, cw, ch = cv2.boundingRect(contour)
        if 10 <= ch <= rh * 0.12 and 18 <= cw <= rw * 0.88 and cw / max(ch, 1) >= 1.15:
            density = cv2.countNonZero(edges[y:y+ch, x:x+cw]) / max(1, cw * ch)
            if density > 0.055:
                score += (cw / rw) * (1.0 + density * 3.0)
    return round(score, 5)


folder = Path(sys.argv[1])
items = [{"path": str(path), "score": text_score(path), "size": path.stat().st_size}
         for path in folder.glob("frame-*.jpg")]
if not items:
    raise SystemExit("no candidate frames")
items.sort(key=lambda item: (item["score"], -item["size"]))
best = items[0]
best["needsCrop"] = best["score"] >= 0.38
print(json.dumps(best, ensure_ascii=False))
