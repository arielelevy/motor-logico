// Sólo herramientas de documentación: Anatomy se resuelve fuera del repo, no se copia.
import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

export const HERE = dirname(fileURLToPath(import.meta.url));
export const PREVIEW = join(tmpdir(), "motor-logico-infografias");
export const ANATOMY = [process.env.ANATOMY_DIR, join(homedir(), ".claude/skills/anatomy"),
  join(homedir(), ".agents/skills/anatomy")].filter(Boolean).find(path => existsSync(join(path, "kit/iso-kit.mjs")));
if (!ANATOMY) throw new Error("Para regenerar las figuras, fijá ANATOMY_DIR a la skill anatomy existente.");
export const k = await import(pathToFileURL(join(ANATOMY, "kit/iso-kit.mjs")));
export const acento = { verde: "verde", ambar: "ambar" };
const css = `<style>.iso{--verde:#4cc38a;--ambar:#ffb224}.iso[data-theme="light"]{--verde:#18794e;--ambar:#c27100}
${Object.values(acento).map(name => `.${name}>.iso-top{fill:var(--${name})}.${name}>.iso-shade{fill:color-mix(in srgb,var(--${name}) 70%,#000)}.${name}>.iso-edge{stroke:var(--${name})}`).join("")}</style>`;

export function write(name, { width, height, label, body, card }) {
  mkdirSync(join(HERE, "img"), { recursive: true });
  mkdirSync(PREVIEW, { recursive: true });
  const parts = [css, ...[body].flat()];
  const paths = [];
  for (const theme of ["dark", "light"]) {
    writeFileSync(join(HERE, "img", `${name}-${theme}.svg`), k.figureSvg({ width, height, label, body: parts, standalone: theme }) + "\n");
    const path = join(PREVIEW, `${name}-${theme}.html`);
    const plate = k.plateHtml({ ...card, body: `<div class="iso-stage">${k.figureSvg({ width, height, label, body: parts })}</div>` });
    writeFileSync(path, k.pageHtml({ title: card.title, theme, body: plate, width: width + 80 }).replace('<html lang="en">', '<html lang="es">'));
    paths.push(path);
  }
  return paths;
}
