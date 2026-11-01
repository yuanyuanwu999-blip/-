import {readFile, writeFile} from "node:fs/promises";
import {dirname, resolve} from "node:path";
import {fileURLToPath} from "node:url";
import {ALL_FORMATS, FilePathSource, Input} from "mediabunny";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const [aPath, bPath] = process.argv.slice(2);
if (!aPath || !bPath) throw new Error("需要同时提供 A 段和 B 段素材路径");

const duration = async (path) => {
  const input = new Input({formats: ALL_FORMATS, source: new FilePathSource(path)});
  try { return Number((await input.computeDuration()).toFixed(3)); }
  finally { input.dispose(); }
};

const configPath = resolve(root, "video.config.json");
const config = JSON.parse(await readFile(configPath, "utf8"));
const [aDuration, bDuration] = await Promise.all([duration(aPath), duration(bPath)]);
config.segments.a = {sourcePath: aPath.replaceAll("\\", "/"), durationSeconds: aDuration};
config.segments.b = {sourcePath: bPath.replaceAll("\\", "/"), durationSeconds: bDuration};
await writeFile(configPath, `${JSON.stringify(config, null, 2)}\n`, "utf8");
console.log(JSON.stringify({aDuration, bDuration}));
