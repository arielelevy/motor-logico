import { spawnSync } from "node:child_process";
import { join, basename } from "node:path";
import { ANATOMY, PREVIEW } from "./kit.mjs";
const args = process.argv.slice(2);
const allowed = ["prolog", "contrato", "reglas"];
if (args.some(arg => arg !== "--check" && !allowed.includes(arg))) throw new Error("Uso: node docs/build.mjs [prolog|contrato|reglas] [--check]");
const selected = args.filter(arg => arg !== "--check");
for (const name of selected.length ? selected : allowed) {
  const figure = await import(`./figuras/${name}.mjs`);
  for (const page of figure.build()) {
    console.log(page);
    if (!args.includes("--check")) continue;
    for (const script of ["capture", "lines"]) {
      const output = join(PREVIEW, `${basename(page, ".html")}-${script}.png`);
      const result = spawnSync(process.execPath, [join(ANATOMY, `scripts/${script}.mjs`), page, "--out", output], { encoding: "utf8", timeout: 60000 });
      process.stdout.write(result.stdout ?? ""); process.stderr.write(result.stderr ?? "");
      if (result.error || result.status !== 0) throw new Error(`Falló ${script}: ${result.error?.message ?? result.status}`);
      if (script === "capture" && (!result.stdout.includes("console: clean") || !result.stdout.includes("scrolls sideways: no"))) throw new Error("Consola o desborde en la figura");
    }
  }
}
