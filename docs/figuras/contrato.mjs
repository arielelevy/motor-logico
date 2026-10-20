// Figure: lectora de fichas. Inventario 47 sólidos: base+4 patas, cuerpo+tapa,
// 2 bastidores, 12 dedos lectores, 2 bandejas con 4 bordes,
// 4 topes, 6 fichas, 4 guías, 4 soportes, placa y lente.
import { acento, k, write } from "../kit.mjs";
const width = 720, height = 440;
const floor = { x: -145, y: -74, w: 290, d: 148, r: 5 };
const P = k.fitProjection(k.boxCorners(floor, -10, 96), width, height, { pad: 36, azimuth: 48, elevation: 32 });
const S = (plan, z, h, tone = "mid", extra = {}) => k.solidSvg(k.slabOf(plan, z, h, P, 4, 0.5), { tone, ...extra });
const out = [`<path class="iso-halo" d="${k.haloOf(floor, -10, 10, P)}"/>`];
for (const [x, y] of k.corners(floor, 12)) out.push(S({ x: x - 4, y: y - 4, w: 8, d: 8, r: 1 }, -10, 6, "lo"));
out.push(S(floor, -4, 4, "lo"));
out.push(k.dotsSvg(k.corners(floor, 7).map(([x, y]) => k.iso([x, y, 0], P)), { size: 0.5 }));
out.push(S({ x: -41, y: -51, w: 82, d: 94, r: 3 }, 0, 12));
for (const x of [-41, 32]) out.push(S({ x, y: -51, w: 9, d: 94, r: 1 }, 12, 70));
// Peines apoyados entre los dos laterales; la lectura no ejecuta lo escrito en la ficha.
for (let i = 0; i < 12; i++) out.push(S({ x: -32, y: -48 + i * 7.5, w: 64, d: 2.5, r: 0.4 }, 55, 12, "hi"));
out.push(S({ x: -44, y: -54, w: 88, d: 100, r: 3 }, 82, 6));
for (const [cx, direction] of [[-92, -1], [92, 1]]) {
  const x = cx - 44;
  out.push(S({ x, y: -28, w: 88, d: 56, r: 2 }, 10, 2, "lo"));
  for (const y of [-28, 25]) out.push(S({ x, y, w: 88, d: 3, r: 0.4 }, 12, 5));
  for (const xx of [x, x + 85]) out.push(S({ x: xx, y: -25, w: 3, d: 50, r: 0.4 }, 12, 4));
  for (const y of [-24, 18]) out.push(S({ x: cx - 8, y, w: 16, d: 6, r: 0.5 }, 0, 10, "lo"));
  for (let i = 0; i < 3; i++) {
    const px = cx - 22 + i * 1.3;
    const py = -18 + i * 1.2;
    const z = 12 + i;
    const lines = [5, 10, 15].map(dy => k.lineSvg(k.segment([px + 4, py + dy, z + 0.8], [px + 38, py + dy, z + 0.8], P), { tone: "lo", free: true })).join("");
    out.push(S({ x: px, y: py, w: 44, d: 34, r: 0.5 }, z, 0.8, "hi", { inner: lines, className: direction === 1 && i === 2 ? acento.verde : undefined }));
  }
  for (const y of [-33, 30]) out.push(S({ x: cx - 3, y, w: 6, d: 4, r: 0.4 }, 0, 18));
}
out.push(S({ x: -18, y: -14, w: 36, d: 28, r: 1 }, 88, 1.5, "lo"));
out.push(S({ x: -6, y: -6, w: 12, d: 12, r: 1 }, 89.5, 2, "hi", { className: acento.verde }));

export function build() {
  return write("contrato", { width, height, P,
    notes: [
      { at: [-92, 0, 14], dx: -70, dy: -40, title: "Entra un JSON", text: "hechos y reglas" },
      { at: [0, 0, 91.5], dx: 90, dy: -60, title: "Luz verde", text: "respuesta válida" },
      { at: [32, 30, 60], dx: 150, dy: -10, title: "Reglas fijas", text: "no ejecuta código" },
      { at: [94, 0, 15], dx: 80, dy: 50, title: "Sale un JSON", text: "respuestas y pruebas" },
    ],
    label: "Una lectora de fichas recibe datos por su bandeja izquierda, los contrasta con peines fijos y entrega una respuesta por la derecha. Las fichas son datos: no programan la máquina.",
    body: out,
    card: { fig: "Fig 2", title: "Datos de ida y de vuelta", hint: "JSON entra · JSON sale", readout: "Contrato 1 · reglas 1",
      keys: [
        { mark: "flat", label: "Entrada: dominio, hechos, contexto y momento del snapshot" },
        { mark: "raised", label: "Lectora: reglas predefinidas; nunca ejecuta código recibido en los datos" },
        { mark: "lit", label: "Salida: estado, regla y cadenas de respaldo, o error explícito" },
      ],
      caption: "Cada consulta ocupa un proceso independiente. Un contrato o dominio no soportado termina con error, no con una lista vacía. No hay un servidor HTTP o MCP obligatorio; las aplicaciones pueden envolver este mismo contrato como herramienta.",
    },
  });
}
