"""Contrato 3, dominio logic: agregados, op, fuentes, huella, explicación de fallos y almacén."""
import json
import random
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "clients" / "python"))
from motor_logico import MotorError, consultar  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
NOT = {"not": True}


def lit(pred, *args, **extra):
    return {"pred": pred, "args": list(args), **extra}


def rule(rid, head, *body):
    return {"id": rid, "head": head, "body": list(body)}


def agg(op, pred, args, as_, value=None):
    d = {"agg": op, "pred": pred, "args": list(args), "as": as_}
    if value:
        d["value"] = value
    return d


def ask(**body):
    return consultar({"contract": 3, "domain": "logic", **body})


def rows(answer, *names):
    return [tuple(r["bindings"][n] for n in names) for r in answer["results"]]


FALLOS = [lit("fallo", "horquilla", 1, source="reglas"), lit("fallo", "horquilla", 2, source="reglas"),
          lit("fallo", "horquilla", 3, source="modelo"), lit("fallo", "clavada", 4),
          lit("concepto", "horquilla"), lit("concepto", "clavada"), lit("concepto", "rayos_x")]


class Agregados(unittest.TestCase):
    def test_count_externo_da_cero_y_de_grupo_no(self):
        rules = [rule("externo", lit("veces", "?C", "?N"), lit("concepto", "?C"), agg("count", "fallo", ["?C", "?_"], "?N")),
                 rule("grupo", lit("con_fallos", "?C", "?N"), agg("count", "fallo", ["?C", "?_"], "?N")),
                 rule("total", lit("total", "?N"), agg("count", "fallo", ["?_", "?_"], "?N")),
                 rule("nada", lit("nada", "?N"), agg("count", "inexistente", ["?_"], "?N"))]
        out = ask(facts=FALLOS, rules=rules, queries=[lit("veces", "?C", "?N"), lit("con_fallos", "?C", "?N"),
                                                      lit("total", "?N"), lit("nada", "?N")])
        self.assertEqual(rows(out["answers"][0], "C", "N"), [("clavada", 1), ("horquilla", 3), ("rayos_x", 0)])
        self.assertEqual(rows(out["answers"][1], "C", "N"), [("clavada", 1), ("horquilla", 3)])
        self.assertEqual(rows(out["answers"][2], "N"), [(4,)])
        self.assertEqual(rows(out["answers"][3], "N"), [(0,)])

    def test_sum_min_max_ignoran_no_numericos(self):
        facts = [lit("t", "a", 2), lit("t", "a", 2.5), lit("t", "a", "x"), lit("t", "b", "x"), lit("t", "c", 0.5),
                 lit("t", "c", 0.5, "otra"), lit("t", "c", 1.5)]
        rules = [rule("s", lit("s", "?K", "?S"), agg("sum", "t", ["?K", "?V"], "?S", "?V")),
                 rule("mn", lit("mn", "?K", "?M"), agg("min", "t", ["?K", "?V"], "?M", "?V")),
                 rule("mx", lit("mx", "?M"), agg("max", "t", ["?_", "?V"], "?M", "?V"))]
        out = ask(facts=facts, rules=rules, queries=[lit("s", "?K", "?S"), lit("mn", "?K", "?M"), lit("mx", "?M")])
        # t/2 y t/3 son relaciones distintas; 0.5 + 1.5 = 2.0 vuelve como 2; b sólo tiene texto.
        self.assertEqual(rows(out["answers"][0], "K", "S"), [("a", 4.5), ("b", 0), ("c", 2)])
        self.assertEqual(rows(out["answers"][1], "K", "M"), [("a", 2), ("c", 0.5)])
        self.assertEqual(rows(out["answers"][2], "M"), [(2.5,)])

    def test_variable_de_grupo_usada_en_una_negacion(self):
        facts = [lit("e", 1, 2), lit("e", 1, 3), lit("e", 2, 3), lit("malo", 2)]
        rules = [rule("r", lit("h", "?N"), agg("count", "e", ["?X", "?_"], "?N"), lit("malo", "?X", **NOT))]
        out = ask(facts=facts, rules=rules, queries=[lit("h", "?N")])
        self.assertEqual(rows(out["answers"][0], "N"), [(2,)])

    def test_prueba_lista_lo_contado_con_tope(self):
        facts = [lit("f", i, source="reglas") for i in range(60)]
        out = ask(facts=facts, rules=[rule("n", lit("n", "?N"), agg("count", "f", ["?_"], "?N"))],
                  explain=True, limits={"proof_depth": 3}, queries=[lit("n", "?N")])
        result = out["answers"][0]["results"][0]
        premise = result["proof"]["premises"][0]
        self.assertEqual((premise["agg"], premise["result"], premise["truncated"]), ("count", 60, True))
        self.assertEqual(premise["of"], {"pred": "f", "args": ["?_"]})
        self.assertEqual(len(premise["items"]), 50)
        self.assertEqual(premise["items"][0], {"fact": {"pred": "f", "args": [0]}, "by": "given", "sources": ["reglas"]})
        self.assertEqual(result["sources"], ["reglas"])

    def test_agregado_en_una_restriccion(self):
        out = ask(facts=FALLOS, constraints=[{"id": "demasiados", "message": "x", "body": [
            lit("concepto", "?C"), agg("count", "fallo", ["?C", "?_"], "?N"), {"cmp": ">=", "args": ["?N", 3]}]}])
        self.assertEqual(out["violations"][0]["results"],
                         [{"bindings": {"C": "horquilla", "N": 3}, "sources": ["modelo", "reglas"]}])


