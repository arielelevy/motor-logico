"""Oráculo del contrato 3: Datalog ingenuo en Python contra el motor, con programas aleatorios.

    python tests/oraculo.py <semilla> <programas>

El oráculo implementa la semántica de docs/CONTRATO-3.md por su cuenta: estratos, punto fijo
ingenuo, negación, comparaciones, agregados con variables externas, de grupo y locales, y `op`.
No comparte código con el motor. No es parte de `unittest`: corre un proceso por programa.
"""
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "clients" / "python"))
from motor_logico import MotorError, consultar  # noqa: E402

V = lambda n: "?" + n  # noqa: E731
L = lambda p, *a, **k: {"pred": p, "args": list(a), **k}  # noqa: E731
NOT = {"not": True}


def agg(op, pred, args, as_, value=None):
    d = {"agg": op, "pred": pred, "args": list(args), "as": as_}
    if value:
        d["value"] = value
    return d


def op(o, a, b, as_):
    return {"op": o, "args": [a, b], "as": as_}


def cmp(o, a, b):
    return {"cmp": o, "args": [a, b]}


RULES = [
    ("a1", L("p", V("X"), V("Y")), [L("e", V("X"), V("Y"))]),
    ("a2", L("p", V("X"), V("Z")), [L("p", V("X"), V("Y")), L("e", V("Y"), V("Z"))]),
    ("n1", L("node", V("X")), [L("e", V("X"), V("_"))]),
    ("n2", L("node", V("Y")), [L("e", V("_"), V("Y"))]),
    ("c1", L("deg", V("X"), V("N")), [agg("count", "e", [V("X"), V("_")], V("N"))]),
    ("c2", L("reach", V("X"), V("N")), [L("node", V("X")), agg("count", "p", [V("X"), V("Y")], V("N"))]),
    ("s1", L("tot", V("X"), V("S")), [agg("sum", "w", [V("X"), V("W")], V("S"), V("W"))]),
    ("s2", L("big", V("X")), [L("tot", V("X"), V("S")), cmp(">", V("S"), 5)]),
    ("m1", L("lo", V("M")), [agg("min", "w", [V("_"), V("W")], V("M"), V("W"))]),
    ("m2", L("hi", V("X"), V("M")), [L("node", V("X")), agg("max", "w", [V("X"), V("W")], V("M"), V("W"))]),
    ("o1", L("dbl", V("X"), V("D")), [L("w", V("X"), V("W")), op("*", V("W"), 2, V("D"))]),
    ("o2", L("diff", V("X"), V("Y"), V("D")),
     [L("tot", V("X"), V("A")), L("tot", V("Y"), V("B")), op("-", V("A"), V("B"), V("D")), cmp(">", V("D"), 0)]),
    ("o3", L("ratio", V("X"), V("R")), [L("tot", V("X"), V("S")), L("deg", V("X"), V("N")), op("/", V("S"), V("N"), V("R"))]),
    ("o4", L("chain", V("X"), V("Y")), [L("dbl", V("X"), V("Y"))]),
    ("o5", L("chain", V("X"), V("Z")), [L("chain", V("X"), V("Y")), L("chain", V("Y"), V("Z"))]),
    ("g1", L("sink", V("X")), [L("node", V("X")), L("e", V("X"), V("_"), **NOT)]),
    ("g2", L("h", V("N")), [agg("count", "e", [V("X"), V("_")], V("N")), L("sink", V("X"), **NOT)]),
    ("g3", L("pairs", V("N")), [agg("count", "p", [V("_"), V("_")], V("N"))]),
    ("g4", L("self", V("N")), [agg("count", "e", [V("X"), V("X")], V("N"))]),
    ("g5", L("k", V("X"), V("N")), [L("deg", V("X"), V("N")), L("big", V("X"), **NOT)]),
    ("g6", L("plus", V("X"), V("Z")), [L("deg", V("X"), V("N")), op("+", V("N"), V("N"), V("M")), op("-", V("M"), 1, V("Z"))]),
]
PREDS = {"p": 2, "node": 1, "deg": 2, "reach": 2, "tot": 2, "big": 1, "lo": 1, "hi": 2, "dbl": 2,
         "diff": 3, "ratio": 2, "chain": 2, "sink": 1, "h": 1, "pairs": 1, "self": 1, "k": 2, "plus": 2}


def isvar(a):
    return isinstance(a, str) and a.startswith("?")


def num(x):
    return isinstance(x, (int, float)) and not isinstance(x, bool)


def norm(x):
    return int(x) if isinstance(x, float) and x == int(x) else x


def lit_vars(args):
    return {a for a in args if isvar(a) and a != "?_"}


def item_vars(i):
    if "agg" in i:
        return lit_vars(i["args"]) | {i["as"]}
    if "op" in i:
        return lit_vars(i["args"]) | {i["as"]}
    return lit_vars(i["args"])


def match(db, pred, args, env):
    for t in db.get(pred, ()):
        e = dict(env)
        for a, v in zip(args, t):
            if isvar(a):
                if a == "?_":
                    continue
                if a in e:
                    if e[a] != v or type(e[a]) is not type(v):
                        break
                else:
                    e[a] = v
            elif a != v:
                break
        else:
            yield t, e


def check(o, a, b):
    if o == "=":
        return a == b if num(a) and num(b) else (type(a) is type(b) and a == b)
    if o == "!=":
        return not check("=", a, b)
    if not (num(a) and num(b)):
        return False
    return {"<": a < b, "<=": a <= b, ">": a > b, ">=": a >= b}[o]


def arith(o, a, b):
    if not (num(a) and num(b)) or (o == "/" and b == 0):
        return None
    return norm(a / b if o == "/" else {"+": a + b, "-": a - b, "*": a * b}[o])


