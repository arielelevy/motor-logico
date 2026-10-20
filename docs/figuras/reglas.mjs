// Figure: banco de cartuchos. 48 sólidos: base+4 patas, 2 placas de ranura,
// 6 carriles, 14 alojamientos, 14 contactos, cartucho con 2 chips y 2 abrazaderas,
// tapa y placa. Sólo hay un cartucho cargado; el segundo zócalo está vacío.
import { acento, k, write } from "../kit.mjs";
const width = 720, height = 440;
const floor = { x: -130, y: -70, w: 260, d: 140, r: 5 };
const P = k.fitProjection(k.boxCorners(floor, -10, 108), width, height, { pad: 36, azimuth: 48, elevation: 32 });
const S = (plan, z, h, tone = "mid", extra = {}) => k.solidSvg(k.slabOf(plan, z, h, P, 4, 0.5), { tone, ...extra });
const out = [`<path class="iso-halo" d="${k.haloOf(floor, -10, 10, P)}"/>`];
for (const [x, y] of k.corners(floor, 12)) out.push(S({ x: x - 4, y: y - 4, w: 8, d: 8, r: 1 }, -10, 6, "lo"));
out.push(S(floor, -4, 4, "lo"));
out.push(k.dotsSvg(k.corners(floor, 7).map(([x, y]) => k.iso([x, y, 0], P)), { size: 0.5 }));
for (const cx of [-66, 66]) {
  out.push(S({ x: cx - 42, y: -49, w: 84, d: 98, r: 2 }, 0, 5));
  for (const x of [cx - 40, cx + 35]) out.push(S({ x, y: -46, w: 5, d: 92, r: 0.6 }, 5, 17, "lo"));
  out.push(S({ x: cx - 35, y: -46, w: 70, d: 6, r: 0.4 }, 5, 17));
  for (let i = 0; i < 7; i++) {
    const x = cx - 29 + i * 9;
    out.push(S({ x, y: -10, w: 6, d: 18, r: 0.6 }, 5, 5, "lo"));
    out.push(S({ x: x + 1, y: -7, w: 4, d: 12, r: 0.3 }, 10, 1, "hi", { className: acento.ambar }));
  }
}
// Cartucho asentado en el banco izquierdo, no flotando encima del zócalo.
out.push(S({ x: -99, y: -39, w: 66, d: 77, r: 1.5 }, 11, 6, "hi"));
for (const x of [-94, -42]) out.push(S({ x, y: -35, w: 5, d: 69, r: 0.6 }, 17, 42));
for (const y of [-28, 4]) out.push(S({ x: -89, y, w: 47, d: 22, r: 1 }, 17, 25, "lo"));
out.push(S({ x: -96, y: -38, w: 60, d: 76, r: 2 }, 59, 4));
out.push(S({ x: -82, y: -12, w: 32, d: 22, r: 0.6 }, 63, 1, "hi", { className: acento.verde }));
for (const y of [-31, 27]) out.push(k.dotsSvg([k.iso([-91, y, 63], P), k.iso([-41, y, 63], P)], { size: 0.45 }));

export function build() {
  return write("reglas", { width, height, P,
    notes: [
      { at: [-66, -1, 64], dx: -70, dy: -50, title: "learning.pl", text: "reglas del contrato 1" },
      { at: [66, -1, 11], dx: 140, dy: -70, title: "main.pl", text: "protocolo compartido" },
      { at: [66, 49, 18], dx: 90, dy: 60, title: "Zócalo libre", text: "próximo dominio" },
    ],
    label: "Un banco con dos zócalos: el cartucho de aprendizaje está asentado y tiene una placa verde; otro zócalo permanece vacío para un dominio futuro. Compartir el banco no significa compartir las reglas.",
    body: out,
    card: { fig: "Fig 3", title: "Un motor, reglas por dominio", hint: "El banco se comparte · las reglas se separan", readout: "Hoy: learning",
      keys: [
        { mark: "lit", label: "Cartucho cargado: reglas de aprendizaje implementadas y versionadas" },
        { mark: "raised", label: "Banco: protocolo y ejecución del motor compartidos por las aplicaciones" },
        { mark: "flat", label: "Zócalo vacío: lugar para reglas futuras; ajedrez todavía no implementado" },
      ],
      caption: "El motor vive en un repositorio propio. Hoy sólo acepta el dominio learning. Chesstudia podrá consultar reglas ajedrecísticas cuando se diseñen y verifiquen: no hereda como válidas las reglas de aprendizaje ni instala un segundo sistema de creencias.",
    },
  });
}