class Aritmetica(unittest.TestCase):
    def test_op_calcula_y_normaliza(self):
        facts = [lit("v", "a", 7), lit("v", "b", 6), lit("v", "c", "x"), lit("v", "d", 0)]
        rules = [rule("div", lit("div", "?K", "?R"), lit("v", "?K", "?A"), {"op": "/", "args": [12, "?A"], "as": "?R"}),
                 rule("med", lit("med", "?K", "?R"), lit("v", "?K", "?A"), {"op": "/", "args": ["?A", 2], "as": "?R"}),
                 rule("enc", lit("enc", "?K", "?Z"), lit("v", "?K", "?A"), {"op": "*", "args": ["?A", 2], "as": "?Y"},
                      {"op": "-", "args": ["?Y", 1], "as": "?Z"}, {"cmp": ">", "args": ["?Z", 0]})]
        out = ask(facts=facts, rules=rules, explain=True,
                  queries=[lit("div", "?K", "?R"), lit("med", "?K", "?R"), lit("enc", "?K", "?Z")])
        self.assertEqual(rows(out["answers"][0], "K", "R"), [("a", 12 / 7), ("b", 2)])  # d: división por cero
        self.assertEqual(rows(out["answers"][1], "K", "R"), [("a", 3.5), ("b", 3), ("d", 0)])
        self.assertEqual(rows(out["answers"][2], "K", "Z"), [("a", 13), ("b", 11)])
        ops = [p for p in out["answers"][2]["results"][0]["proof"]["premises"] if "op" in p]
        self.assertEqual(ops, [{"op": "*", "args": [7, 2], "result": 14}, {"op": "-", "args": [14, 1], "result": 13}])


class Cotas(unittest.TestCase):
    def test_enteros_fuera_de_2_53_no_se_cumplen(self):
        rules = [rule("cuad", lit("c", "?Y"), lit("v", "?X"), {"op": "*", "args": ["?X", "?X"], "as": "?Y"}),
                 rule("tot", lit("t", "?S"), agg("sum", "v", ["?X"], "?S", "?X"))]
        out = ask(facts=[lit("v", 2 ** 30), lit("v", 2 ** 26), lit("v", 2 ** 53)], rules=rules,
                  queries=[lit("c", "?Y"), lit("t", "?S")])
        self.assertEqual(rows(out["answers"][0], "Y"), [(2 ** 52,)])
        self.assertEqual(out["answers"][1]["count"], 0)


