import {mkdir, readFile, stat, statfs, writeFile} from "node:fs/promises";
import {cpus, totalmem} from "node:os";
import {dirname, isAbsolute, join, resolve} from "node:path";
import {fileURLToPath} from "node:url";
import {spawnSync} from "node:child_process";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const appRoot = resolve(root, "..");
const arg = (name) => {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : null;
};
const fromRoot = (value) => isAbsolute(value) ? value : resolve(root, value);
const items = [];
const add = (level, name, passed, detail) => items.push({level: passed ? "pass" : level, name, passed, detail});
const exists = async (path) => {
  try { return await stat(path); } catch { return null; }
};

const configPath = arg("--config") ?? join(root, "video.config.json");
const mode = arg("--mode") ?? "Preview";
const platform = arg("--platform") ?? "universal";
const reportDir = arg("--output-dir") ?? join(root, "输出", "审核报告");
const config = JSON.parse(await readFile(configPath, "utf8"));
const ffprobe = join(appRoot, "runtime", "ffmpeg-full", "bin", "ffprobe.exe");
const ffmpeg = join(appRoot, "runtime", "ffmpeg-full", "bin", "ffmpeg.exe");
let inputBytes = 0;

for (const key of ["a", "b"]) {
  const path = fromRoot(config.segments?.[key]?.sourcePath ?? "");
  const info = await exists(path);
  add("fail", `${key.toUpperCase()}段素材`, Boolean(info?.isFile() && info.size > 10_000), info ? `${path}（${(info.size / 1024 / 1024).toFixed(1)}MB）` : `文件不存在：${path}`);
  if (!info) continue;
  inputBytes += info.size;
  const probe = spawnSync(ffprobe, ["-v", "error", "-show_entries", "stream=codec_type,width,height,r_frame_rate:format=duration", "-of", "json", path], {encoding: "utf8", windowsHide: true});
  if (probe.status !== 0) {
    add("fail", `${key.toUpperCase()}段可读取性`, false, "视频损坏、格式不支持或无法读取");
    continue;
  }
  const metadata = JSON.parse(probe.stdout);
  const video = metadata.streams?.find((stream) => stream.codec_type === "video");
  const duration = Number(metadata.format?.duration ?? 0);
  add("fail", `${key.toUpperCase()}段视频轨道`, Boolean(video && duration > 0.2), video ? `${video.width}×${video.height}，${duration.toFixed(2)}秒` : "没有有效视频轨道");
  const decode = spawnSync(ffmpeg, [
    "-v", "error",
    "-i", path,
    "-map", "0:v:0",
    "-an",
    "-f", "null",
    "-",
  ], {encoding: "utf8", windowsHide: true, maxBuffer: 8 * 1024 * 1024});
  add("fail", `${key.toUpperCase()}段实际解码`, decode.status === 0, decode.status === 0
    ? "全段逐帧解码通过，导入后将自动统一为稳定格式"
    : `素材包含无法解码的画面：${String(decode.stderr || "").trim().slice(0, 300)}`);
}

const transcriptPath = fromRoot(config.voiceover?.sourcePath ?? "");
const transcriptInfo = await exists(transcriptPath);
let transcript = "";
if (transcriptInfo) transcript = await readFile(transcriptPath, "utf8");
add("fail", "配音稿", Boolean(transcriptInfo && transcript.trim()), transcriptInfo ? `${transcript.split(/\r?\n/).filter((line) => line.trim()).length}句` : `文件不存在：${transcriptPath}`);

if (config.voiceover?.mode === "human") {
  const humanPath = fromRoot(config.voiceover.humanAudioPath ?? "");
  add("fail", "真人录音", Boolean(await exists(humanPath)), `录音文件：${humanPath}`);
} else {
  add("fail", "自然配音组件", Boolean(await exists(join(appRoot, "runtime", "edge-tts", "Scripts", "edge-tts.exe"))), "AI配音运行组件");
}

if (config.music?.mode === "auto" && config.music?.sourcePath) {
  const musicPath = fromRoot(config.music.sourcePath);
  add("fail", "背景音乐", Boolean(await exists(musicPath)), `音乐文件：${musicPath}`);
}
add("fail", "视频运行组件", Boolean(await exists(join(root, "node_modules", "@remotion", "cli", "remotion-cli.js"))) && Boolean(await exists(ffprobe)), "Remotion与视频检查组件");

await mkdir(reportDir, {recursive: true});
const disk = await statfs(reportDir);
const freeBytes = Number(disk.bavail) * Number(disk.bsize);
const platformCount = mode === "Final" && platform === "all" ? Object.keys(config.export?.presets ?? {}).length : 1;
const minimumBytes = Math.max(mode === "Final" ? 5 * 1024 ** 3 * platformCount : 2 * 1024 ** 3, inputBytes * (mode === "Final" ? 5 : 3));
add("fail", "磁盘剩余空间", freeBytes >= minimumBytes, `剩余${(freeBytes / 1024 ** 3).toFixed(1)}GB，建议至少${(minimumBytes / 1024 ** 3).toFixed(1)}GB`);
add("warn", "电脑内存", totalmem() >= 8 * 1024 ** 3, `总内存${(totalmem() / 1024 ** 3).toFixed(1)}GB，建议8GB以上`);
add("warn", "处理器", cpus().length >= 4, `${cpus().length}个逻辑处理器，建议4个以上`);

const failures = items.filter((item) => !item.passed && item.level === "fail");
const warnings = items.filter((item) => !item.passed && item.level === "warn");
const report = {
  productName: config.productName,
  checkedAt: new Date().toISOString(),
  mode,
  result: failures.length ? "failed" : warnings.length ? "warning" : "passed",
  summary: {fail: failures.length, warning: warnings.length, pass: items.filter((item) => item.passed).length},
  items,
};
const safeName = String(config.productName).replace(/[<>:"/\\|?*]/g, "_");
const jsonPath = join(reportDir, `${safeName}_生成前体检.json`);
const textReportPath = join(reportDir, `${safeName}_生成前体检.txt`);
await writeFile(jsonPath, JSON.stringify(report, null, 2), "utf8");
await writeFile(textReportPath, [
  `产品：${config.productName}`,
  `结果：${failures.length ? "不能开始" : warnings.length ? "可以开始但有提醒" : "通过"}`,
  "",
  ...items.map((item, index) => `${index + 1}. [${item.passed ? "通过" : item.level === "fail" ? "失败" : "提醒"}] ${item.name}：${item.detail}`),
].join("\r\n"), "utf8");
console.log(JSON.stringify({...report, jsonPath, textReportPath}));
if (failures.length) process.exitCode = 2;
