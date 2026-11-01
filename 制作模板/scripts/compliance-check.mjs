import {mkdir, readFile, writeFile} from "node:fs/promises";
import {dirname, isAbsolute, resolve, join} from "node:path";
import {fileURLToPath} from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const fromRoot = (path) => isAbsolute(path) ? path : resolve(root, path);
const arg = (name) => {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : null;
};

export const runComplianceCheck = async ({textPath, outputDir = join(root, "输出", "审核报告"), productName = "当前产品"}) => {
  const rulesConfig = JSON.parse(await readFile(join(root, "compliance-rules.json"), "utf8"));
  const content = await readFile(fromRoot(textPath), "utf8");
  const lines = content.split(/\r?\n/);
  const findings = [];
  for (const rule of rulesConfig.rules) {
    for (let lineIndex = 0; lineIndex < lines.length; lineIndex++) {
      let searchFrom = 0;
      while (true) {
        const column = lines[lineIndex].indexOf(rule.term, searchFrom);
        if (column < 0) break;
        findings.push({
          term: rule.term,
          level: rule.level,
          category: rule.category,
          suggestion: rule.suggestion,
          line: lineIndex + 1,
          column: column + 1,
          context: lines[lineIndex].trim(),
        });
        searchFrom = column + Math.max(1, rule.term.length);
      }
    }
  }
  findings.sort((a, b) => a.line - b.line || a.column - b.column || b.term.length - a.term.length);
  const deduplicated = findings.filter((item, index, all) => !all.slice(0, index).some((previous) =>
    previous.line === item.line &&
    previous.category === item.category &&
    item.column >= previous.column &&
    item.column + item.term.length <= previous.column + previous.term.length
  ));
  const blockCount = deduplicated.filter((item) => item.level === "block").length;
  const reviewCount = deduplicated.filter((item) => item.level === "review").length;
  const report = {
    productName,
    checkedAt: new Date().toISOString(),
    ruleVersion: rulesConfig.version,
    notice: rulesConfig.notice,
    result: blockCount > 0 ? "blocked" : reviewCount > 0 ? "manual-review" : "passed",
    summary: {block: blockCount, review: reviewCount, total: deduplicated.length},
    findings: deduplicated,
  };
  await mkdir(outputDir, {recursive: true});
  const safeName = String(productName).replace(/[<>:"/\\|?*]/g, "_");
  const jsonPath = join(outputDir, `${safeName}_合规审核.json`);
  const textReportPath = join(outputDir, `${safeName}_合规审核.txt`);
  const levelName = {block: "必须修改", review: "人工复核"};
  const textReport = [
    `产品：${productName}`,
    `结果：${report.result === "passed" ? "通过初审" : report.result === "blocked" ? "存在必须修改项" : "需要人工复核"}`,
    `必须修改：${blockCount} 项；人工复核：${reviewCount} 项`,
    "",
    ...deduplicated.map((item, index) => `${index + 1}. [${levelName[item.level]}] ${item.term}（${item.category}）\n   第${item.line}行：${item.context}\n   建议：${item.suggestion}`),
    deduplicated.length ? "" : "未发现当前词库中的风险词。",
    "说明：该报告仅用于内部自动初审，平台规则可能变化，发布前仍需人工确认。",
  ].join("\r\n");
  await writeFile(jsonPath, JSON.stringify(report, null, 2), "utf8");
  await writeFile(textReportPath, textReport, "utf8");
  return {...report, jsonPath, textReportPath};
};

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const configPath = arg("--config") ?? join(root, "video.config.json");
  const config = JSON.parse(await readFile(configPath, "utf8"));
  const report = await runComplianceCheck({
    textPath: arg("--text") ?? config.voiceover.sourcePath,
    outputDir: arg("--output-dir") ?? join(root, "输出", "审核报告"),
    productName: arg("--product") ?? config.productName,
  });
  console.log(JSON.stringify(report));
  if (report.result === "blocked") process.exitCode = 2;
}