class Rechazos(unittest.TestCase):
    def assertCode(self, code, contract=3, **body):
        with self.assertRaises(MotorError) as ctx:
            consultar({"contract": contract, "domain": "logic", **body})
        self.assertEqual(ctx.exception.code, code, ctx.exception.message)

    def test_op_recursiva_se_rechaza(self):
        self.assertCode("unstratified", rules=[
            rule("base", lit("n", 0)),
            rule("suc", lit("n", "?Y"), lit("n", "?X"), {"op": "+", "args": ["?X", 1], "as": "?Y"})])

    def test_agregado_recursivo_se_rechaza(self):
        self.assertCode("unstratified", rules=[rule("r", lit("p", "?N"), agg("count", "p", ["?_"], "?N"))])
        # También a través de otra regla, y con un positivo del mismo estrato.
        self.assertCode("unstratified", rules=[
            rule("a", lit("p", "?X"), lit("q", "?X")),
            rule("b", lit("q", "?N"), lit("p", "?X"), agg("count", "e", ["?X"], "?N"))])

    def test_formas_invalidas(self):
        bad = {
            "invalid_rule": [agg("count", "e", ["?X"], "?N", "?X"), agg("sum", "e", ["?X"], "?N"),
                             agg("sum", "e", ["?X"], "?N", "?Z"), agg("avg", "e", ["?X"], "?N"),
                             agg("count", "e", ["?X"], "?_"), {"op": "%", "args": [1, 2], "as": "?Z"},
                             {"op": "+", "args": [1, "a"], "as": "?Z"}, {"op": "+", "args": [1], "as": "?Z"}],
            "unsafe_rule": [agg("count", "e", ["?N"], "?N")],
        }
        for code, items in bad.items():
            for item in items:
                with self.subTest(item=item):
                    self.assertCode(code, rules=[rule("r", lit("h", "?Z"), lit("b", "?Z"), item)])

    def test_variables_mal_ligadas(self):
        cases = [
            [lit("b", "?N"), agg("count", "e", ["?_"], "?N")],  # as ya ligado por un positivo
            [agg("count", "e", ["?X"], "?N"), agg("count", "f", ["?X"], "?M")],  # ?X la ligan dos agregados
            [lit("b", "?X"), {"op": "+", "args": ["?Y", 1], "as": "?Z"}, {"op": "+", "args": ["?Z", 1], "as": "?Y"}],
            [lit("b", "?X"), {"op": "+", "args": ["?W", 1], "as": "?Z"}],
            [lit("b", "?X"), {"op": "+", "args": ["?_", 1], "as": "?Z"}],
        ]
        for body in cases:
            with self.subTest(body=body):
                self.assertCode("unsafe_rule", rules=[rule("r", lit("h", "?X"), *body)])

    def test_source_invalido_y_en_retract(self):
        for source in ["Motor", "", "a" * 33, "1x", 3]:
            self.assertCode("invalid_fact", facts=[lit("p", 1, source=source)])
        with tempfile.TemporaryDirectory() as d:
            with self.assertRaises(MotorError) as ctx:
                consultar({"contract": 3, "domain": "logic", "store": "s",
                           "retract": {"facts": [lit("p", 1, source="motor")]}}, data_dir=d)
            self.assertEqual(ctx.exception.code, "invalid_fact")

    def test_contrato_2_no_acepta_lo_nuevo(self):
        self.assertCode("invalid_request", contract=2, facts=[lit("p", 1, source="motor")])
        self.assertCode("invalid_request", contract=2, rules=[rule("r", lit("h", "?N"), agg("count", "e", ["?_"], "?N"))])
        self.assertCode("invalid_request", contract=2, explain_failures=True)
        out = consultar({"contract": 2, "domain": "logic", "facts": [lit("p", 1)], "queries": [lit("p", "?X")]})
        self.assertNotIn("engine", out)
        self.assertNotIn("sources", out["answers"][0]["results"][0])


class Fuentes(unittest.TestCase):
    def test_un_hecho_con_dos_fuentes(self):
        facts = [lit("p", 1, source="motor"), lit("p", 1, source="fragmento"), lit("p", 1), lit("q", 2, source="prior")]
        rules = [rule("r", lit("r", "?X", "?Y"), lit("p", "?X"), lit("q", "?Y"))]
        out = ask(facts=facts, rules=rules, explain=True, queries=[lit("r", "?X", "?Y"), lit("p", "?X")])
        result = out["answers"][0]["results"][0]
        self.assertEqual(result["sources"], ["fragmento", "motor", "prior"])
        leaf = result["proof"]["premises"][0]
        self.assertEqual(leaf, {"fact": {"pred": "p", "args": [1]}, "by": "given", "sources": ["fragmento", "motor"]})
        self.assertEqual(out["answers"][1]["count"], 1)
        self.assertEqual(out["stats"]["facts"], 3)

    def test_negacion_no_aporta_fuentes(self):
        out = ask(facts=[lit("c", "a", source="modelo"), lit("s", "b", source="motor")],
                  rules=[rule("r", lit("f", "?C"), lit("c", "?C"), lit("s", "?C", **NOT))], queries=[lit("f", "?C")])
        self.assertEqual(out["answers"][0]["results"][0]["sources"], ["modelo"])


