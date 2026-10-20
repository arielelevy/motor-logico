// Figure estática: fichero autónomo + estación de consulta desmontable.
// Inventario: fichero (base, 4 patas, cuerpo, tapa, 6 frentes, 6 tiradores,
// 6 portaetiquetas, placa y lámpara, 4 fichas = 31); estación (base, 4 patas,
// 2 soportes, 2 montantes, tapa, placa, 6 peines = 17); bandejas (2 fondos,
// 4 bordes, 4 topes, 6 fichas = 16). 64 sólidos; tornillos como puntos del kit.
// La ficha sale y vuelve por bandejas distintas. El fichero conserva su lámpara
// propia: retirar la estación no retira las creencias ni el aprendizaje.
import { acento, k, write } from "../kit.mjs";

const WIDTH = 720, HEIGHT = 440;
const FILE = { x: -142, y: -36, w: 100, d: 74, r: 3 };
const STATION = { x: 38, y: -30, w: 106, d: 78, r: 3 };
const P = k.fitProjection([
  ...k.boxCorners(FILE, -12, 105), ...k.boxCorners(STATION, -12, 92),
  [-44, 91, 28], [120, 91, 28],
], WIDTH, HEIGHT, { pad: 30, azimuth: 48, elevation: 32 });
const S = (plan, z, h, tone = "mid", extra = {}) => k.solidSvg(k.slabOf(plan, z, h, P, 4, 0.5), { tone, ...extra });
const dot = (points) => k.dotsSvg(points.map(p => k.iso(p, P)), { size: 0.45 });
const L = (a, b, style = {}) => k.lineSvg(k.segment(a, b, P), { tone: "faint", ...style });

function base(plan) {
  const out = [`<path class="iso-halo" d="${k.haloOf(plan, -12, 12, P)}"/>`];
  for (const [x, y] of k.corners(plan, 9).sort((a, b) => k.depthOf([...a, 0], P) - k.depthOf([...b, 0], P))) {
    out.push(S({ x: x - 3.5, y: y - 3.5, w: 7, d: 7, r: 1 }, -12, 8, "lo"));
  }
  out.push(S(plan, -4, 4, "lo"));
  out.push(dot(k.corners(plan, 6).map(([x, y]) => [x, y, 0])));
  return out.join("");
}

function paper(x, y, z, width, depth, accent) {
  const plan = { x, y, w: width, d: depth, r: 0.4 };
  const top = z + 0.8;
  const lines = [4, 7, 10].map((dy, i) => L([x + 3, y + dy, top], [x + width - 3 - i * 2, y + dy, top], { free: true })).join("");
  return S(plan, z, 0.8, "hi", { className: accent, inner: lines });
}

function cabinet() {
  const front = FILE.y + FILE.d - 4;
  const out = [base(FILE)];
  out.push(S({ ...FILE, x: FILE.x + 4, y: FILE.y + 4, w: FILE.w - 8, d: FILE.d - 8 }, 0, 94));
  out.push(S({ ...FILE, x: FILE.x + 1, y: FILE.y + 1, w: FILE.w - 2, d: FILE.d - 2 }, 94, 4));
  out.push(dot(k.corners(FILE, 8).map(([x, y]) => [x, y, 98])));
  for (const z of [8, 36, 64]) {
    for (const x of [-135, -91]) {
      out.push(S({ x, y: front, w: 40, d: 2, r: 1 }, z, 25, "hi"));
      out.push(S({ x: x + 11, y: front + 2, w: 18, d: 2, r: 0.5 }, z + 14, 6, "lo"));
      out.push(S({ x: x + 13, y: front + 4, w: 14, d: 3, r: 0.6 }, z + 6, 3));
      out.push(dot([[x + 3, front + 2, z + 3], [x + 37, front + 2, z + 22]]));
    }
  }
  out.push(S({ x: -132, y: -16, w: 18, d: 18, r: 1 }, 98, 2, "lo"));
  out.push(S({ x: -127, y: -11, w: 8, d: 8, r: 1 }, 100, 2, "hi", { className: acento.verde }));
  for (let i = 0; i < 4; i++) out.push(paper(-101 + i, 0 + i, 98 + i, 38, 24));
  return out.join("");
}

