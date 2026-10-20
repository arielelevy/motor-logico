"""Contrato 2, dominio logic: razonamiento, seguridad de reglas y almacenes persistentes."""
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "clients" / "python"))
from motor_logico import MotorError, comando, consultar  # noqa: E402


def lit(pred, *args, **extra):
    return {"pred": pred, "args": list(args), **extra}


def rule(rid, head, *body):
    return {"id": rid, "head": head, "body": list(body)}


ANCESTRO = [
    rule("anc1", lit("ancestro", "?X", "?Y"), lit("padre", "?X", "?Y")),
    rule("anc2", lit("ancestro", "?X", "?Z"), lit("padre", "?X", "?Y"), lit("ancestro", "?Y", "?Z")),
]


def ask(**body):
    return consultar({"contract": 2, "domain": "logic", **body})


def values(answer, var):
    return [r["bindings"][var] for r in answer["results"]]


class Razonamiento(unittest.TestCase):
    def test_recursion_transitiva_con_ciclo_termina(self):
        facts = [lit("padre", "a", "b"), lit("padre", "b", "c"), lit("padre", "c", "a")]
        out = ask(facts=facts, rules=ANCESTRO, queries=[lit("ancestro", "a", "?Q")])
        self.assertEqual(values(out["answers"][0], "Q"), ["a", "b", "c"])
        self.assertTrue(out["consistent"])
        self.assertIsNone(out["store"])

    def test_cadena_larga_es_semi_ingenua_y_completa(self):
        n = 300
        facts = [lit("padre", f"p{i:04}", f"p{i + 1:04}") for i in range(n)]
        out = ask(facts=facts, rules=ANCESTRO, queries=[lit("ancestro", "p0000", "?Q")],
                  limits={"max_results": 1})
        self.assertEqual(out["answers"][0]["count"], n)
        self.assertTrue(out["answers"][0]["truncated"])
        self.assertEqual(out["stats"]["derived"], n * (n + 1) // 2)

    def test_negacion_estratificada_y_comparaciones(self):
        facts = [lit("persona", "ana"), lit("persona", "beto"), lit("padre", "ana", "beto"),
                 lit("edad", "ana", 40), lit("edad", "beto", 10)]
        rules = [rule("raiz", lit("raiz", "?X"), lit("persona", "?X"), lit("padre", "?_", "?X", **{"not": True})),
                 rule("mayor", lit("mayor", "?X"), lit("edad", "?X", "?E"), {"cmp": ">=", "args": ["?E", 18]})]
        out = ask(facts=facts, rules=rules, queries=[lit("raiz", "?R"), lit("mayor", "?M")])
        self.assertEqual(values(out["answers"][0], "R"), ["ana"])
        self.assertEqual(values(out["answers"][1], "M"), ["ana"])
        self.assertEqual(out["stats"]["strata"], 2)

    def test_prueba_explica_reglas_hechos_y_negaciones(self):
        facts = [lit("padre", "a", "b"), lit("padre", "b", "c")]
        out = ask(facts=facts, rules=ANCESTRO, explain=True, queries=[lit("ancestro", "a", "c")])
        answer = out["answers"][0]
        self.assertTrue(answer["holds"])
        proof = answer["results"][0]["proof"]
        self.assertEqual((proof["by"], proof["rule"]), ("rule", "anc2"))
        self.assertEqual([p["fact"]["args"] for p in proof["premises"]], [["a", "b"], ["b", "c"]])
        self.assertEqual(proof["premises"][1]["premises"][0]["by"], "given")

    def test_restricciones_reportan_violaciones(self):
        out = ask(facts=[lit("edad", "x", 15), lit("edad", "y", 30)],
                  constraints=[{"id": "menor", "message": "menor de edad",
                                "body": [lit("edad", "?P", "?E"), {"cmp": "<", "args": ["?E", 18]}]}])
        self.assertFalse(out["consistent"])
        self.assertEqual(out["violations"][0]["results"], [{"bindings": {"P": "x", "E": 15}}])

    def test_textos_que_parecen_codigo_son_datos(self):
        evil = "halt, shell('rm -rf /')"
        out = ask(facts=[lit("x", evil), lit("y", "??literal")], queries=[lit("x", "?V"), lit("y", "?W")])
        self.assertEqual(values(out["answers"][0], "V"), [evil])
        self.assertEqual(values(out["answers"][1], "W"), ["?literal"])

    def test_floats_integrales_se_normalizan(self):
        out = ask(facts=[lit("v", 1), lit("v", 1.0), lit("v", -0.0)], queries=[lit("v", "?N")])
        self.assertEqual(values(out["answers"][0], "N"), [0, 1])

    def test_numeros_y_booleanos(self):
        out = ask(facts=[lit("v", 1, True), lit("v", 2.5, False)], queries=[lit("v", "?N", True)])
        self.assertEqual(values(out["answers"][0], "N"), [1])


class Rechazos(unittest.TestCase):
    def assertCode(self, code, **body):
        with self.assertRaises(MotorError) as ctx:
            ask(**body)
        self.assertEqual(ctx.exception.code, code, ctx.exception.message)

    def test_recursion_a_traves_de_negacion(self):
        self.assertCode("unstratified", rules=[rule("r", lit("p", "?X"), lit("q", "?X"), lit("p", "?X", **{"not": True}))])

    def test_reglas_inseguras(self):
        self.assertCode("unsafe_rule", rules=[rule("r", lit("p", "?X", "?Y"), lit("q", "?X"))])
        self.assertCode("unsafe_rule", rules=[rule("r", lit("p", "?X"), lit("q", "?Y", **{"not": True}), lit("s", "?X"))])
        self.assertCode("unsafe_rule", rules=[rule("r", lit("p", "?X"), lit("q", "?X"), {"cmp": "<", "args": ["?Z", 1]})])

    def test_hecho_con_variable_campo_desconocido_y_store_requerido(self):
        self.assertCode("invalid_fact", facts=[lit("p", "?X")])
        self.assertCode("invalid_request", facts=[], goal="halt")
        self.assertCode("store_required", **{"assert": {"facts": [lit("p", 1)]}})

    def test_ids_duplicados_y_limites(self):
        self.assertCode("duplicate_id", rules=[rule("r", lit("p", 1)), rule("r", lit("q", 1))])
        self.assertCode("invalid_limit", limits={"seconds": 999})

    def test_nombre_de_store_no_escapa_de_la_carpeta(self):
        for name in ["../x", "a/b", "A", "", ".x", "a..b"]:
            self.assertCode("invalid_store", store=name)

    def test_orden_con_constante_no_numerica(self):
        self.assertCode("invalid_rule", rules=[rule("r", lit("p", "?X"), lit("q", "?X"), {"cmp": "<", "args": ["?X", "m"]})])

    def test_surrogate_suelto_se_rechaza_sin_romper_el_cliente(self):
        raw = json.dumps({"contract": 2, "domain": "logic", "facts": [lit("p", "\ud800")]}).encode("ascii")
        result = subprocess.run(comando(), input=raw, capture_output=True, timeout=40)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(json.loads(result.stderr)["code"], "invalid_term")
        self.assertEqual(result.stdout, b"")
        self.assertCode("invalid_request", facts=[lit("p", "\ud800")])

    def test_contrato_desconocido(self):
        with self.assertRaises(MotorError) as ctx:
            consultar({"contract": 4})
        self.assertEqual(ctx.exception.code, "unsupported_contract")


class Persistencia(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.data = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def q(self, **body):
        return consultar({"contract": 2, "domain": "logic", **body}, data_dir=self.data)

    def test_assert_persiste_entre_procesos_con_revision(self):
        out = self.q(store="familia", **{"assert": {"facts": [lit("padre", "a", "b")], "rules": ANCESTRO}})
        self.assertEqual(out["store"]["revision"], 1)
        self.assertTrue(out["store"]["changed"])
        out = self.q(store="familia", facts=[lit("padre", "b", "c")], queries=[lit("ancestro", "a", "?Q")], explain=True)
        self.assertEqual(values(out["answers"][0], "Q"), ["b", "c"])
        self.assertEqual(out["answers"][0]["results"][0]["proof"]["premises"][0]["by"], "stored")
        self.assertEqual(out["store"]["revision"], 1)
        self.assertEqual(out["store"]["facts"], 1)  # el hecho local no se guardó
        self.assertTrue((self.data / "familia.pl").is_file())

    def test_retract_export_y_reasertar_sin_cambios(self):
        self.q(store="s", **{"assert": {"facts": [lit("p", 1), lit("p", 2)], "rules": [rule("r", lit("q", "?X"), lit("p", "?X"))]}})
        out = self.q(store="s", **{"retract": {"facts": [lit("p", 1)], "rules": ["r"]}}, export=True)
        self.assertEqual(out["store"]["revision"], 2)
        self.assertEqual(out["store"]["content"], {"facts": [lit("p", 2)], "rules": [], "constraints": []})
        out = self.q(store="s", **{"assert": {"facts": [lit("p", 2)]}})
        self.assertFalse(out["store"]["changed"])
        self.assertEqual(out["store"]["revision"], 2)

    def test_export_reconstruye_reglas_identicas(self):
        rules = ANCESTRO + [rule("neg", lit("r", "?X"), lit("p", "?X"), lit("q", "?X", "?_", **{"not": True}),
                                 {"cmp": "!=", "args": ["?X", "??a"]})]
        self.q(store="s", **{"assert": {"rules": rules}})
        content = self.q(store="s", export=True)["store"]["content"]
        self.assertEqual(sorted(content["rules"], key=lambda r: r["id"]), sorted(rules, key=lambda r: r["id"]))

    def test_conflicto_de_revision_no_escribe(self):
        self.q(store="s", **{"assert": {"facts": [lit("p", 1)]}})
        with self.assertRaises(MotorError) as ctx:
            self.q(store="s", expect_revision=0, **{"assert": {"facts": [lit("p", 2)]}})
        self.assertEqual(ctx.exception.code, "conflict")
        self.assertEqual(self.q(store="s")["store"]["facts"], 1)

    def test_programa_invalido_no_se_guarda(self):
        with self.assertRaises(MotorError):
            self.q(store="s", **{"assert": {"facts": [lit("p", 1)],
                                            "rules": [rule("r", lit("p", "?X"), lit("p", "?X", **{"not": True}), lit("q", "?X"))]}})
        self.assertEqual(self.q(store="s")["store"]["revision"], 0)
        self.assertFalse((self.data / "s.pl").exists())

    def test_almacen_corrupto_o_con_codigo_se_rechaza(self):
        (self.data / "x.pl").write_text(":- initialization(halt).\nstore_meta(1, 0).\n", encoding="utf-8")
        with self.assertRaises(MotorError) as ctx:
            self.q(store="x")
        self.assertEqual(ctx.exception.code, "corrupt_store")

    def test_emoji_y_par_surrogate_ida_y_vuelta(self):
        # json.dumps con ensure_ascii escribe el emoji como par surrogate 😀.
        raw = json.dumps({"contract": 2, "domain": "logic", "store": "e",
                          "assert": {"facts": [lit("p", "ok 😀")]}}).encode("ascii")
        env = {**os.environ, "MOTOR_LOGICO_DATA": str(self.data), "WSLENV": "MOTOR_LOGICO_DATA/p"}
        result = subprocess.run(comando(), input=raw, capture_output=True, timeout=40, env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.q(store="e", **{"assert": {"facts": [lit("p", "ñandú 😀")]}})
        out = self.q(store="e", queries=[lit("p", "?X")])
        self.assertEqual(values(out["answers"][0], "X"), ["ok 😀", "ñandú 😀"])
        self.assertEqual(out["store"]["revision"], 2)

    def test_candado_de_proceso_muerto_se_recupera(self):
        lock = self.data / "s.pl.lock"
        lock.mkdir()
        (lock / "owner").write_text("owner(999999,999999-1).\n", encoding="utf-8")
        old = time.time() - 10
        os.utime(lock, (old, old))
        out = self.q(store="s", **{"assert": {"facts": [lit("p", 1)]}})
        self.assertEqual(out["store"]["revision"], 1)
        self.assertFalse(lock.exists())

    def test_candado_vivo_bloquea(self):
        lock = self.data / "s.pl.lock"
        lock.mkdir()
        (lock / "owner").write_text("owner(1,1-1).\n", encoding="utf-8")  # el pid 1 siempre existe
        with self.assertRaises(MotorError) as ctx:
            self.q(store="s", **{"assert": {"facts": [lit("p", 1)]}})
        self.assertEqual(ctx.exception.code, "store_busy")
        self.assertTrue(lock.exists())

    def test_escrituras_concurrentes_no_pierden_datos(self):
        def write(i):
            return self.q(store="c", **{"assert": {"facts": [lit("n", i)]}})["store"]["revision"]
        with ThreadPoolExecutor(6) as pool:
            revisions = sorted(pool.map(write, range(6)))
        self.assertEqual(revisions, [1, 2, 3, 4, 5, 6])
        self.assertEqual(self.q(store="c")["store"]["facts"], 6)
        self.assertFalse(any(self.data.glob("*.lock")))


if __name__ == "__main__":
    unittest.main()
