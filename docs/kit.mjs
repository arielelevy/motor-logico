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
const NOTA = 20, MARGEN = 24;
const css = `<style>.iso{--verde:#4cc38a;--ambar:#ffb224}.iso[data-theme="light"]{--verde:#18794e;--ambar:#c27100}
${Object.values(acento).map(name => `.${name}>.iso-top{fill:var(--${name})}.${name}>.iso-shade{fill:color-mix(in srgb,var(--${name}) 70%,#000)}.${name}>.iso-edge{stroke:var(--${name})}`).join("")}
.nota{fill:var(--anatomy-strong);font:600 ${NOTA}px var(--anatomy-mono)}.nota tspan+tspan{fill:var(--anatomy-text);font-weight:400}</style>`;

// Nota: punto sobre la pieza, guía hasta el rótulo y dos líneas (título y detalle).
// `at` es un punto 3D de la pieza; `dx, dy` desplazan el rótulo en pantalla.
function notas(lista, P) {
  const out = [], cajas = [];
  for (const { at, dx, dy, title, text } of lista) {
    const [ax, ay] = k.iso(at, P);
    const tx = ax + dx, ty = ay + dy, izquierda = dx < 0;
    const codo = [tx - (izquierda ? -6 : 6), ty];
    out.push(k.lineSvg(k.pathOf([[ax, ay], codo, [tx, ty]]), { tone: "mid", free: true }));
    out.push(k.dotsSvg([[ax, ay]], { size: 2.2, tone: "hi" }));
    const x = tx + (izquierda ? -6 : 6), anchor = izquierda ? "end" : "start";
    out.push(`<text class="nota" x="${x.toFixed(1)}" y="${(ty - 3).toFixed(1)}" text-anchor="${anchor}"><tspan>${title}</tspan><tspan x="${x.toFixed(1)}" dy="${NOTA + 3}">${text}</tspan></text>`);
    const ancho = Math.max(title.length, text.length) * NOTA * 0.62;
    cajas.push([izquierda ? x - ancho : x, ty - 3 - NOTA, izquierda ? x : x + ancho, ty + NOTA + 4], [ax - 3, ay - 3, ax + 3, ay + 3]);
  }
  return { svg: out.join(""), cajas };
}

// Recorta el lienzo al dibujo más las notas, con el mismo margen en todas las figuras.
function recorte(svg, cajas) {
  const xs = [], ys = [];
  for (const [, d] of svg.matchAll(/ d="([^"]*)"/g)) {
    for (const [, x, y] of d.matchAll(/[ML](-?[\d.]+) (-?[\d.]+)/g)) { xs.push(+x); ys.push(+y); }
  }
  for (const [x0, y0, x1, y1] of cajas) xs.push(x0, x1), ys.push(y0, y1);
  const x = Math.floor(Math.min(...xs) - MARGEN), y = Math.floor(Math.min(...ys) - MARGEN);
  return { x, y, w: Math.ceil(Math.max(...xs) + MARGEN) - x, h: Math.ceil(Math.max(...ys) + MARGEN) - y };
}

export function write(name, { width, height, label, body, card, P, notes = [] }) {
  mkdirSync(join(HERE, "img"), { recursive: true });
  mkdirSync(PREVIEW, { recursive: true });
  const { svg, cajas } = notas(notes, P);
  const parts = [css, ...[body].flat(), svg];
  const caja = recorte(parts.join(""), cajas);
  const figura = (standalone) => k.figureSvg({ width, height, label, body: parts, standalone })
    .replace(`viewBox="0 0 ${width} ${height}"`, `viewBox="${caja.x} ${caja.y} ${caja.w} ${caja.h}"`);
  const paths = [];
  for (const theme of ["dark", "light"]) {
    writeFileSync(join(HERE, "img", `${name}-${theme}.svg`), figura(theme) + "\n");
    const path = join(PREVIEW, `${name}-${theme}.html`);
    const plate = k.plateHtml({ ...card, body: `<div class="iso-stage">${figura(false)}</div>` });
    writeFileSync(path, k.pageHtml({ title: card.title, theme, body: plate, width: width + 80 }).replace('<html lang="en">', '<html lang="es">'));
    paths.push(path);
  }
  return paths;
}
