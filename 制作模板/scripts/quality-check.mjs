import {mkdir, readFile, writeFile} from "node:fs/promises";
import {dirname, join, resolve} from "node:path";
import {fileURLToPath} from "node:url";
import {spawnSync} from "node:child_process";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const ffmpeg = resolve(root, "..", "runtime", "ffmpeg-full", "bin", "ffmpeg.exe");
const ffprobe = resolve(root, "..", "runtime", "ffmpeg-full", "bin", "ffprobe.exe");
const run = (command, args) => spawnSync(command, args, {encoding: "utf8", windowsHide: true, maxBuffer: 64 * 1024 * 1024});
const check = (items, level, name, passed, detail, metric = null) => items.push({level: passed ? "pass" : level, name, passed, detail, metric});

export const runQualityCheck = async ({videoPath, config, isPreview = false, outputDir = join(root, "输出", "审核报告")}) => {
  const items = [];
  const probe = run(ffprobe, ["-v", "error", "-show_streams", "-show_format", "-of", "json", videoPath]);
  if (probe.status !== 0) throw new Error(`无法读取成片：${probe.stderr}`);
  const metadata = JSON.parse(probe.stdout);
  const video = metadata.streams.find((stream) => stream.codec_type === "video");
  const audio = metadata.streams.find((stream) => stream.codec_type === "audio");
  const duration = Number(metadata.format?.duration ?? 0);
  const expectedDuration = Number(config.totalSeconds ?? Object.values(config.segments).reduce((sum, item) => sum + Number(item.durationSeconds), 0));
  const expectedWidth = isPreview ? Math.round(config.width * 0.5) : config.width;
  const expectedHeight = isPreview ? Math.round(config.height * 0.5) : config.height;
  check(items, "fail", "视频轨道", Boolean(video), video ? `${video.codec_name} ${video.width}×${video.height}` : "缺少视频轨道");
  check(items, "fail", "音频轨道", Boolean(audio), audio ? `${audio.codec_name}` : "缺少音频轨道");
  check(items, "fail", "画面尺寸", video?.width === expectedWidth && video?.height === expectedHeight, `实际 ${video?.width ?? 0}×${video?.height ?? 0}，目标 ${expectedWidth}×${expectedHeight}`);
  check(items, "fail", "成片时长", Math.abs(duration - expectedDuration) <= 0.25, `实际 ${duration.toFixed(2)} 秒，目标 ${expectedDuration.toFixed(2)} 秒`, duration);

  const scan = run(ffmpeg, ["-hide_banner", "-i", videoPath, "-vf", "blackdetect=d=0.45:pix_th=0.08,freezedetect=n=-50dB:d=1.5", "-af", "silencedetect=n=-45dB:d=2.5,volumedetect", "-f", "null", "-"]);
  const diagnostic = `${scan.stdout ?? ""}\n${scan.stderr ?? ""}`;
  const blackMatches = [...diagnostic.matchAll(/black_start:([\d.]+).*?black_end:([\d.]+)/g)];
  const freezeMatches = [...diagnostic.matchAll(/freeze_start:\s*([\d.]+)/g)];
  const silenceMatches = [...diagnostic.matchAll(/silence_start:\s*([\d.]+)/g)];
  const maxVolume = /max_volume:\s*(-?[\d.]+) dB/.exec(diagnostic);
  const meanVolume = /mean_volume:\s*(-?[\d.]+) dB/.exec(diagnostic);
  check(items, "warn", "连续黑屏", blackMatches.length === 0, blackMatches.length ? `发现 ${blackMatches.length} 处连续黑屏` : "未发现连续黑屏", blackMatches.length);
  check(items, "warn", "异常定格", freezeMatches.length === 0, freezeMatches.length ? `发现 ${freezeMatches.length} 处超过1.5秒定格，请人工确认` : "未发现异常长定格", freezeMatches.length);
  check(items, "warn", "长时间静音", silenceMatches.length === 0, silenceMatches.length ? `发现 ${silenceMatches.length} 处超过2.5秒静音，请人工确认` : "未发现长时间静音", silenceMatches.length);
  const maxDb = maxVolume ? Number(maxVolume[1]) : null;
  const meanDb = meanVolume ? Number(meanVolume[1]) : null;
  check(items, "warn", "峰值音量", maxDb !== null && maxDb <= -0.1 && maxDb >= -12, maxDb === null ? "无法测量峰值音量" : `峰值 ${maxDb.toFixed(1)} dB`, maxDb);
  check(items, "warn", "平均音量", meanDb !== null && meanDb >= -32 && meanDb <= -8, meanDb === null ? "无法测量平均音量" : `平均 ${meanDb.toFixed(1)} dB`, meanDb);

  try {
    const captions = JSON.parse(await readFile(join(root, "public", "generated", "captions.json"), "utf8"));
    check(items, "fail", "字幕存在", captions.length > 0, `共 ${captions.length} 条字幕`);
    const invalidTiming = captions.filter((caption, index) => caption.startMs < 0 || caption.endMs <= caption.startMs || (index > 0 && caption.startMs < captions[index - 1].endMs));
    check(items, "fail", "字幕时间", invalidTiming.length === 0, invalidTiming.length ? `${invalidTiming.length} 条字幕时间异常或重叠` : "字幕时间正常", invalidTiming.length);
    const punctuation = captions.filter((caption) => /[，。！？：；、“”‘’（）《》【】…,.!?;:'"()[\]{}<>]/.test(caption.text));
    check(items, "warn", "字幕标点", punctuation.length === 0, punctuation.length ? `${punctuation.length} 条字幕仍有标点` : "字幕已删除标点", punctuation.length);
    const longCaptions = captions.filter((caption) => caption.text.replace(/\s/g, "").length > 20);
    check(items, "warn", "字幕长度", longCaptions.length === 0, longCaptions.length ? `${longCaptions.length} 条字幕超过20字` : "字幕长度正常", longCaptions.length);
    check(items, "warn", "字幕安全区", Number(config.captions?.bottom ?? 0) >= 120, `底部距离 ${config.captions?.bottom ?? 0}px`);
  } catch (error) {
    check(items, "fail", "字幕文件", false, `字幕检查失败：${error.message}`);
  }

  try {
    const sourceAudioReport = JSON.parse(await readFile(join(root, "public", "generated", "source-audio-report.json"), "utf8"));
    const unsafe = Object.values(sourceAudioReport.segments ?? {}).filter((segment) => segment.status !== "environment-preserved" && segment.status !== "muted");
    check(items, "fail", "原人声处理", unsafe.length === 0, unsafe.length ? "存在未经安全处理的原音轨" : "原音轨均已分离检测或安全静音");
  } catch (error) {
    check(items, "fail", "原人声报告", false, `无法读取原人声处理报告：${error.message}`);
  }

  const failCount = items.filter((item) => !item.passed && item.level === "fail").length;
  const warningCount = items.filter((item) => !item.passed && item.level === "warn").length;
  const report = {
    productName: config.productName,
    checkedAt: new Date().toISOString(),
    videoPath,
    result: failCount ? "failed" : warningCount ? "manual-review" : "passed",
    summary: {fail: failCount, warning: warningCount, pass: items.filter((item) => item.passed).length},
    metadata: {duration, width: video?.width, height: video?.height, videoCodec: video?.codec_name, audioCodec: audio?.codec_name, maxVolumeDb: maxDb, meanVolumeDb: meanDb},
    items,
  };
  await mkdir(outputDir, {recursive: true});
  const safeName = String(config.productName).replace(/[<>:"/\\|?*]/g, "_");
  const suffix = isPreview ? "预览" : "成片";
  const jsonPath = join(outputDir, `${safeName}_${suffix}_质量检查.json`);
  const textReportPath = join(outputDir, `${safeName}_${suffix}_质量检查.txt`);
  const levelLabel = {pass: "通过", warn: "需复核", fail: "不通过"};
  const text = [
    `产品：${config.productName}`,
    `文件：${videoPath}`,
    `结果：${report.result === "passed" ? "通过" : report.result === "failed" ? "不通过" : "需要人工复核"}`,
    `失败：${failCount}；提醒：${warningCount}`,
    "",
    ...items.map((item, index) => `${index + 1}. [${levelLabel[item.passed ? "pass" : item.level]}] ${item.name}：${item.detail}`),
  ].join("\r\n");
  await writeFile(jsonPath, JSON.stringify(report, null, 2), "utf8");
  await writeFile(textReportPath, text, "utf8");
  return {...report, jsonPath, textReportPath};
};

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const videoIndex = process.argv.indexOf("--video");
  const configIndex = process.argv.indexOf("--config");
  if (videoIndex < 0) throw new Error("需要 --video 参数");
  const config = JSON.parse(await readFile(configIndex >= 0 ? process.argv[configIndex + 1] : join(root, "video.config.json"), "utf8"));
  const report = await runQualityCheck({videoPath: process.argv[videoIndex + 1], config, isPreview: process.argv.includes("--preview")});
  console.log(JSON.stringify(report));
  if (report.result === "failed") process.exitCode = 2;
}