class Huella(unittest.TestCase):
    def test_no_depende_del_orden_y_cambia_con_el_programa(self):
        facts = [lit("e", i, i + 1, source="motor") for i in range(10)] + [lit("e", 0, 0)]
        rules = [rule("a", lit("p", "?X", "?Y"), lit("e", "?X", "?Y")),
                 rule("b", lit("p", "?X", "?Z"), lit("e", "?X", "?Y"), lit("p", "?Y", "?Z"))]
        base = ask(facts=facts, rules=rules)
        self.assertEqual(base["engine"], {"name": "motor-logico", "version": "0.2.0"})
        self.assertRegex(base["program_hash"], r"^sha256:[0-9a-f]{64}$")
        r = random.Random(3)
        for _ in range(3):
            f2, r2 = facts[:], rules[:]
            r.shuffle(f2)
            r2.reverse()
            self.assertEqual(ask(facts=f2 + f2[:3], rules=r2)["program_hash"], base["program_hash"])
        otra = facts[:-1] + [lit("e", 0, 0, source="prior")]
        self.assertNotEqual(ask(facts=otra, rules=rules)["program_hash"], base["program_hash"])
        self.assertNotEqual(ask(facts=facts, rules=rules[:1])["program_hash"], base["program_hash"])

    def test_misma_huella_misma_salida(self):
        # Dos derivaciones de h(1) con fuentes distintas: la elegida no depende del orden de las reglas.
        facts = [lit("a", 1, source="motor"), lit("c", 1, source="modelo")]
        rules = [rule("r1", lit("h", "?X"), lit("a", "?X")), rule("r2", lit("h", "?X"), lit("c", "?X"))]
        uno = ask(facts=facts, rules=rules, explain=True, queries=[lit("h", "?X")])
        otro = ask(facts=facts[::-1], rules=rules[::-1], explain=True, queries=[lit("h", "?X")])
        self.assertEqual(uno, otro)

    def test_almacen_o_consulta_dan_la_misma_huella(self):
        facts = [lit("p", 1, source="motor"), lit("p", 2)]
        rules = [rule("q", lit("q", "?X"), lit("p", "?X"))]
        with tempfile.TemporaryDirectory() as d:
            consultar({"contract": 3, "domain": "logic", "store": "h",
                       "assert": {"facts": facts[:1], "rules": rules}}, data_dir=d)
            stored = consultar({"contract": 3, "domain": "logic", "store": "h", "facts": facts[1:]}, data_dir=d)
        self.assertEqual(stored["program_hash"], ask(facts=facts, rules=rules)["program_hash"])


class Fallos(unittest.TestCase):
    def test_explica_el_primer_elemento_que_no_se_cumple(self):
        rules = [rule("frente", lit("frente", "?C"), lit("concepto", "?C"), lit("sostenido", "?C", **NOT),
                      lit("bloqueado", "?C", **NOT)),
                 rule("otra", lit("frente", "?C"), lit("urgente", "?C")),
                 rule("ajena", lit("frente", "nunca"), lit("concepto", "nunca"))]
        out = ask(facts=[lit("concepto", "a"), lit("bloqueado", "a"), lit("concepto", "b")], rules=rules,
                  explain_failures=True, queries=[lit("frente", "a"), lit("frente", "b"), lit("sin_reglas", "?X")])
        self.assertEqual(out["answers"][0]["failures"], [
            {"rule": "frente", "position": 3, "item": lit("bloqueado", "?C", **NOT)},
            {"rule": "otra", "position": 1, "item": lit("urgente", "?C")}])
        self.assertNotIn("failures", out["answers"][1])
        self.assertEqual(out["answers"][2]["failures"], [])


