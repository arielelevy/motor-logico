"""Cliente mínimo del motor lógico, sólo biblioteca estándar. Copiable a cualquier repo.

    from motor_logico import consultar
    respuesta = consultar({"contract": 3, "domain": "logic", "facts": [...], "queries": [...]})

En Windows ejecuta SWI-Prolog dentro de WSL (distro MOTOR_LOGICO_WSL_DISTRO, por defecto
Ubuntu); en Linux y macOS usa `swipl` del PATH. No instala nada.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

ENGINE = Path(os.environ.get("MOTOR_LOGICO_ENGINE", Path(__file__).resolve().parents[2] / "main.pl"))
MAX_INPUT = 8 * 1024 * 1024


class MotorError(Exception):
    """El motor no respondió o rechazó la consulta. `code` viene del contrato o es local."""

    def __init__(self, code: str, message: str):
        super().__init__(f"{code}: {message}")
        self.code = code
        self.message = message


def _wsl_path(path: Path) -> str:
    path = path.resolve()
    if not path.drive.endswith(":"):
        raise MotorError("unavailable", f"WSL necesita una ruta con unidad, no {path.drive}")
    return "/mnt/" + path.drive[0].lower() + path.as_posix()[len(path.drive):]


def comando(engine: Path = ENGINE, timeout: float = 40) -> list[str]:
    # `timeout` de coreutils corre junto a swipl: matar wsl.exe no mata al proceso Linux,
    # que seguiría vivo con el candado del almacén tomado.
    args = ["-q", "-f", "none", "--stack-limit=512m"]
    limit = ["timeout", "--kill-after=2", str(max(1, int(timeout)))]
    if os.name == "nt":
        distro = os.environ.get("MOTOR_LOGICO_WSL_DISTRO", "Ubuntu")
        return ["wsl.exe", "-d", distro, "--", *limit, "swipl", *args, "-s", _wsl_path(engine),
                "-g", "main", "-t", "halt"]
    return [*(limit if shutil.which("timeout") else []), "swipl", *args, "-s", str(engine),
            "-g", "main", "-t", "halt"]


def consultar(consulta: dict, *, engine: Path = ENGINE, data_dir: str | os.PathLike | None = None,
              timeout: float = 40) -> dict:
    """Envía una consulta y devuelve la respuesta. Lanza MotorError ante cualquier fallo.

    Si vence `timeout` durante una escritura, no se sabe si se aplicó: releer el `store` y
    reconciliar con `expect_revision`.
    """
    try:
        data = (json.dumps(consulta, ensure_ascii=False, allow_nan=False) + "\n").encode("utf-8")
    except (TypeError, ValueError, UnicodeEncodeError) as exc:
        raise MotorError("invalid_request", f"La consulta no es JSON UTF-8 serializable ({exc})") from None
    if len(data) > MAX_INPUT:
        raise MotorError("too_large", "La consulta supera 8 MiB")
    env = dict(os.environ)
    if data_dir is not None:
        env["MOTOR_LOGICO_DATA"] = str(Path(data_dir).resolve())
    if os.name == "nt" and "MOTOR_LOGICO_DATA" in env:
        # /p traduce la ruta de Windows a /mnt/<unidad>/… al cruzar a WSL.
        env["WSLENV"] = ":".join(filter(None, [env.get("WSLENV"), "MOTOR_LOGICO_DATA/p"]))
    try:
        result = subprocess.run(comando(engine, timeout), input=data, capture_output=True,
                                timeout=timeout + 5, env=env,
                                creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)
    except (OSError, subprocess.SubprocessError) as exc:
        raise MotorError("unavailable", f"No se pudo ejecutar SWI-Prolog ({type(exc).__name__})") from None
    if result.returncode:
        stderr = result.stderr.decode("utf-8", "replace").strip()
        try:
            error = json.loads(stderr.splitlines()[-1])
            code, message = error.get("code", "error"), error["error"]
        except (ValueError, IndexError, KeyError, TypeError, AttributeError):
            code = "time_limit" if result.returncode in (124, 137) else "unavailable"
            message = (stderr or f"código {result.returncode}")[:500]
        raise MotorError(code, message)
    try:
        return json.loads(result.stdout.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        raise MotorError("invalid_output", "La respuesta no es JSON UTF-8 válido") from None


def main() -> int:
    """`python motor_logico.py < consulta.json`: imprime la respuesta o el error."""
    try:
        print(json.dumps(consultar(json.load(sys.stdin)), ensure_ascii=False, indent=2))
        return 0
    except (MotorError, ValueError) as exc:
        code, message = (exc.code, exc.message) if isinstance(exc, MotorError) else ("invalid_json", str(exc))
        print(json.dumps({"error": message, "code": code}, ensure_ascii=False), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
