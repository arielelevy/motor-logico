"""Diferencial: el motor actual contra otra versión, con consultas aleatorias de los contratos 1 y 2.

    python tests/diferencial.py <carpeta-con-main.pl-anterior> <semilla> <casos>

Compara código de salida, stdout y el `code` de stderr byte a byte. El contrato 2 incluye
pruebas, restricciones, límites, errores y secuencias de escritura sobre un almacén por motor.
No es parte de `unittest`: corre muchos procesos y necesita la versión anterior en disco.
"""
import json
import random
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def wsl(p):
    p = Path(p).resolve()
    return "/mnt/" + p.drive[0].lower() + p.as_posix()[len(p.drive):]


def run(engine, data, store_dir):
    env = f"MOTOR_LOGICO_DATA={wsl(store_dir)}"
    try:
        p = subprocess.run(["wsl.exe", "-d", "Ubuntu", "--", "env", env, "timeout", "50", "swipl", "-q", "-f", "none",
                            "-s", wsl(engine), "-g", "main", "-t", "halt"],
                           input=json.dumps(data, ensure_ascii=False).encode("utf-8"), capture_output=True, timeout=60)
    except subprocess.TimeoutExpired:
        return -1, b"", "timeout"
    if p.returncode not in (0, 2):
        return p.returncode, p.stdout, p.stderr.decode("utf-8", "replace")[:200]
    code = json.loads(p.stderr)["code"] if p.returncode else None
    return p.returncode, p.stdout, code


# Contrato 1: el generador de la revisión del 2026-10-19.
KINDS = ["decision", "evidencia", "hallazgo", "medicion", "nota"]
STATES = ["vigente", "rechazado", "rechazada", "revertida", "reemplazada", "propuesta", None]


def learning(r):
    n = r.randint(1, 25)
    ids = [f"n{i}" for i in range(n)]
    nodes = [{"id": i, "kind": r.choice(KINDS + ["decision"] * 2), "state": r.choice(STATES)} for i in ids]
    edges = [{"from": r.choice(ids), "to": r.choice(ids), "relation": r.choice(["motivada_por", "apoya", "motivada_por"])}
             for _ in range(r.randint(0, 60))]
    beliefs = []
    for i in r.sample(ids, r.randint(0, n)):
        if r.random() < 0.5:
            ev = r.choice(ids)
            edges.append({"from": i, "to": ev, "relation": "apoya"})
            nodes[ids.index(ev)]["kind"] = r.choice(["evidencia", "evidencia", "nota"])
        else:
            ev = r.choice(ids + [None])
        req = r.choice([None, {}, {r.choice(["agente", "fase", "area", "raro"]): r.choice(["a", "b"])}, {"fase": 3}])
        beliefs.append({"id": i, "state": r.choice(["vigente", "vigente", "revertida", "propuesta"]),
                        "verdict": r.choice(["validada", "validada", "refutada", None]),
                        "approved_by": r.choice(["persona:x", "persona:y", "agente:y", None]),
                        "evidence": ev, "until": r.choice([None, 50, 500, 500]), "required": req})
    return {"contract": 1, "domain": "learning", "now": 100,
            "context": r.choice([{}, {"fase": "a"}, {"fase": "b", "agente": "a"}]),
            "nodes": nodes, "edges": edges, "beliefs": beliefs}


# Contrato 2: reglas de las plantillas del oráculo, con recursión, negación y comparaciones.
V = lambda n: "?" + n  # noqa: E731
L = lambda p, *a, **k: {"pred": p, "args": list(a), **k}  # noqa: E731
NOT = {"not": True}
RULES = [
    ("r1", L("p", V("X"), V("Y")), [L("e", V("X"), V("Y"))]),
    ("r2", L("p", V("X"), V("Z")), [L("p", V("X"), V("Y")), L("e", V("Y"), V("Z"))]),
    ("r3", L("p", V("X"), V("Z")), [L("p", V("X"), V("Y")), L("p", V("Y"), V("Z"))]),
    ("r4", L("q", V("X"), V("Y")), [L("f", V("X"), V("Y")), L("p", V("Y"), V("X"))]),
    ("r5", L("q", V("X"), V("Y")), [L("q", V("Y"), V("X"))]),
    ("r6", L("p", V("X"), V("Y")), [L("q", V("X"), V("Y")), {"cmp": "!=", "args": [V("X"), V("Y")]}]),
    ("r7", L("s", V("X"), V("Y")), [L("e", V("X"), V("Y")), L("p", V("Y"), V("X"), **NOT)]),
    ("r8", L("t", V("X")), [L("f", V("X"), V("Y")), L("q", V("X"), V("_"), **NOT), {"cmp": "<", "args": [V("Y"), 3]}]),
    ("r9", L("u", V("X")), [L("t", V("X")), L("s", V("X"), V("_"), **NOT)]),
    ("bad", L("p", V("X")), [L("q", V("X")), L("p", V("X"), **NOT)]),
    ("unsafe", L("w", V("X"), V("Z")), [L("e", V("X"), V("Y"))]),
]
PREDS = {"p": 2, "q": 2, "s": 2, "t": 1, "u": 1, "e": 2, "f": 2}


