# Motor lógico

**Hechos de entrada. Reglas explícitas. Conclusiones con respaldo.**

Motor SWI-Prolog que cualquier repo puede consultar por un proceso: entra un JSON, sale un JSON.
Deduce con reglas declaradas como datos, explica cada conclusión con su prueba y, si se lo pide,
guarda hechos y reglas en almacenes con nombre. Nunca ejecuta código ni goals del cliente.

`v0.1.0` · dos contratos:

| Contrato | Dominio | Para qué | Persistencia |
|---|---|---|---|
| `1` · reglas `1` | `learning` | Segunda opinión sobre creencias y aprendizaje de Lienzo | No |
| `2` | `logic` | Razonamiento general: Datalog con recursión, negación, comparaciones, restricciones y pruebas | Opcional, por `store` |

## Una consulta, sin depender del motor

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/img/prolog-dark.svg">
  <img alt="Fichero autónomo con lámpara verde junto a una estación Prolog separada: una bandeja lleva la consulta y otra devuelve las conclusiones; el fichero sigue funcionando sin la estación" src="docs/img/prolog-light.svg">
</picture>

La aplicación conserva sus datos y su funcionamiento normal. Cuando necesita deducir o contrastar
algo, consulta al motor y recibe conclusiones con su explicación. Si falta Prolog o la consulta
falla, recibe un error explícito (código `2`) y sigue sin ese razonamiento.

**Hoy:** Lienzo usa el contrato 1 desde un botón de consulta manual. El contrato 2 está disponible
para cualquier repo. **Pendiente:** reglas de ajedrez para Chesstudia (no hereda las de aprendizaje).

## Empezar en dos minutos

Requiere SWI-Prolog ya instalado (probado con 9.0.4). En Windows se usa el de Ubuntu WSL.

```sh
swipl -q -f none -s main.pl -g main -t halt < examples/logic.json
```

```powershell
Get-Content -Raw examples/logic.json | wsl -d Ubuntu -- swipl -q -f none -s /mnt/d/Apps/motor-logico/main.pl -g main -t halt
```

[examples/logic.json](examples/logic.json) declara qué servicio depende de cuál y cuál está caído.
El motor responde que `api`, `auth` y `web` están afectados (con la cadena de reglas que lo prueba),
que `reportes` está sano por negación, y que la restricción `servicio-afectado` se viola para `web`.

Desde Python, sin dependencias, con [clients/python/motor_logico.py](clients/python/motor_logico.py):

```python
from motor_logico import consultar, MotorError

r = consultar({
    "contract": 2, "domain": "logic",
    "facts": [{"pred": "padre", "args": ["ana", "beto"]}, {"pred": "padre", "args": ["beto", "carla"]}],
    "rules": [
        {"id": "a1", "head": {"pred": "ancestro", "args": ["?X", "?Y"]},
         "body": [{"pred": "padre", "args": ["?X", "?Y"]}]},
        {"id": "a2", "head": {"pred": "ancestro", "args": ["?X", "?Z"]},
         "body": [{"pred": "padre", "args": ["?X", "?Y"]}, {"pred": "ancestro", "args": ["?Y", "?Z"]}]},
    ],
    "queries": [{"pred": "ancestro", "args": ["ana", "?Q"]}],
})
[x["bindings"]["Q"] for x in r["answers"][0]["results"]]  # ['beto', 'carla']
```

## Usarlo desde otro repo

El motor no se instala ni se importa: se ejecuta. Tres formas, de la más simple a la más integrada:

1. **Copiar el cliente.** `clients/python/motor_logico.py` es un archivo; copialo y apuntalo con
   `MOTOR_LOGICO_ENGINE=/ruta/a/main.pl`. Arma el comando (WSL en Windows), traduce rutas y
   convierte cualquier fallo en `MotorError(code, message)`.
2. **Proceso directo** desde cualquier lenguaje: escribí el JSON en stdin de
   `swipl -q -f none -s main.pl -g main -t halt`, leé stdout; código distinto de 0 es error.
3. **Un adaptador propio**, como el de Lienzo, que valida versiones y limita entrada y concurrencia.

Cloná el repo una sola vez (por ejemplo en `D:/Apps/motor-logico`) y apuntá cada proyecto ahí.
Cada consulta es un proceso aislado; no hay servidor, HTTP ni MCP que mantener.

| Variable | Uso |
|---|---|
| `MOTOR_LOGICO_ENGINE` | Ruta a `main.pl` para el cliente Python |
| `MOTOR_LOGICO_DATA` | Carpeta de almacenes (por defecto `data/` junto a `main.pl`, ignorada por Git) |
| `MOTOR_LOGICO_WSL_DISTRO` | Distro de WSL en Windows (por defecto `Ubuntu`) |

## Un contrato pequeño

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/img/contrato-dark.svg">
  <img alt="Lectora de fichas con bandeja de entrada, peines fijos de reglas y bandeja de respuesta: los datos atraviesan la máquina sin convertirse en código ejecutable" src="docs/img/contrato-light.svg">
</picture>

Un JSON por entrada estándar, un JSON por salida estándar. Las reglas viajan como datos y el motor
las interpreta contra sus propios hechos: un texto como `"halt, shell('rm')"` es sólo un valor.

