"""Contrato 4 independiente: JSONL, aislamiento y proyecciones como datos."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[1]


def motor_path(path):
    text = Path(path).as_posix()
    return "/mnt/" + Path(path).drive[0].lower() + text[len(Path(path).drive):] if os.name == "nt" else text


def requests(messages):
    cmd = ["wsl.exe", "-d", "Ubuntu", "--", "swipl"] if os.name == "nt" else ["swipl"]
    proc = subprocess.Popen(
        cmd + ["-q", "-f", "none", "-s", motor_path(ROOT / "servicio.pl"), "-g", "servicio_main", "-t", "halt"],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0,
    )
    timer = threading.Timer(30, proc.kill)
    timer.start()
    try:
        results = []
        for msg in messages:
            proc.stdin.write(json.dumps(msg) + "\n")
            proc.stdin.flush()
            results.append(json.loads(proc.stdout.readline()))
        proc.stdin.close()  # EOF cancela una consulta activa: cerrar sólo tras recibir la última
        proc.wait(timeout=5)
        if proc.returncode:
            raise AssertionError(proc.stderr.read())
        return results
    finally:
        timer.cancel()
        if proc.poll() is None:
            proc.kill()
            proc.wait(timeout=5)
        for stream in (proc.stdin, proc.stdout, proc.stderr):
            stream.close()


def message(rid, facts=None, files=None):
    return {"contract": 4, "request_id": rid, "op": "query", "archivos": files or [],
            "payload": {"contract": 3, "domain": "logic", "facts": facts or [], "rules": [],
                        "queries": [{"pred": "dato", "args": ["?X"]}]}}


class Servicio(unittest.TestCase):
    def test_reusa_pid_y_no_filtra_hechos_entre_consultas(self):
        one, two = requests([message("uno", [{"pred": "dato", "args": ["uno"]}]), message("dos")])
        self.assertTrue(one["ok"])
        self.assertEqual(one["pid"], two["pid"])
        self.assertEqual(one["resultado"]["answers"][0]["count"], 1)
        self.assertEqual(two["resultado"]["answers"][0]["count"], 0)

    def test_directiva_no_se_ejecuta_y_siguiente_consulta_funciona(self):
        with tempfile.TemporaryDirectory() as tmp:
            sentinel = Path(tmp) / "prohibido.txt"
            path = Path(tmp) / "directiva.pl"
            path.write_text(':- setup_call_cleanup(open("' + motor_path(sentinel) +
                            '",write,S),write(S,peligro),close(S)).\n', encoding="utf-8")
            files = [{"path": motor_path(path), "hash": hashlib.sha256(path.read_bytes()).hexdigest()}]
            bad, good = requests([message("mala", files=files), message("buena")])
            self.assertFalse(bad["ok"])
            self.assertFalse(sentinel.exists())
            self.assertTrue(good["ok"])

    def test_hash_y_almacen_rechazados_sin_ensuciar_siguiente_consulta(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "datos.pl"
            path.write_text('proyecto("aa").\n', encoding="utf-8")
            a = message("hash", files=[{"path": motor_path(path), "hash": "0" * 64}])
            b = message("store")
            b["payload"]["store"] = "prohibido"
            badhash, badstore, good = requests([a, b, message("bien")])
            self.assertEqual(badhash["code"], "stale_file")
            self.assertFalse(badstore["ok"])
            self.assertTrue(good["ok"])


if __name__ == "__main__":
    unittest.main()

