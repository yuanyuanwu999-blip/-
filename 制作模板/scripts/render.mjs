import {mkdir, readFile, writeFile} from "node:fs/promises";
import {basename, dirname, extname, isAbsolute, join, resolve} from "node:path";
import {fileURLToPath} from "node:url";
import {spawn} from "node:child_process";
import {prepareAssets} from "./prepare-assets.mjs";
import {runComplianceCheck} from "./compliance-check.mjs";
import {runQualityCheck} from "./quality-check.mjs";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const appRoot = resolve(root, "..");
const stateDir = join(root, ".video-assistant");
const progressPath = join(stateDir, "progress.json");
await mkdir(stateDir, {recursive: true});

const writeProgress = async (progress, message, status = "running", extra = {}) => {
  await writeFile(progressPath, JSON.stringify({progress, message, status, updatedAt: new Date().toISOString(), ...extra}, null, 2), "utf8");
};

const arg = (name) => {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : null;
};

const runRemotion = ({args, progressStart, progressSpan, message}) => new Promise((resolveRender, reject) => {
  const child = spawn(process.execPath, args, {cwd: root, windowsHide: true});
  let stderr = "";
  const accept = (chunk, error = false) => {
    const value = chunk.toString("utf8");
    process[error ? "stderr" : "stdout"].write(value);
    if (error) stderr += value;
    for (const line of value.split(/\r?\n/)) {
      const match = /Rendered\s+(\d+)\/(\d+)/i.exec(line) || /(\d+)\/(\d+)\s*frames/i.exec(line);
      if (match) {
        const ratio = Number(match[1]) / Math.max(1, Number(match[2]));
        void writeProgress(Math.min(96, progressStart + Math.round(ratio * progressSpan)), `${message} ${Math.round(ratio * 100)}%`);
      }
    }
  };
  child.stdout.on("data", (chunk) => accept(chunk));
  child.stderr.on("data", (chunk) => accept(chunk, true));
  child.on("error", reject);
  child.on("close", (code) => code === 0 ? resolveRender() : reject(new Error(stderr || `渲染失败 ${code}`)));
});

const runContentAudit = ({videoPath, config}) => new Promise((resolveAudit, reject) => {
  const python = join(appRoot, "runtime", "audio-processing", "Scripts", "python.exe");
  const transcript = isAbsolute(config.voiceover.sourcePath) ? config.voiceover.sourcePath : resolve(root, config.voiceover.sourcePath);
  const child = spawn(python, [
    join(root, "scripts", "content-audit.py"),
    "--video", videoPath,
    "--transcript", transcript,
    "--rules", join(root, "compliance-rules.json"),
    "--ffmpeg", join(appRoot, "runtime", "ffmpeg-full", "bin", "ffmpeg.exe"),
    "--whisper-dir", join(appRoot, "runtime", "whisper-models"),
    "--output-dir", join(root, "输出", "审核报告"),
    "--product", String(config.productName),
  ], {cwd: root, windowsHide: true, env: {
    ...process.env,
    PYTHONUTF8: "1",
    PYTHONIOENCODING: "utf-8",
  }});
  let stdout = "";
  let stderr = "";
  const accept = (chunk, error = false) => {
    const value = chunk.toString("utf8");
    process[error ? "stderr" : "stdout"].write(value);
    if (error) stderr += value;
    else stdout += value;
    for (const line of value.split(/\r?\n/)) {
      const progress = /^PROGRESS:(\d+):(.*)$/.exec(line.trim());
      if (progress) void writeProgress(Number(progress[1]), progress[2]);
    }
  };
  child.stdout.on("data", (chunk) => accept(chunk));
  child.stderr.on("data", (chunk) => accept(chunk, true));
  child.on("error", reject);
  child.on("close", (code) => {
    const jsonLine = stdout.split(/\r?\n/).reverse().find((line) => line.trim().startsWith("{"));
    let report = null;
    try { report = jsonLine ? JSON.parse(jsonLine) : null; } catch {}
    if (code === 0 && report) resolveAudit(report);
    else if (code === 2) reject(new Error("成片画面中发现必须修改的敏感内容，请查看内容复核报告"));
    else reject(new Error(stderr || "成片内容复核未能完成"));
  });
});