| Contrato 2: entra | Vuelve |
|---|---|
| `facts`: hechos `{pred, args}` sólo para esta consulta | `answers`: por query, `holds`, `count` y `bindings` |
| `rules`: `{id, head, body}`; `?X` es variable, `?_` anónima | `proof` por respuesta con `explain: true` |
| `constraints`: cuerpos que no deberían cumplirse | `consistent` y `violations` con sus ligaduras |
| `queries`: patrones a responder | `stats`: hechos, derivados, estratos, iteraciones |
| `store`, `assert`, `retract`, `expect_revision`, `export` | `store`: nombre, revisión y conteos |

El cuerpo admite literales positivos, negados (`"not": true`) y comparaciones
(`{"cmp": "<", "args": ["?E", 18]}` con `= != < <= > >=`). Se rechazan con un código claro las
reglas inseguras (variables sin ligar), la recursión a través de una negación y los campos
desconocidos. Detalle completo: [contrato 2](docs/CONTRATO-2.md) · [contrato 1](docs/CONTRATO.md).

### Persistencia

```json
{"contract": 2, "domain": "logic", "store": "inventario",
 "assert": {"facts": [{"pred": "depende", "args": ["api", "db"]}], "rules": []}}
```

Un `store` es un archivo `<nombre>.pl` de términos Prolog legible a mano. `assert` y `retract` se
aplican, se evalúa el programa resultante y **recién entonces** se guarda: si algo falla, el
almacén queda como estaba. Cada cambio sube la `revision`; `expect_revision` rechaza con
`conflict` si otro proceso escribió antes. Las escrituras concurrentes se serializan con un
candado; las lecturas no esperan. Los hechos de `facts` combinan con el almacén sin guardarse.
El almacén se lee como datos (`read_term`), nunca se consulta como código.

## Reglas separadas del cliente

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/img/reglas-dark.svg">
  <img alt="Banco de cartuchos con un módulo de aprendizaje cargado y otro zócalo vacío: el protocolo se comparte, pero cada dominio necesita sus propias reglas" src="docs/img/reglas-light.svg">
</picture>

| Archivo | Responsabilidad |
|---|---|
| `main.pl` | Protocolo, despacho por contrato, límites y errores |
| `learning.pl` | Reglas fijas del contrato 1: veredicto humano, respaldo, cadenas caídas, vigencia, contexto |
| `logic.pl` | Contrato 2: validación, estratificación, evaluación semi-ingenua, pruebas, restricciones |
| `store.pl` | Almacenes: nombres seguros, lectura validada, escritura atómica, candado |

Las reglas de aprendizaje no son reglas de ajedrez: un dominio futuro trae sus propias reglas y
pruebas. Un cambio de contrato es una versión nueva; el contrato 1 se mantiene para Lienzo.

## Conectar Lienzo

Cloná este repo **junto** al de Lienzo: `D:/Apps/motor-logico` y `D:/Apps/lienzo`.
Repositorio público: [arielelevy/motor-logico](https://github.com/arielelevy/motor-logico).
El adaptador busca `main.pl` en esa carpeta hermana; para otra ubicación, fijá la ruta absoluta
`LIENZO_PROLOG_ENGINE` al arrancar Lienzo. Windows consulta Ubuntu WSL; Linux usa `swipl`.

El botón **Contrastar con Prolog** compara ambos motores sobre el mismo snapshot y muestra
diferencias; no valida ni modifica creencias. Actualizar Lienzo no instala ni actualiza este repo.

## Límites

| | Contrato 1 | Contrato 2 |
|---|---|---|
| Tiempo de inferencia | 2 s | 5 s por defecto, `limits.seconds` hasta 30 |
| Inferencias | 1 millón | 10 millones por segundo de límite |
| Resultados por query | todos | 100 por defecto, `limits.max_results` hasta 10 000 |
| Profundidad de prueba | n/a | 12 por defecto, `limits.proof_depth` hasta 64; 300 nodos por prueba |
| Tamaño | lo limita el cliente | 100 000 hechos, 5 000 reglas, 1 000 restricciones, 100 queries |

El cliente Python rechaza entradas de más de 8 MiB y corta el proceso a los 40 s. Un error sale
con código `2` y `{"error", "code"}` por stderr, nunca como una respuesta vacía exitosa.

Es Datalog: sin símbolos de función ni aritmética que cree valores nuevos, por eso toda consulta
termina. `1` y `1.0` son iguales en `cmp` pero distintos al unificar. Un texto que empieza con
`?` se escribe `??`.

## Verificar y mantener

```sh
python -m unittest discover -s tests -v
```

Las pruebas no importan Lienzo: protocolo del contrato 1, razonamiento, rechazos y persistencia del
contrato 2 (incluidas escrituras concurrentes). La integración con Lienzo se prueba en su repo.

Las tres infografías son SVG estáticos en temas claro y oscuro. Sus fuentes están en
`docs/figuras/`; para regenerarlas, Node y la skill Anatomy existente (`ANATOMY_DIR` indica dónde):

```sh
node docs/build.mjs --check
```

Ver [revisión y validación](code-review-2026-10-19.md).
