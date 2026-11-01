import {createHash} from "node:crypto";
import {createReadStream} from "node:fs";
import {mkdir, readFile, stat, writeFile} from "node:fs/promises";
import {dirname, isAbsolute, resolve} from "node:path";
import {fileURLToPath} from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const arg = (name) => {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : null;
};
const fromRoot = (path) => isAbsolute(path) ? path : resolve(root, path);
const sha256File = async (path) => new Promise((resolveHash, reject) => {
  const hash = createHash("sha256");
  const stream = createReadStream(path);
  stream.on("data", (chunk) => hash.update(chunk));
  stream.on("error", reject);
  stream.on("end", () => resolveHash(hash.digest("hex")));
});
const canonical = (value) => {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === "object") return Object.fromEntries(Object.keys(value).sort().map((key) => [key, canonical(value[key])]));
  return value;
};
const contentSnapshot = (config) => canonical({
  productName: config.productName,
  width: config.width,
  height: config.height,
  fps: config.fps,
  segments: config.segments,
  voiceover: config.voiceover,
  audio: config.audio,
  music: config.music,
  captions: config.captions,
});
const snapshotHash = (snapshot) => createHash("sha256").update(JSON.stringify(snapshot)).digest("hex");
const collectFiles = (config) => {
  const values = [
    ["A段视频", config.segments?.a?.sourcePath],
    ["B段视频", config.segments?.b?.sourcePath],
    ["配音稿", config.voiceover?.sourcePath],
    ["真人录音", config.voiceover?.mode === "human" ? config.voiceover?.humanAudioPath : null],
    ["背景音乐", config.music?.mode !== "off" ? config.music?.sourcePath : null],
  ];
  return values.filter(([, path]) => path).map(([role, path]) => ({role, path: fromRoot(path)}));
};

export const createApprovalLock = async ({configPath, manifestPath, previewPath = null}) => {
  const config = JSON.parse(await readFile(configPath, "utf8"));
  const files = [];
  for (const item of collectFiles(config)) {
    const info = await stat(item.path);
    files.push({...item, size: info.size, modifiedAtMs: info.mtimeMs, sha256: await sha256File(item.path)});
  }
  if (previewPath) {
    const absolutePreview = fromRoot(previewPath);
    const info = await stat(absolutePreview);
    files.push({role: "审核预览", path: absolutePreview, size: info.size, modifiedAtMs: info.mtimeMs, sha256: await sha256File(absolutePreview)});
  }
  const snapshot = contentSnapshot(config);
  const manifest = {
    version: 1,
    productName: config.productName,
    approvedAt: new Date().toISOString(),
    contentConfigHash: snapshotHash(snapshot),
    contentConfig: snapshot,
    files,
  };
  await mkdir(dirname(manifestPath), {recursive: true});
  await writeFile(manifestPath, JSON.stringify(manifest, null, 2), "utf8");
  return {...manifest, manifestPath};
};

export const verifyApprovalLock = async ({manifestPath, configPath = null}) => {
  const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
  const changes = [];
  for (const item of manifest.files) {
    try {
      const info = await stat(item.path);
      if (info.size !== item.size) changes.push({role: item.role, reason: "文件大小已变化"});
      const hash = await sha256File(item.path);
      if (hash !== item.sha256) changes.push({role: item.role, reason: "文件内容已变化"});
    } catch {
      changes.push({role: item.role, reason: "文件不存在或已移动"});
    }
  }
  if (configPath) {
    const config = JSON.parse(await readFile(configPath, "utf8"));
    if (snapshotHash(contentSnapshot(config)) !== manifest.contentConfigHash) changes.push({role: "制作设置", reason: "声音 字幕 音量 音乐或素材设置已变化"});
  }
  return {passed: changes.length === 0, productName: manifest.productName, manifestPath, changes};
};

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const manifestPath = arg("--manifest");
  if (!manifestPath) throw new Error("需要 --manifest 参数");
  let result;
  if (process.argv.includes("--create")) {
    const configPath = arg("--config") ?? resolve(root, "video.config.json");
    result = await createApprovalLock({configPath, manifestPath, previewPath: arg("--preview")});
  } else if (process.argv.includes("--verify")) {
    result = await verifyApprovalLock({manifestPath, configPath: arg("--config")});
    if (!result.passed) process.exitCode = 2;
  } else throw new Error("需要 --create 或 --verify");
  console.log(JSON.stringify(result));
}