try {
  await writeProgress(1, "正在启动制作任务");
  const baseConfig = JSON.parse(await readFile(join(root, "video.config.json"), "utf8"));
  await writeProgress(2, "正在进行文案合规初审");
  const compliance = await runComplianceCheck({
    textPath: baseConfig.voiceover.sourcePath,
    outputDir: join(root, "输出", "审核报告"),
    productName: baseConfig.productName,
  });
  if (compliance.result === "blocked") {
    throw new Error(`合规初审发现 ${compliance.summary.block} 项必须修改内容，请先打开合规报告处理`);
  }

  const config = await prepareAssets({onProgress: (progress, message) => writeProgress(Math.max(4, progress), message)});
  const isPreview = process.argv.includes("--preview");
  const isReview = process.argv.includes("--review");
  const selectedPlatform = isPreview ? "preview" : (isReview ? "universal" : (arg("--platform") ?? config.export?.platform ?? "universal"));
  const presets = config.export?.presets ?? {universal: {label: "通用高清", crf: 15}};
  const platformKeys = selectedPlatform === "all" ? Object.keys(presets) : [selectedPlatform];
  const configured = isAbsolute(config.outputPath) ? config.outputPath : resolve(root, config.outputPath);
  const configuredExtension = extname(configured) || ".mp4";
  const overrideOutput = arg("--output");
  const timestamp = new Date().toISOString().replace(/[-:]/g, "").replace("T", "_").slice(0, 15);
  const cli = join(root, "node_modules", "@remotion", "cli", "remotion-cli.js");
  const outputs = [];
  const qualityReports = [];
  const contentAudits = [];

  for (let index = 0; index < platformKeys.length; index++) {
    const platformKey = platformKeys[index];
    const preset = isPreview ? {label: "预览", crf: 23} : presets[platformKey];
    if (!preset) throw new Error(`找不到导出平台预设：${platformKey}`);
    let output;
    if (overrideOutput) {
      const absoluteOverride = isAbsolute(overrideOutput) ? overrideOutput : resolve(root, overrideOutput);
      output = platformKeys.length === 1
        ? absoluteOverride
        : join(dirname(absoluteOverride), `${basename(absoluteOverride, extname(absoluteOverride))}_${preset.label}${extname(absoluteOverride) || ".mp4"}`);
    } else if (isPreview) {
      output = join(dirname(configured), "预览", `${basename(configured, configuredExtension)}_预览_${timestamp}${configuredExtension}`);
    } else {
      output = join(dirname(configured), "平台成片", `${basename(configured, configuredExtension)}_${preset.label}_${timestamp}${configuredExtension}`);
    }

    await mkdir(dirname(output), {recursive: true});
    const progressStart = 65 + Math.round(index / platformKeys.length * 28);
    const progressSpan = Math.max(3, Math.round(28 / platformKeys.length));
    const renderArgs = [
      cli, "render", "src/index.ts", config.compositionId, output,
      "--codec=h264", "--audio-codec=aac", "--pixel-format=yuv420p",
      `--crf=${preset.crf ?? (isPreview ? 23 : 16)}`,
      ...(isPreview ? ["--scale=0.5"] : []),
      "--timeout=240000",
      "--concurrency=1",
      "--overwrite",
    ];
    const renderLabel = isPreview ? "预览" : (isReview ? "高清待审核成片" : preset.label);
    await writeProgress(progressStart, `正在生成${renderLabel}`);
    await runRemotion({args: renderArgs, progressStart, progressSpan, message: `正在生成${renderLabel}`});
    await writeProgress(Math.min(97, progressStart + progressSpan), `正在检查${preset.label}视频质量`);
    const quality = await runQualityCheck({videoPath: output, config, isPreview, outputDir: join(root, "输出", "审核报告")});
    outputs.push(output);
    qualityReports.push({platform: platformKey, result: quality.result, report: quality.textReportPath});
    if (quality.result === "failed") throw new Error(`${preset.label}视频质量检查未通过，请查看质量检查报告`);
    if (!isPreview) {
      await writeProgress(98, `正在复核${preset.label}成片内容`);
      const audit = await runContentAudit({videoPath: output, config});
      contentAudits.push({platform: platformKey, result: audit.result, report: audit.textReportPath});
    }
  }

  await writeProgress(100, isReview ? "高清待审核成片制作完成" : "制作完成", "complete", {
    output: outputs[0],
    outputs,
    mode: isPreview ? "Preview" : (isReview ? "Review" : "Final"),
    platform: selectedPlatform,
    complianceReport: compliance.textReportPath,
    qualityReports,
    contentAudits,
  });
  for (const output of outputs) console.log(`OUTPUT:${output}`);
} catch (error) {
  await writeProgress(0, `制作失败：${error?.message || error}`, "failed");
  console.error(error);
  process.exit(1);
}