class Almacen(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.data = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def q(self, contract=3, **body):
        return consultar({"contract": contract, "domain": "logic", **body}, data_dir=self.data)

    def test_fuentes_persisten_se_unen_y_se_exportan(self):
        self.q(store="s", **{"assert": {"facts": [lit("p", 1, source="motor")]}})
        self.q(store="s", **{"assert": {"facts": [lit("p", 1, source="modelo"), lit("p", 2)],
                                        "rules": [rule("c", lit("c", "?N"), agg("count", "p", ["?_"], "?N"))]}})
        text = (self.data / "s.pl").read_text(encoding="utf-8")
        self.assertIn("store_meta(2,2)", text.replace(" ", ""))
        out = self.q(store="s", facts=[lit("p", 1, source="prior")], explain=True, export=True,
                     queries=[lit("p", 1), lit("c", "?N")])
        self.assertEqual(out["answers"][0]["results"][0]["proof"]["sources"], ["modelo", "motor", "prior"])
        self.assertEqual(out["answers"][0]["results"][0]["proof"]["by"], "stored")
        self.assertEqual(rows(out["answers"][1], "N"), [(2,)])
        content = out["store"]["content"]
        self.assertEqual(content["facts"], [lit("p", 1, source="modelo"), lit("p", 1, source="motor"), lit("p", 2)])
        # Lo exportado se vuelve a asertar tal cual en otro almacén y da la misma huella.
        copy = self.q(store="t", **{"assert": content})
        self.assertEqual(copy["program_hash"], self.q(store="s")["program_hash"])
        # retract quita el hecho con todas sus fuentes.
        out = self.q(store="s", **{"retract": {"facts": [lit("p", 1)]}}, export=True)
        self.assertEqual(out["store"]["content"]["facts"], [lit("p", 2)])

    def test_formato_minimo_y_compatibilidad_con_el_contrato_2(self):
        self.q(contract=2, store="viejo", **{"assert": {"facts": [lit("p", 1)]}})
        out = self.q(store="viejo", queries=[lit("p", "?X")])
        self.assertEqual(rows(out["answers"][0], "X"), [(1,)])
        self.assertEqual(out["store"]["revision"], 1)
        # El 3 escribe formato 1 mientras no haga falta nada nuevo: el 2 lo sigue leyendo.
        self.q(store="viejo", **{"assert": {"facts": [lit("p", 2)], "rules": [rule("q", lit("q", "?X"), lit("p", "?X"))]}})
        self.assertEqual(self.q(contract=2, store="viejo")["store"]["facts"], 2)
        # Con una fuente, un agregado o una op pasa al formato 2, y el 2 avisa que es del 3.
        for change in [{"facts": [lit("p", 3, source="motor")]},
                       {"rules": [rule("n", lit("n", "?N"), agg("count", "p", ["?_"], "?N"))]},
                       {"rules": [rule("d", lit("d", "?Y"), lit("p", "?X"), {"op": "*", "args": ["?X", 2], "as": "?Y"})]}]:
            with self.subTest(change=change):
                name = "s" + str(len(change["facts"]) if "facts" in change else change["rules"][0]["id"])
                self.q(store=name, **{"assert": change})
                self.assertIn("store_meta(2,", (self.data / f"{name}.pl").read_text(encoding="utf-8").replace(" ", ""))
                with self.assertRaises(MotorError) as ctx:
                    self.q(contract=2, store=name)
                self.assertEqual(ctx.exception.code, "corrupt_store")
                self.assertIn("contrato 3", ctx.exception.message)
        # Sin lo nuevo vuelve al formato 1.
        self.q(store="s1", **{"retract": {"facts": [lit("p", 3)]}, "assert": {"facts": [lit("p", 4)]}})
        self.assertEqual(self.q(contract=2, store="s1")["store"]["facts"], 1)


class Chesstudia(unittest.TestCase):
    def test_prerrequisitos_frente_y_repeticiones(self):
        consulta = json.loads((ROOT / "examples" / "chesstudia.json").read_text(encoding="utf-8"))
        out = consultar(consulta)
        frente, bloqueado, repite, desviacion, horquilla = out["answers"]
        self.assertEqual([b for (b,) in rows(frente, "C")],
                         ["alfiles_de_distinto_color", "ataque_doble", "mate_del_pasillo", "peon_pasado_exterior",
                          "peon_pasado_protegido", "rayos_x", "torre_en_septima"])
        self.assertEqual([b for (b,) in rows(bloqueado, "C")],
                         ["descubierto", "desviacion", "horquilla", "pieza_atrapada", "sobrecarga"])
        self.assertEqual([b for (b,) in rows(repite, "C")], ["ataque_doble", "horquilla"])
        self.assertEqual(repite["results"][1]["sources"], ["reglas"])
        # La prueba recorre la cadena entera: desviación → sobrecarga → ataque doble, sin sostener.
        proof = desviacion["results"][0]["proof"]
        raiz = proof["premises"][0]
        self.assertEqual(raiz["fact"], lit("raiz", "desviacion", "ataque_doble"))
        cadena = raiz["premises"][0]
        self.assertEqual(cadena["rule"], "req-transitivo")
        self.assertEqual([p["fact"]["args"] for p in cadena["premises"]],
                         [["desviacion", "sobrecarga"], ["sobrecarga", "ataque_doble"]])
        self.assertEqual(raiz["premises"][1], {"not": lit("sostenido", "ataque_doble")})
        self.assertEqual(horquilla["failures"], [{"rule": "frente", "position": 3, "item": lit("bloqueado", "?C", **NOT)}])
        self.assertEqual([v["results"][0]["bindings"] for v in out["violations"]], [{"C": "desviacion"}])


if __name__ == "__main__":
    unittest.main()
