"""Pruebas del contrato sin importar Lienzo ni necesitar librerías Python externas."""
import json
import os
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]


def query(data):
    return raw_query(json.dumps(data))


def raw_query(text):
    engine = ROOT / "main.pl"
    if os.name == "nt":
        path = "/mnt/" + engine.drive[0].lower() + engine.as_posix()[len(engine.drive):]
        command = ["wsl.exe", "-d", "Ubuntu", "--", "swipl"]
    else:
        path = str(engine)
        command = ["swipl"]
    return subprocess.run(command + ["-q", "-f", "none", "-s", path, "-g", "main", "-t", "halt"],
                          input=text, capture_output=True, text=True, timeout=12,
                          creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)


class Protocol(unittest.TestCase):
    def test_empty_snapshot_is_honest_and_has_version(self):
        result = query({"contract": 1, "domain": "learning", "now": 0, "context": {},
                        "nodes": [], "edges": [], "beliefs": []})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {"contract": 1, "domain": "learning", "rules": 1,
                                                     "authority": "observation_only", "conclusions": []})

    def test_unknown_domain_is_not_empty_success(self):
        result = query({"contract": 1, "domain": "chess"})
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, "")
        self.assertIn("error", json.loads(result.stderr))

    def test_example_is_applicable(self):
        data = json.loads((ROOT / "examples" / "learning.json").read_text(encoding="utf-8"))
        result = query(data)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["conclusions"],
                         [{"id": "b", "status": "aplicable", "rule": "aplicable", "chains": []}])

    def test_fallen_chain_through_decisions(self):
        data = json.loads((ROOT / "examples" / "learning.json").read_text(encoding="utf-8"))
        data["nodes"] += [{"id": "d", "kind": "decision", "state": "vigente"},
                          {"id": "h", "kind": "hallazgo", "state": "rechazado"}]
        data["edges"] += [{"from": "b", "to": "d", "relation": "motivada_por"},
                          {"from": "d", "to": "b", "relation": "motivada_por"},
                          {"from": "d", "to": "h", "relation": "motivada_por"}]
        result = query(data)
        self.assertEqual(result.returncode, 0, result.stderr)
        conclusion = json.loads(result.stdout)["conclusions"][0]
        self.assertEqual((conclusion["status"], conclusion["chains"]), ("respaldo_caido", [["b", "d", "h"]]))

    def test_trailing_whitespace_ok_trailing_text_is_error(self):
        empty = {"contract": 1, "domain": "learning", "now": 0, "context": {}, "nodes": [], "edges": [], "beliefs": []}
        for suffix, code in [("\n", 0), ("  \r\n\t\n", 0), ("\n{}", 2), (" basura", 2)]:
            result = raw_query(json.dumps(empty) + suffix)
            self.assertEqual(result.returncode, code, (suffix, result.stderr))
            if code:
                self.assertEqual(result.stdout, "")
                self.assertEqual(json.loads(result.stderr)["code"], "invalid_json")

    def test_edge_to_missing_node_is_error(self):
        result = query({"contract": 1, "domain": "learning", "now": 0, "context": {}, "beliefs": [],
                        "nodes": [], "edges": [{"from": "x", "to": "y", "relation": "apoya"}]})
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, "")
        self.assertIn("code", json.loads(result.stderr))


if __name__ == "__main__":
    unittest.main()