def logic(r):
    rules = [{"id": i, "head": h, "body": b} for i, h, b in RULES if r.random() < (0.05 if i in ("bad", "unsafe") else 0.55)]
    dom = list(range(r.randint(2, 6))) + (["x"] if r.random() < 0.3 else [])
    facts = [L(p, a, b) for p in ("e", "f") for a in dom for b in dom if r.random() < 0.25]
    queries = [L(p, *[r.choice([V(f"A{i}"), V("_"), r.choice(dom)]) for i in range(a)]) for p, a in PREDS.items() if r.random() < 0.7]
    body = {"contract": 2, "domain": "logic", "facts": facts, "rules": rules, "queries": queries}
    if r.random() < 0.5:
        body["explain"] = True
    if r.random() < 0.3:
        body["limits"] = {"max_results": r.choice([1, 3, 100]), "proof_depth": r.choice([1, 3, 12])}
    if r.random() < 0.4:
        body["constraints"] = [{"id": "c1", "message": "ciclo", "body": [L("p", V("X"), V("X"))]},
                               {"id": "c2", "body": [L("e", V("X"), V("Y")), {"cmp": ">", "args": [V("X"), V("Y")]}]}][:r.randint(1, 2)]
    if r.random() < 0.05:
        body[r.choice(["goal", "source"])] = "x"
    return body


def store_session(r):
    """Secuencia de consultas sobre un mismo almacén."""
    steps = []
    for _ in range(r.randint(2, 5)):
        b = {"contract": 2, "domain": "logic", "store": "s"}
        kind = r.random()
        if kind < 0.5:
            b["assert"] = {"facts": [L("e", r.randint(0, 3), r.randint(0, 3)) for _ in range(r.randint(1, 3))],
                           "rules": [{"id": i, "head": h, "body": bb} for i, h, bb in RULES[:3] if r.random() < 0.5]}
        elif kind < 0.7:
            b["retract"] = {"facts": [L("e", r.randint(0, 3), r.randint(0, 3))], "rules": ["r2"]}
        if r.random() < 0.3:
            b["expect_revision"] = r.randint(0, 3)
        if r.random() < 0.5:
            b["export"] = True
        b["queries"] = [L("p", V("A"), V("B"))]
        b["explain"] = r.random() < 0.5
        steps.append(b)
    return steps


def main():
    old, seed, n = Path(sys.argv[1]) / "main.pl", int(sys.argv[2]), int(sys.argv[3])
    only = {int(x) for x in sys.argv[4].split(",")} if len(sys.argv) > 4 else None  # repetir casos sueltos
    new = ROOT / "main.pl"
    r = random.Random(seed)
    diffs, kinds = 0, {}
    for k in range(n):
        kind = r.choice(["learning", "logic", "logic", "store"])
        cases = store_session(r) if kind == "store" else [learning(r) if kind == "learning" else logic(r)]
        if only is not None and k not in only:
            continue
        with tempfile.TemporaryDirectory() as a, tempfile.TemporaryDirectory() as b:
            for case in cases:
                x, y = run(old, case, a), run(new, case, b)
                ok = "ok" if x[0] == 0 else x[2]
                kinds[(kind, ok)] = kinds.get((kind, ok), 0) + 1
                if x != y:
                    diffs += 1
                    print("DIFF", k, kind, x[0], y[0], x[2], y[2], x[1][:300], y[1][:300], json.dumps(case)[:300])
    total = sum(kinds.values())
    print(f"consultas={total} diferencias={diffs}")
    for (kind, ok), c in sorted(kinds.items(), key=str):
        print(f"  {kind:8} {ok:20} {c}")


if __name__ == "__main__":
    main()