def solve_rule(db, head, body):
    pos = [i for i in body if "agg" not in i and "op" not in i and "cmp" not in i and not i.get("not")]
    pv = set().union(*[lit_vars(i["args"]) for i in pos]) if pos else set()
    envs = [{}]
    for lit in pos:
        envs = [e2 for e in envs for _, e2 in match(db, lit["pred"], lit["args"], e)]
    pending = [i for i in body if i not in pos]
    bound = set(pv)
    while pending:
        ready = None
        for i in pending:
            if "agg" in i:
                lv = lit_vars(i["args"])
                others = [j for j in body if j is not i]
                elsewhere = lit_vars(head["args"]).union(*[item_vars(j) for j in others])
                needs, group = lv & pv, sorted((lv - pv) & elsewhere)
            elif "op" in i:
                needs, group = lit_vars(i["args"]), []
            else:
                needs, group = lit_vars(i["args"]), []
            if needs <= bound:
                ready = (i, group)
                break
        i, group = ready
        pending.remove(i)
        out = []
        for e in envs:
            if "cmp" in i:
                a, b = (e.get(x, x) for x in i["args"])
                if check(i["cmp"], a, b):
                    out.append(e)
            elif i.get("not"):
                if not any(True for _ in match(db, i["pred"], i["args"], e)):
                    out.append(e)
            elif "op" in i:
                a, b = (e.get(x, x) for x in i["args"])
                r = arith(i["op"], a, b)
                if r is not None:
                    out.append({**e, i["as"]: r})
            else:
                groups = {}
                for t, e2 in match(db, i["pred"], i["args"], e):
                    groups.setdefault(tuple(e2[g] for g in group), {})[t] = e2.get(i.get("value"))
                if not group and not groups:
                    groups[()] = {}
                for key, rows in groups.items():
                    vals = [v for v in rows.values() if num(v)]
                    if i["agg"] == "count":
                        r = len(rows)
                    elif i["agg"] == "sum":
                        r = norm(sum(vals))
                    elif vals:
                        r = norm(min(vals) if i["agg"] == "min" else max(vals))
                    else:
                        continue
                    out.append({**e, **dict(zip(group, key)), i["as"]: r})
        envs = out
        bound |= set(group) | ({i["as"]} if "as" in i else set())
    for e in envs:
        yield tuple(e.get(a, a) for a in head["args"])


def strata(rules):
    s = {}
    for _, h, b in rules:
        s.setdefault(h["pred"], 0)
        for i in b:
            if "pred" in i:
                s.setdefault(i["pred"], 0)
    changed = True
    while changed:
        changed = False
        for _, h, b in rules:
            strict = any("agg" in i or "op" in i for i in b)
            need = s[h["pred"]]
            for i in b:
                if "pred" not in i:
                    continue
                bump = 1 if ("agg" in i or i.get("not") or strict) else 0
                need = max(need, s[i["pred"]] + bump)
            if need > s[h["pred"]]:
                s[h["pred"]] = need
                changed = True
                assert need <= len(s), "no estratificable"
    return s


def naive(facts, rules):
    db = {}
    for f in facts:
        db.setdefault(f["pred"], set()).add(tuple(f["args"]))
    s = strata(rules)
    for k in range(max(s.values(), default=0) + 1):
        rs = [r for r in rules if s[r[1]["pred"]] == k]
        while True:
            new = {(h["pred"], t) for _, h, b in rs for t in solve_rule(db, h, b)} - {
                (p, t) for p, ts in db.items() for t in ts}
            if not new:
                break
            for p, t in new:
                db.setdefault(p, set()).add(t)
    return db


def key(v):
    return (type(v).__name__ == "str", v)


def main():
    seed, n = int(sys.argv[1]), int(sys.argv[2])
    r = random.Random(seed)
    bad, cover, retries = 0, {}, 0
    for k in range(n):
        rules = [t for t in RULES if r.random() < 0.6]
        dom = list(range(r.randint(2, 6))) + (["x"] if r.random() < 0.3 else [])
        facts = [L("e", a, b) for a in dom for b in dom if r.random() < 0.25]
        facts += [L("w", a, r.choice([-3, 0, 1, 2, 4, 7, 2.5, "x"])) for a in dom if r.random() < 0.6]
        expected = naive(facts, rules)
        query = {"contract": 3, "domain": "logic", "facts": facts,
                 "rules": [{"id": i, "head": h, "body": b} for i, h, b in rules],
                 "queries": [L(p, *[V(f"A{i}") for i in range(a)]) for p, a in PREDS.items()],
                 "limits": {"max_results": 10000}}
        try:
            out = consultar(query)
        except MotorError as e:
            # WSL a veces no arranca swipl y el `timeout` del cliente corta con 124: se reintenta
            # una vez y se cuenta. Un time_limit del motor sale con código 2, no con 124.
            if "124" not in e.message:
                raise
            retries += 1
            out = consultar(query)
        for (p, a), ans in zip(PREDS.items(), out["answers"]):
            got = {tuple(res["bindings"][f"A{i}"] for i in range(a)) for res in ans["results"]}
            exp = expected.get(p, set())
            cover[p] = cover.get(p, 0) + (1 if exp else 0)
            if got != exp:
                bad += 1
                print("DIFF", k, p, sorted(got - exp, key=str)[:5], sorted(exp - got, key=str)[:5], [x[0] for x in rules])
    print(f"programas={n} diferencias={bad} reintentos_por_entorno={retries}")
    print("programas con resultados por predicado:", dict(sorted(cover.items())))


if __name__ == "__main__":
    main()
