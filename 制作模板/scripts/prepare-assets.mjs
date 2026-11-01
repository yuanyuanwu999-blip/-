import {createHash} from "node:crypto";
import {createReadStream} from "node:fs";
import {access, copyFile, mkdir, readFile, readdir, rename, rm, writeFile} from "node:fs/promises";
import {dirname, isAbsolute, join, resolve} from "node:path";
import {fileURLToPath} from "node:url";
import {spawn} from "node:child_process";
import {ALL_FORMATS, FilePathSource, Input} from "mediabunny";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const appRoot = resolve(root, "..");
const fromRoot = (path) => isAbsolute(path) ? path : resolve(root, path);
const mediaDurationMs = async (path) => {
  const input = new Input({formats: ALL_FORMATS, source: new FilePathSource(path)});
  try { return Math.round(await input.computeDuration() * 1000); }
  finally { input.dispose(); }
};
const clean = (text) => text.replace(/[，。！？：；、“”‘’（）《》【】…,.!?;:'"()[\]{}<>]/g, " ").replace(/\s+/g, " ").trim();
const visibleLength = (text) => Array.from(clean(text).replace(/\s+/g, "")).length;
const splitNaturalPhrases = (text) => {
  const normalized = text.replace(/^>\s*/, "").trim();
  if (!normalized) return [];
  const clauses = normalized.match(/[^，。！？；：,.!?;:]+[，。！？；：,.!?;:]?/g)?.map((item) => item.trim()).filter(Boolean) ?? [normalized];
  const pieces = [];
  for (const clause of clauses) {
    if (visibleLength(clause) <= 16) {
      pieces.push(clause);
      continue;
    }
    const ending = /[，。！？；：,.!?;:]$/.exec(clause)?.[0] ?? "";
    const core = ending ? clause.slice(0, -1) : clause;
    const parts = core.split("、").map((item) => item.trim()).filter(Boolean);
    let current = "";
    for (const part of parts) {
      const candidate = current ? `${current}、${part}` : part;
      if (current && visibleLength(candidate) > 16) {
        pieces.push(current);
        current = part;
      } else current = candidate;
    }
    if (current) {
      const characters = Array.from(current);
      while (characters.length > 16) pieces.push(characters.splice(0, 14).join(""));
      if (characters.length) pieces.push(characters.join("") + ending);
      else if (ending && pieces.length) pieces[pieces.length - 1] += ending;
    }
  }
  const merged = [];
  for (const piece of pieces) {
    const previous = merged[merged.length - 1];
    if (previous && visibleLength(previous + piece) <= 14) merged[merged.length - 1] = previous + piece;
    else merged.push(piece);
  }
  return merged;
};
const formatCaption = (text) => {
  const cleaned = clean(text);
  const characters = Array.from(cleaned.replace(/\s+/g, ""));
  if (characters.length <= 14) return characters.join("");
  const lineCount = Math.min(3, Math.ceil(characters.length / 14));
  const lineLength = Math.ceil(characters.length / lineCount);
  const words = cleaned.split(/\s+/).filter(Boolean);
  if (words.length > 1) {
    const semanticLines = [];
    let current = "";
    for (const word of words) {
      const remainingSlots = lineCount - semanticLines.length - 1;
      if (current && current.length + word.length > lineLength && remainingSlots > 0) {
        semanticLines.push(current);
        current = word;
      } else current += word;
    }
    if (current) semanticLines.push(current);
    if (semanticLines.length <= lineCount && semanticLines.every((line) => {
      const length = Array.from(line).length;
      return length >= 4 && length <= 16;
    })) return semanticLines.join("\n");
  }
  const lines = [];
  for (let index = 0; index < characters.length; index += lineLength) lines.push(characters.slice(index, index + lineLength).join(""));
  return lines.join("\n");
};
const sha256File = async (path) => new Promise((resolveHash, reject) => {
  const hash = createHash("sha256");
  const stream = createReadStream(path);
  stream.on("data", (chunk) => hash.update(chunk));
  stream.on("error", reject);
  stream.on("end", () => resolveHash(hash.digest("hex")));
});
const sha256Text = (text) => createHash("sha256").update(text).digest("hex");
const sleep = (milliseconds) => new Promise((resolveSleep) => setTimeout(resolveSleep, milliseconds));
const run = (command, args, options = {}, onLine = () => {}) => new Promise((resolveRun, reject) => {
  const child = spawn(command, args, {...options, windowsHide: true});
  let stderr = "";
  const consume = (chunk, isError = false) => {
    const text = chunk.toString();
    if (isError) stderr += text;
    text.split(/\r?\n/).filter(Boolean).forEach(onLine);
  };
  child.stdout?.on("data", (chunk) => consume(chunk));
  child.stderr?.on("data", (chunk) => consume(chunk, true));
  child.on("error", reject);
  child.on("close", (code) => code === 0 ? resolveRun() : reject(new Error(stderr || `命令执行失败 ${code}`)));
});

const prepareBrowserVideo = async ({source, key, fps, generated, onProgress}) => {
  const ffmpeg = join(appRoot, "runtime", "ffmpeg-full", "bin", "ffmpeg.exe");
  const sourceHash = await sha256File(source);
  const cacheKey = sha256Text(`remotion-browser-video-v2:${sourceHash}:fps=${fps}`);
  const cacheFolder = join(appRoot, "runtime", "video-cache", cacheKey);
  const cachedVideo = join(cacheFolder, "video.mp4");
  const readyMarker = join(cacheFolder, "ready.json");
  const destination = join(generated, `${key}.mp4`);
  await mkdir(cacheFolder, {recursive: true});

  let cacheHit = false;
  try {
    await access(cachedVideo);
    await access(readyMarker);
    cacheHit = true;
  } catch {
    await rm(cachedVideo, {force: true});
    await rm(readyMarker, {force: true});
    await onProgress(`${key.toUpperCase()}段首次导入，正在转换为稳定视频格式`);
    await run(ffmpeg, [
      "-y",
      "-v", "warning",
      "-i", source,
      "-map", "0:v:0",
      "-an",
      "-vf", `scale=trunc(iw/2)*2:trunc(ih/2)*2,fps=${fps}`,
      "-c:v", "libx264",
      "-preset", "fast",
      "-crf", "12",
      "-pix_fmt", "yuv420p",
      "-profile:v", "high",
      "-movflags", "+faststart",
      "-fps_mode", "cfr",
      cachedVideo,
    ], {cwd: root});
    await run(ffmpeg, [
      "-v", "error",
      "-i", cachedVideo,
      "-map", "0:v:0",
      "-an",
      "-f", "null",
      "-",
    ], {cwd: root});
    await writeFile(readyMarker, JSON.stringify({
      source,
      sourceHash,
      fps,
      createdAt: new Date().toISOString(),
    }, null, 2), "utf8");
  }

  await copyFile(cachedVideo, destination);
  await onProgress(cacheHit
    ? `${key.toUpperCase()}段已使用兼容视频缓存`
    : `${key.toUpperCase()}段稳定格式转换并解码检查通过`);
  return `generated/${key}.mp4`;
};

const isRetryableTtsError = (error) => /(?:\b429\b|\b5\d\d\b|WSServerHandshakeError|websocket|temporar|timeout|timed out|ECONNRESET|ECONNREFUSED|EAI_AGAIN|network|connection|SSL)/i
  .test(String(error?.message || error));

const generateEdgeTtsWithRetry = async ({edgeTts, text, voice, rate, pitch, output, onProgress}) => {
  const retryDelaysMs = [2000, 5000, 10000];
  let lastError;
  for (let attempt = 0; attempt <= retryDelaysMs.length; attempt++) {
    await rm(output, {force: true});
    try {
      await run(edgeTts, [
        "--text", text,
        "--voice", voice,
        "--rate", rate,
        "--pitch", pitch,
        "--write-media", output,
      ]);
      await access(output);
      return;
    } catch (error) {
      lastError = error;
      // A 403 means Microsoft is actively refusing the free Read Aloud socket.
      // Retrying the identical request only delays the job; use the natural
      // online fallback below instead.
      if (/\b403\b/.test(String(error?.message || error))) break;
      if (attempt >= retryDelaysMs.length || !isRetryableTtsError(error)) break;
      const delayMs = retryDelaysMs[attempt];
      await onProgress(`配音服务暂时繁忙，${Math.round(delayMs / 1000)}秒后重试（${attempt + 2}/${retryDelaysMs.length + 1}）`);
      await sleep(delayMs);
    }
  }
  const detail = String(lastError?.message || lastError).replace(/\s+/g, " ").trim();
  throw new Error(`AI配音服务连续请求失败，请稍后点击“失败后重试”。原因：${detail}`);
};

const generateGoogleNaturalTts = async ({gttsCli, ffmpeg, text, rate, output}) => {
  const rawOutput = `${output}.google-raw.mp3`;
  await rm(rawOutput, {force: true});
  await rm(output, {force: true});
  await run(gttsCli, [text, "--lang", "zh-CN", "--output", rawOutput]);
  const percent = Number.parseFloat(String(rate || "+0%").replace("%", "")) || 0;
  const tempo = Math.max(0.8, Math.min(1.25, 1 + percent / 100));
  await run(ffmpeg, [
    "-y", "-v", "warning", "-i", rawOutput,
    "-filter:a", `atempo=${tempo.toFixed(3)}`,
    "-c:a", "libmp3lame", "-b:a", "128k", output,
  ]);
  await access(output);
  await rm(rawOutput, {force: true});
};

// Keep a short segment intact and take only the remaining time from the longer
// segment. A and B are never forced to be ten seconds each.
export const allocateTimeline = ({aSeconds, bSeconds, targetSeconds, requestedTransitionSeconds = 0.35}) => {
  const sourceA = Number(aSeconds);
  const sourceB = Number(bSeconds);
  const target = Number(targetSeconds);
  if (![sourceA, sourceB, target].every(Number.isFinite) || sourceA <= 0 || sourceB <= 0 || target <= 0) {
    throw new Error("A段、B段和成片时长必须大于0秒");
  }
  const sourceTotal = sourceA + sourceB;
  const shortfall = Math.max(0, target - sourceTotal);
  const encodingTolerance = Math.min(0.5, target * 0.025);
  if (shortfall > encodingTolerance + 0.001) {
    throw new Error(`A段和B段合计只有${sourceTotal.toFixed(1)}秒，无法制作${target.toFixed(0)}秒成片；请补充素材`);
  }
  // Phone and platform videos often report a few missing frames. Allow at most
  // half a second of imperceptible compensation, never a visibly slowed clip.
  const videoPlaybackRate = shortfall > 0 ? sourceTotal / target : 1;
  const effectiveA = sourceA / videoPlaybackRate;
  const effectiveB = sourceB / videoPlaybackRate;
  const effectiveTotal = effectiveA + effectiveB;
  // A transition consumes overlapping source time. Reduce it automatically
  // when there is no spare footage instead of slowing either source video.
  const transitionSeconds = Math.max(0, Math.min(
    Number(requestedTransitionSeconds) || 0,
    target * 0.1,
    Math.max(0, effectiveTotal - target),
    effectiveA,
    effectiveB,
  ));
  const contentSeconds = target + transitionSeconds;
  const half = contentSeconds / 2;
  let timelineASeconds = Math.min(effectiveA, half);
  let timelineBSeconds = Math.min(effectiveB, half);
  let remaining = contentSeconds - timelineASeconds - timelineBSeconds;
  const spareA = () => Math.max(0, effectiveA - timelineASeconds);
  const spareB = () => Math.max(0, effectiveB - timelineBSeconds);
  if (remaining > 0.0001) {
    if (spareA() >= spareB()) {
      const addA = Math.min(remaining, spareA()); timelineASeconds += addA; remaining -= addA;
      const addB = Math.min(remaining, spareB()); timelineBSeconds += addB; remaining -= addB;
    } else {
      const addB = Math.min(remaining, spareB()); timelineBSeconds += addB; remaining -= addB;
      const addA = Math.min(remaining, spareA()); timelineASeconds += addA; remaining -= addA;
    }
  }
  if (remaining > 0.001) throw new Error(`A段和B段合计只有${sourceTotal.toFixed(1)}秒，无法制作${target.toFixed(0)}秒成片；请补充素材`);
  return {
    targetSeconds: target,
    transitionSeconds,
    aSeconds: timelineASeconds,
    bSeconds: timelineBSeconds,
    bStartSeconds: timelineASeconds - transitionSeconds,
    trimStrategy: "preserve-short-fill-from-long",
    videoPlaybackRate,
  };
};

export const prepareAssets = async ({onProgress = async () => {}} = {}) => {
  const config = JSON.parse(await readFile(join(root, "video.config.json"), "utf8"));
  const generated = join(root, "public", "generated");
  await rm(generated, {recursive: true, force: true});
  await mkdir(generated, {recursive: true});
  await onProgress(4, "正在整理视频素材");
  const assets = {};
  for (const [key, segment] of Object.entries(config.segments)) {
    const source = fromRoot(segment.sourcePath);
    assets[key] = await prepareBrowserVideo({
      source,
      key,
      fps: config.fps,
      generated,
      onProgress: (message) => onProgress(key === "a" ? 7 : 11, message),
    });
  }

  const audioReport = join(generated, "source-audio-report.json");
  const manifestPath = join(generated, "source-audio-manifest.json");
  const environment = {
    a: join(generated, "environment-a.wav"),
    b: join(generated, "environment-b.wav"),
  };
  const audioCacheRoot = join(appRoot, "runtime", "audio-cache");
  await mkdir(audioCacheRoot, {recursive: true});
  const audioSegments = {};
  const missingAudioSegments = [];
  const cacheLocations = {};
  for (const key of ["a", "b"]) {
    const source = fromRoot(config.segments[key].sourcePath);
    const sourceHash = await sha256File(source);
    const cacheKey = sha256Text(`source-separation-v2:${sourceHash}`);
    const cacheFolder = join(audioCacheRoot, cacheKey);
    const cacheReport = join(cacheFolder, "report.json");
    const cacheEnvironment = join(cacheFolder, "environment.wav");
    cacheLocations[key] = {cacheFolder, cacheReport, cacheEnvironment};
    try {
      const segmentReport = JSON.parse(await readFile(cacheReport, "utf8"));
      if (segmentReport.status === "environment-preserved") await copyFile(cacheEnvironment, environment[key]);
      audioSegments[key] = {...segmentReport, cache: "hit"};
      await onProgress(key === "a" ? 20 : 36, `${key.toUpperCase()}段复用已审核原声缓存`);
    } catch {
      missingAudioSegments.push({key, source, output: environment[key]});
    }
  }
  await writeFile(manifestPath, JSON.stringify({segments: missingAudioSegments}, null, 2), "utf8");

  if (missingAudioSegments.length) try {
    const python = join(appRoot, "runtime", "audio-processing", "Scripts", "python.exe");
    const ffmpeg = join(root, "node_modules", "@remotion", "compositor-win32-x64-msvc", "ffmpeg.exe");
    const runReportPath = join(generated, "source-audio-run-report.json");
    await access(python);
    await run(python, [
      join(root, "scripts", "separate-source-audio.py"),
      "--manifest", manifestPath,
      "--ffmpeg", ffmpeg,
      "--model-dir", join(appRoot, "runtime", "audio-models"),
      "--whisper-dir", join(appRoot, "runtime", "whisper-models"),
      "--report", runReportPath,
    ], {cwd: root, env: {
      ...process.env,
      PATH: `${dirname(ffmpeg)};${process.env.PATH ?? ""}`,
      PYTHONUTF8: "1",
      PYTHONIOENCODING: "utf-8",
    }}, async (line) => {
      const match = /^PROGRESS:(\d+):(.*)$/.exec(line);
      if (match) await onProgress(Number(match[1]), match[2]);
    });
    const runReport = JSON.parse(await readFile(runReportPath, "utf8"));
    for (const item of missingAudioSegments) {
      const segmentReport = runReport.segments?.[item.key] ?? {status: "muted", reason: "处理报告缺失 已安全静音", speech: []};
      audioSegments[item.key] = {...segmentReport, cache: "created"};
      const cache = cacheLocations[item.key];
      await mkdir(cache.cacheFolder, {recursive: true});
      await writeFile(cache.cacheReport, JSON.stringify(segmentReport, null, 2), "utf8");
      if (segmentReport.status === "environment-preserved") await copyFile(environment[item.key], cache.cacheEnvironment);
    }
  } catch (error) {
    for (const item of missingAudioSegments) {
      audioSegments[item.key] = {status: "muted", reason: "原声处理异常 已安全静音", speech: [], error: String(error?.message || error), cache: "fallback"};
    }
    await onProgress(48, "原声处理未通过 已自动完全静音");
  }
  await writeFile(audioReport, JSON.stringify({policy: "separate-detect-or-mute", segments: audioSegments}, null, 2), "utf8");
  for (const key of ["a", "b"]) {
    try {
      await access(environment[key]);
      assets[`environment${key.toUpperCase()}`] = `generated/environment-${key}.wav`;
    } catch {
      assets[`environment${key.toUpperCase()}`] = null;
    }
  }
  if (config.voiceover.mode === "source") {
    const sourceFfmpeg = join(appRoot, "runtime", "ffmpeg-full", "bin", "ffmpeg.exe");
    for (const key of ["a", "b"]) {
      const source = fromRoot(config.segments[key].sourcePath);
      try {
        await run(sourceFfmpeg, ["-y", "-v", "warning", "-i", source, "-vn", "-ac", "2", "-ar", "48000", "-c:a", "pcm_s16le", environment[key]]);
        assets[`environment${key.toUpperCase()}`] = `generated/environment-${key}.wav`;
      } catch {
        assets[`environment${key.toUpperCase()}`] = null;
      }
    }
    await writeFile(audioReport, JSON.stringify({policy: "preserve-original-speech", message: "AI配音已关闭，保留素材原口播"}, null, 2), "utf8");
  }
  assets.sourceAudioReport = "generated/source-audio-report.json";

  const scriptLines = (await readFile(fromRoot(config.voiceover.sourcePath), "utf8"))
    .split(/\r?\n/).map((line) => line.trim()).filter((line) => line && !line.startsWith("#"));
  // Short display units only: the original scriptLines still drive continuous TTS.
  const splitLines = scriptLines.flatMap(splitNaturalPhrases);
  const lines = [];
  for (const piece of splitLines) {
    // Do not leave a tiny grammatical tail such as “的状态” on its own.
    // It creates an unnatural pause in captions and previously also affected TTS.
    if (lines.length && visibleLength(piece) <= 5 && visibleLength(lines[lines.length - 1] + piece) <= 18) lines[lines.length - 1] += piece;
    else lines.push(piece);
  }
  if (lines.length === 0) throw new Error("配音稿没有可用文字");
  const voiceoverSegments = [];
  const captions = [];
  const startMs = Number(config.voiceover.startMs ?? 120);
  const gapMs = Math.max(90, Number(config.voiceover.gapMs ?? 100));
  let cursorMs = startMs;

  await onProgress(50, config.voiceover.mode === "source" ? "AI配音已关闭，正在保留素材原口播并匹配字幕" : config.voiceover.mode === "human" ? "正在导入真人录音" : "正在生成自然配音");
  if (config.voiceover.mode === "source") {
    const targetMs = Number(config.duration?.targetSeconds ?? 15) * 1000;
    const weights = lines.map((line) => Math.max(1, visibleLength(line)));
    const totalWeight = weights.reduce((sum, value) => sum + value, 0);
    let captionCursor = 0;
    for (let index = 0; index < lines.length; index++) {
      const part = index === lines.length - 1 ? targetMs - captionCursor : Math.round(targetMs * weights[index] / totalWeight);
      captions.push({text: clean(lines[index]), startMs: captionCursor, endMs: captionCursor + part, timestampMs: null, confidence: null});
      captionCursor += part;
    }
    cursorMs = targetMs;
  } else if (config.voiceover.mode === "human") {
    if (!config.voiceover.humanAudioPath) throw new Error("已选择真人录音，但尚未导入音频文件");
    const source = fromRoot(config.voiceover.humanAudioPath);
    const name = `human-voice${extname(source).toLowerCase()}`;
    const target = join(generated, name);
    await copyFile(source, target);
    const length = await mediaDurationMs(target);
    voiceoverSegments.push({text: lines.join(" "), startMs, endMs: startMs + length, asset: `generated/${name}`});
    const weights = lines.map((line) => Math.max(1, clean(line).length));
    const totalWeight = weights.reduce((sum, value) => sum + value, 0);
    let captionCursor = startMs;
    for (let index = 0; index < lines.length; index++) {
      const part = index === lines.length - 1 ? startMs + length - captionCursor : Math.round(length * weights[index] / totalWeight);
      captions.push({text: clean(lines[index]), startMs: captionCursor, endMs: captionCursor + part, timestampMs: null, confidence: null});
      captionCursor += part;
    }
    cursorMs = startMs + length;
  } else {
    const voiceDir = join(generated, "voiceover");
    const ttsCacheDir = join(appRoot, "runtime", "tts-cache");
    await mkdir(voiceDir, {recursive: true});
    await mkdir(ttsCacheDir, {recursive: true});
    const edgeTts = join(appRoot, "runtime", "edge-tts", "Scripts", "edge-tts.exe");
    const gttsCli = join(appRoot, "runtime", "edge-tts", "Scripts", "gtts-cli.exe");
    const powershell = join(process.env.SystemRoot || "C:\\Windows", "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
    const systemTtsScript = join(root, "scripts", "generate-system-tts.ps1");
    const ffmpeg = join(root, "node_modules", "@remotion", "compositor-win32-x64-msvc", "ffmpeg.exe");
    const trimFfmpeg = join(appRoot, "runtime", "ffmpeg-full", "bin", "ffmpeg.exe");
    const edgeHealthPath = join(appRoot, "runtime", "edge-tts-health.json");
    // Generate the complete script in one online request. Splitting every sentence
    // into a separate audio file resets prosody and makes sentence endings sound cut off.
    await rm(voiceDir, {recursive: true, force: true});
    await mkdir(voiceDir, {recursive: true});
    // Use the untouched transcript for speech. Caption wrapping must never insert
    // pauses into the spoken sentence (for example “人 的状态”).
    const fullText = scriptLines.join(" ");
    const fullOutput = join(voiceDir, "voice-full.mp3");
    const fullCacheKey = sha256Text(JSON.stringify({text: fullText, voice: config.voiceover.voice, rate: config.voiceover.rate, pitch: config.voiceover.pitch, provider: "edge-online-full-v2"}));
    const fullCached = join(ttsCacheDir, `${fullCacheKey}.mp3`);
    const fallbackCacheKey = sha256Text(JSON.stringify({text: fullText, rate: config.voiceover.rate, provider: "google-natural-full-v1"}));
    const fallbackCached = join(ttsCacheDir, `${fallbackCacheKey}.mp3`);
    let usedNaturalFallback = false;
    try {
      await copyFile(fullCached, fullOutput);
      await onProgress(56, "正在复用整篇自然配音");
    } catch {
      await onProgress(52, "正在整篇生成自然配音");
      try {
        await generateEdgeTtsWithRetry({
          edgeTts, text: fullText, voice: config.voiceover.voice,
          rate: config.voiceover.rate, pitch: config.voiceover.pitch,
          output: fullOutput, onProgress: (message) => onProgress(54, message),
        });
      } catch {
        usedNaturalFallback = true;
        await onProgress(54, "微软自然配音暂时不可用，正在切换免费自然语音备用连接");
        try {
          await copyFile(fallbackCached, fullOutput);
        } catch {
          await generateGoogleNaturalTts({
            gttsCli, ffmpeg: trimFfmpeg, text: fullText,
            rate: config.voiceover.rate, output: fullOutput,
          });
          await copyFile(fullOutput, fallbackCached);
        }
      }
      if (!usedNaturalFallback) await copyFile(fullOutput, fullCached);
      await rm(edgeHealthPath, {force: true});
    }
    const fullLength = await mediaDurationMs(fullOutput);
    voiceoverSegments.push({text: fullText, startMs, endMs: startMs + fullLength, asset: "generated/voiceover/voice-full.mp3"});
    const captionWeights = lines.map((line) => Math.max(1, visibleLength(line)));
    const captionTotalWeight = captionWeights.reduce((sum, value) => sum + value, 0);
    let fullCaptionCursor = startMs;
    for (let index = 0; index < lines.length; index++) {
      const part = index === lines.length - 1 ? startMs + fullLength - fullCaptionCursor : Math.round(fullLength * captionWeights[index] / captionTotalWeight);
      captions.push({text: clean(lines[index]), startMs: fullCaptionCursor, endMs: fullCaptionCursor + part, timestampMs: null, confidence: null});
      fullCaptionCursor += part;
    }
    cursorMs = startMs + fullLength;

    if (false) {
    const records = lines.map((text, index) => {
      const baseName = `voice-${String(index + 1).padStart(2, "0")}`;
      const cacheKey = sha256Text(JSON.stringify({text, voice: config.voiceover.voice, rate: config.voiceover.rate, pitch: config.voiceover.pitch, provider: config.voiceover.provider}));
      return {
        text,
        index,
        output: join(voiceDir, `${baseName}.mp3`),
        fallbackWave: join(voiceDir, `${baseName}-system.wav`),
        cached: join(ttsCacheDir, `${cacheKey}.mp3`),
        fallbackCached: join(ttsCacheDir, `${cacheKey}-system.mp3`),
      };
    });
    let allEdgeCached = true;
    for (const record of records) {
      try { await access(record.cached); } catch { allEdgeCached = false; break; }
    }
    let edgeTtsUnavailable = false;
    if (false && !allEdgeCached) {
      try {
        const health = JSON.parse(await readFile(edgeHealthPath, "utf8"));
        edgeTtsUnavailable = Number(health.retryAfter ?? 0) > Date.now();
      } catch {}
    }

    if (!edgeTtsUnavailable) {
      for (const record of records) {
        try {
          await copyFile(record.cached, record.output);
          await onProgress(50 + Math.round((record.index / lines.length) * 12), `复用配音缓存 ${record.index + 1}/${lines.length}`);
        } catch {
          await onProgress(50 + Math.round((record.index / lines.length) * 12), `正在生成配音 ${record.index + 1}/${lines.length}`);
          try {
            await generateEdgeTtsWithRetry({
              edgeTts,
              text: record.text,
              voice: config.voiceover.voice,
              rate: config.voiceover.rate,
              pitch: config.voiceover.pitch,
              output: record.output,
              onProgress: (message) => onProgress(50 + Math.round((record.index / lines.length) * 12), message),
            });
            await copyFile(record.output, record.cached);
          } catch {
            edgeTtsUnavailable = true;
            await writeFile(edgeHealthPath, JSON.stringify({retryAfter: Date.now() + 5 * 60 * 1000}), "utf8");
            break;
          }
          if (record.index < lines.length - 1) await sleep(500);
        }
      }
      if (!edgeTtsUnavailable) await rm(edgeHealthPath, {force: true});
    }

    if (edgeTtsUnavailable) {
      throw new Error("在线自然配音暂时不可用，任务已停止；没有使用机械备用声音。请稍后重试。");
    }

    if (false && edgeTtsUnavailable) {
      // Keep one consistent voice across the entire clip if the online provider fails mid-job.
      await rm(voiceDir, {recursive: true, force: true});
      await mkdir(voiceDir, {recursive: true});
      for (const record of records) {
        try {
          await copyFile(record.fallbackCached, record.output);
          await onProgress(50 + Math.round((record.index / lines.length) * 12), `复用本机配音缓存 ${record.index + 1}/${lines.length}`);
        } catch {
          await onProgress(50 + Math.round((record.index / lines.length) * 12), `在线配音不可用，正在使用本机中文语音 ${record.index + 1}/${lines.length}`);
          await run(powershell, [
            "-NoProfile", "-ExecutionPolicy", "Bypass",
            "-File", systemTtsScript,
            "-Text", record.text,
            "-Output", record.fallbackWave,
            "-Rate", config.voiceover.rate,
          ]);
          try {
            await run(ffmpeg, ["-y", "-i", record.fallbackWave, "-vn", "-codec:a", "libmp3lame", "-q:a", "2", record.output]);
          } finally {
            await rm(record.fallbackWave, {force: true});
          }
          await copyFile(record.output, record.fallbackCached);
        }
      }
    }
    // Trim only outside silence. Internal pauses remain natural, while captions no
    // longer remain stuck on a sentence after speech has already ended.
    for (const record of records) {
      const trimmed = record.output.replace(/\.mp3$/i, "-trimmed.mp3");
      await run(trimFfmpeg, [
        "-y", "-i", record.output,
        "-af", "silenceremove=start_periods=1:start_duration=0.02:start_threshold=-50dB,areverse,silenceremove=start_periods=1:start_duration=0.05:start_threshold=-50dB,areverse,apad=pad_dur=0.04",
        "-codec:a", "libmp3lame", "-q:a", "2", trimmed,
      ]);
      await rm(record.output, {force: true});
      await rename(trimmed, record.output);
    }
    const voiceFiles = (await readdir(voiceDir)).filter((name) => /\.(?:mp3|wav|m4a|aac)$/i.test(name)).sort();
    for (let index = 0; index < voiceFiles.length; index++) {
      const file = voiceFiles[index];
      const length = await mediaDurationMs(join(voiceDir, file));
      const segmentStart = cursorMs;
      const endMs = segmentStart + length;
      const asset = `generated/voiceover/${file}`;
      voiceoverSegments.push({text: lines[index], startMs: segmentStart, endMs, asset});
      captions.push({text: clean(lines[index]), startMs: segmentStart, endMs, timestampMs: null, confidence: null});
      cursorMs = endMs + gapMs;
    }
    }
  }

  const sourceVideoSeconds = Object.values(config.segments).reduce((sum, item) => sum + Number(item.durationSeconds), 0);
  const rawVoiceEndMs = Math.max(startMs, ...voiceoverSegments.map((segment) => Number(segment.endMs ?? startMs)));
  const durationPolicy = config.voiceover.durationPolicy ?? {maxVoicePlaybackRate: 1.2, slowVideoWhenNeeded: true, minimumVideoPlaybackRate: 0.9};
  const targetSeconds = Number(config.duration?.targetSeconds ?? 15);
  if (!Number.isFinite(targetSeconds) || targetSeconds <= 0) throw new Error("成片目标时长必须大于0秒");
  const timeline = allocateTimeline({
    aSeconds: Number(config.segments.a.durationSeconds),
    bSeconds: Number(config.segments.b.durationSeconds),
    targetSeconds,
    requestedTransitionSeconds: Number(config.duration?.transitionSeconds ?? 0.35),
  });
  const videoPlaybackRate = timeline.videoPlaybackRate;
  let voiceoverPlaybackRate = 1;
  // Keep a short natural tail before the video ends instead of cutting the last syllable.
  const availableVoiceMs = targetSeconds * 1000 - 250;
  const maximumVoicePlaybackRate = Math.min(1.4, Number(durationPolicy.maxVoicePlaybackRate ?? 1.4));
  if (rawVoiceEndMs > availableVoiceMs) {
    voiceoverPlaybackRate = (rawVoiceEndMs - startMs) / Math.max(1, availableVoiceMs - startMs);
    if (voiceoverPlaybackRate > maximumVoicePlaybackRate + 0.001) throw new Error(`配音稿明显超过${targetSeconds.toFixed(0)}秒，适度提速到${maximumVoicePlaybackRate.toFixed(1)}倍仍无法自然讲完；请缩短文案，或关闭AI声音并保留素材原口播`);
  }
  voiceoverPlaybackRate = Math.max(1, Math.min(maximumVoicePlaybackRate, voiceoverPlaybackRate));
  if (voiceoverPlaybackRate > 1) {
    for (const segment of voiceoverSegments) {
      segment.startMs = startMs + (segment.startMs - startMs) / voiceoverPlaybackRate;
      segment.endMs = startMs + (segment.endMs - startMs) / voiceoverPlaybackRate;
    }
    for (const caption of captions) {
      caption.startMs = startMs + (caption.startMs - startMs) / voiceoverPlaybackRate;
      caption.endMs = startMs + (caption.endMs - startMs) / voiceoverPlaybackRate;
    }
  }
  for (const caption of captions) caption.text = formatCaption(caption.text);
  const totalSeconds = targetSeconds;
  await writeFile(join(generated, "captions.json"), JSON.stringify(captions, null, 2), "utf8");
  let backgroundMusic = null;
  if (config.music?.mode === "auto" && config.music?.sourcePath) {
    const musicPath = fromRoot(config.music.sourcePath);
    await access(musicPath);
    const preparedMusic = join(generated, "background-music.wav");
    const musicFfmpeg = join(appRoot, "runtime", "ffmpeg-full", "bin", "ffmpeg.exe");
    const fadeOutStart = Math.max(0, targetSeconds - 0.25).toFixed(3);
    await run(musicFfmpeg, [
      "-y", "-i", musicPath, "-t", String(targetSeconds),
      "-af", `silenceremove=start_periods=1:start_duration=0.12:start_threshold=-38dB,loudnorm=I=-18:TP=-1.5:LRA=7,afade=t=in:st=0:d=0.04,afade=t=out:st=${fadeOutStart}:d=0.25,apad`,
      "-ar", "44100", "-ac", "2", "-c:a", "pcm_s16le", preparedMusic,
    ]);
    backgroundMusic = "generated/background-music.wav";
  }
  await onProgress(64, "素材准备完成 正在构建视频");
  const generatedConfig = {...config, totalSeconds, sourceVideoSeconds, timeline, videoPlaybackRate, voiceoverPlaybackRate, sourceAudioMode: config.voiceover.mode === "source", assets: {...assets, captions: "generated/captions.json", backgroundMusic}, voiceoverSegments};
  await writeFile(join(root, "src", "generated-config.json"), JSON.stringify(generatedConfig, null, 2), "utf8");
  return generatedConfig;
};

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const config = await prepareAssets({onProgress: (progress, message) => console.log(`${progress}:${message}`)});
  console.log(JSON.stringify({totalSeconds: config.totalSeconds, productName: config.productName}));
}