function station() {
  const out = [base(STATION)];
  // Peines lógicos en un bastidor, todo apoyado: no hay piezas flotantes.
  for (const x of [48, 125]) out.push(S({ x, y: -21, w: 9, d: 57, r: 1 }, 0, 7, "lo"));
  for (const x of [48, 128]) out.push(S({ x, y: -21, w: 6, d: 57, r: 1 }, 7, 69));
  for (let i = 0; i < 6; i++) {
    const y = -18 + i * 9;
    out.push(S({ x: 54, y, w: 74, d: 3, r: 0.5 }, 22 + i * 5, 8, "hi"));
  }
  out.push(S({ x: 46, y: -23, w: 90, d: 61, r: 2 }, 76, 5));
  const badge = { x: 69, y: 37, w: 44, d: 1, r: 0.6 };
  out.push(S(badge, 63, 13, "lo"));
  out.push(k.faceTextSvg(k.sideMatrix([91, 38], 67, P, "left"), "PROLOG", { size: 6, tone: "hi", anchor: "middle" }));
  out.push(dot([[72, 38, 73], [110, 38, 73]]));
  return out.join("");
}

function tray(y, z, returned) {
  const plan = { x: -38, y, w: 160, d: 20, r: 1 };
  const out = [S(plan, z, 2, "lo")];
  for (const edge of [y, y + 18]) out.push(S({ ...plan, y: edge, d: 2 }, z + 2, 4));
  for (const x of [-38, 119]) out.push(S({ x, y: y + 2, w: 3, d: 16, r: 0.4 }, z + 2, 4));
  for (let i = 0; i < 3; i++) out.push(paper((returned ? -25 : 68) + i, y + 3 + i * 0.4, z + 2 + i, 34, 14,
    returned && i === 2 ? acento.ambar : undefined));
  return out.join("");
}

export function build() {
  return write("prolog", {
    width: WIDTH, height: HEIGHT, P,
    notes: [
      { at: [-123, -7, 102], dx: -50, dy: -14, title: "Tu aplicación", text: "guarda sus datos" },
      { at: [91, 8, 81], dx: 60, dy: -80, title: "Motor Prolog", text: "en su propio repo" },
      { at: [85, 50, 5], dx: 130, dy: 50, title: "Ida: la consulta", text: "JSON con hechos" },
      { at: [-8, 77, 5], dx: -90, dy: 60, title: "Vuelta: la respuesta", text: "conclusiones + prueba" },
    ],
    label: "Un fichero con su lámpara verde conserva las creencias y el aprendizaje. A su lado, un bastidor Prolog independiente recibe fichas por una bandeja y devuelve una copia con conclusiones por otra. Retirar el bastidor no detiene el fichero.",
    body: [cabinet(), station(), tray(43, 0, false), tray(70, 0, true)],
    card: {
      fig: "Fig 1", title: "Razonamiento opcional",
      hint: "Sale una consulta · vuelve una explicación",
      readout: "Sin Prolog, el aprendizaje sigue",
      keys: [
        { mark: "lit", label: "Fichero con luz verde: creencias, evidencia y aprendizaje conservados por Lienzo" },
        { mark: "raised", label: "Bastidor separado: motor Prolog con reglas versionadas, consultado sólo cuando lo pedís" },
        { mark: "flat", label: "Dos bandejas: snapshot JSON de ida y conclusiones justificadas de vuelta; no reescribe el fichero" },
      ],
      caption: "Lienzo y el motor lógico viven en repositorios separados. La consulta manual envía hechos y recibe conclusiones con sus respaldos. Si el motor falta o no responde, se informa que no se ejecutó esa consulta: creencias, aprendizaje y el resto siguen disponibles. Chesstudia podrá usar el mismo contrato con reglas propias; esa conexión todavía no está implementada.",
    },
  });
}
