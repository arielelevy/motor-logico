# Motor lógico

**Hechos de entrada. Reglas explícitas. Conclusiones con respaldo.**

Le das al motor lo que sabés (hechos) y cómo se razona sobre eso (reglas). Te devuelve todo lo que
se deduce y, para cada conclusión, la cadena de pasos que la prueba. Es un motor SWI-Prolog que
cualquier repo consulta por un proceso: entra un JSON, sale un JSON. Nunca ejecuta código ni goals
del cliente.

`v0.2.0` · tres contratos:

| Contrato | Dominio | Para qué | Persistencia |
|---|---|---|---|
| `1` · reglas `1` | `learning` | Segunda opinión sobre creencias y aprendizaje de Lienzo | No |
| `2` | `logic` | Razonamiento general: Datalog con recursión, negación, comparaciones, restricciones y pruebas | Opcional, por `store` |
| `3` | `logic` | El 2 más agregados (`count`, `sum`, `min`, `max`), aritmética, fuentes de cada hecho y huella del programa | Opcional, por `store` |

## La idea: una segunda opinión, no una dependencia

<table>
<tr>
<td width="50%" valign="top">

Tu aplicación guarda sus datos y funciona sola. Cuando necesita deducir algo, como qué servicios
caen si se cae la base, o si una creencia tiene respaldo, arma una consulta y se la manda al motor.

El motor vive en su propio repo. Recibe una copia de los hechos, razona y devuelve conclusiones
con su prueba. No guarda nada de la aplicación ni le cambia sus datos.

Si falta Prolog o la consulta falla, la aplicación recibe un error explícito (código `2`) y sigue
funcionando, sólo que sin ese razonamiento.

</td>
<td width="50%" valign="middle">
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/img/prolog-dark.svg">
  <img width="100%" alt="Fichero autónomo con lámpara verde junto a una estación Prolog separada: una bandeja lleva la consulta y otra devuelve las conclusiones; el fichero sigue funcionando sin la estación" src="docs/img/prolog-light.svg">
</picture>
</td>
</tr>
</table>

**Hoy:** Lienzo usa el contrato 1 desde un botón de consulta manual. Los contratos 2 y 3 están
disponibles para cualquier repo. **Pendiente:** el adaptador de Chesstudia, que va en su repo y usará
el contrato 3 con reglas propias (no hereda las de aprendizaje).

## Aprender con un ejemplo

[examples/logic.json](examples/logic.json) describe cuatro servicios y pregunta cuáles quedan
afectados cuando se cae la base de datos. Lo recorremos en cuatro pasos.

### 1. Hechos: lo que sabés

Un hecho es un predicado con argumentos. `depende(web, api)` se lee "web depende de api".

```json
{"pred": "depende", "args": ["web", "api"]}
{"pred": "depende", "args": ["api", "auth"]}
{"pred": "depende", "args": ["auth", "db"]}
{"pred": "caido",   "args": ["db"]}
{"pred": "servicio", "args": ["web"]}
{"pred": "servicio", "args": ["reportes"]}
```

```text
web ──► api ──► auth ──► db (caída)          reportes (no depende de nadie)
```

### 2. Reglas: cómo se razona

Una regla dice "si se cumple todo el cuerpo, vale la cabeza". Las palabras con `?` son variables:
el motor prueba todos los valores que encajan.

| Regla | En palabras |
|---|---|
| `directa` | Si `?A` depende de `?B`, entonces `?A` requiere `?B`. |
| `transitiva` | Si `?A` depende de `?B` y `?B` requiere `?C`, entonces `?A` requiere `?C`. |
| `afectado` | Si `?S` requiere algo que está caído, `?S` está afectado. |
| `sano` | Si `?S` es un servicio y **no** está afectado, está sano. |

```json
{"id": "transitiva",
 "head": {"pred": "requiere", "args": ["?A", "?C"]},
 "body": [{"pred": "depende", "args": ["?A", "?B"]},
          {"pred": "requiere", "args": ["?B", "?C"]}]}
```

`transitiva` se usa a sí misma: así el motor sigue la cadena entera, sin importar cuán larga sea.
`sano` usa una negación (`"not": true`); el motor calcula primero todos los afectados y recién
después decide quién está sano.

### 3. Preguntas y restricciones

Las `queries` son lo que querés saber: `afectado(?S)` y `sano(?S)`. Una restricción describe algo
que **no** debería pasar; acá, que un servicio publicado esté afectado.

### 4. La respuesta

```sh
swipl -q -f none -s main.pl -g main -t halt < examples/logic.json
```

| Pregunta | Resultado |
|---|---|
| `afectado(?S)` | `api`, `auth`, `web` |
| `sano(?S)` | `reportes` |
| restricción `servicio-afectado` | violada por `web`: `consistent` es `false` |

Con `"explain": true`, cada resultado trae su prueba. La de `web` se lee de abajo hacia arriba:

```text
afectado(web)                       regla afectado
├─ requiere(web, db)                regla transitiva
│  ├─ depende(web, api)             hecho
│  └─ requiere(api, db)             regla transitiva
│     ├─ depende(api, auth)         hecho
│     └─ requiere(auth, db)         regla directa
│        └─ depende(auth, db)       hecho
└─ caido(db)                        hecho
```

Cada conclusión termina en hechos que vos diste. Si una respuesta te sorprende, la prueba muestra
qué hecho o qué regla la produjo.

### Vocabulario

| Término | Qué es |
|---|---|
| Hecho | Algo que se da por cierto: `caido(db)` |
| Regla | Cabeza que vale cuando se cumple todo el cuerpo |
| Variable | `?X`; toma cualquier valor que encaje. `?_` es anónima |
| Negación | Literal con `"not": true`: vale si el hecho **no** se puede deducir |
| Comparación | `{"cmp": "<", "args": ["?E", 18]}` con `= != < <= > >=` |
| Restricción | Cuerpo que no debería cumplirse; si se cumple, aparece en `violations` |
| Prueba | Árbol de reglas y hechos que respalda una conclusión |
| Almacén | Hechos y reglas guardados con nombre para consultas siguientes |

## ¿Por qué Prolog y no IA acá?

El motor no usa un modelo de lenguaje. Lo que una aplicación le pide es justo lo que un modelo no
garantiza:

| Lo que necesita | Cómo lo da el motor | Evidencia |
|---|---|---|
| La misma respuesta para la misma entrada | Evaluación de punto fijo; el resultado no depende del orden de hechos ni de reglas | `examples/logic.json` cinco veces: la misma salida byte a byte (mismo SHA-256) |
| Saber por qué | Cada conclusión trae el árbol de reglas y hechos que la prueba | La prueba de `afectado(web)` de arriba; `test_prueba_explica_reglas_hechos_y_negaciones` |
| Nada que no salga de los datos | Sólo deduce de los hechos y reglas recibidos; no completa con conocimiento propio | Oráculo Datalog ingenuo en Python: 260 programas aleatorios, 0 diferencias |
| Que siempre termine | Datalog sin símbolos de función, más límites de tiempo e inferencias | `test_recursion_transitiva_con_ciclo_termina`; `call_with_time_limit` en `logic.pl` |
| Que la entrada no se ejecute | Las reglas son datos interpretados; el almacén se lee con `read_term` | `test_textos_que_parecen_codigo_son_datos`, `test_almacen_corrupto_o_con_codigo_se_rechaza` |
| Costo fijo y local | Un proceso, sin red, sin tokens | ~130 ms por consulta en WSL ya arrancado; el primer arranque de WSL tarda unos segundos |

El motor tampoco reemplaza a un modelo: sólo sabe lo que le dan y no maneja ambigüedad ni texto
libre. Si una aplicación usa un modelo, el motor puede ser el paso que deduce y prueba a partir de
hechos explícitos.

## Contar, calcular y saber de dónde salió

El contrato 3 agrega lo que hace falta para razonar sobre un alumno. Está pensado para Chesstudia y
sirve a cualquier repo. [examples/chesstudia.json](examples/chesstudia.json) arma un caso con los
14 motivos tácticos, más sobrecarga y desviación, y un grafo de prerrequisitos inventado de ejemplo.

**Contar.** Un agregado en el cuerpo cuenta, suma o busca el mínimo o el máximo:

```json
{"id": "veces", "head": {"pred": "veces", "args": ["?C", "?N"]},
 "body": [{"pred": "concepto", "args": ["?C"]},
          {"agg": "count", "pred": "fallo", "args": ["?C", "?_"], "as": "?N"}]}
```

Se lee "`?N` es la cantidad de fallos en `?C`". Como `?C` viene de `concepto`, un concepto sin fallos da
`0`. Con otra regla, `veces(?C, ?N)` y `?N >= 3`, sale "ya fallaste tres veces esto".

**Calcular.** `{"op": "-", "args": ["?Hoy", "?Dia"], "as": "?Dias"}` da los días desde un acierto.

**Saber de dónde salió.** Cada hecho puede traer `"source"`: `motor`, `reglas`, `fragmento`, `modelo`,
`prior`. Cada respuesta devuelve `sources`, las fuentes de todo lo que la sostiene, y cada hoja de la
prueba dice la suya.

**Repetir una decisión.** La salida trae `engine.version` y `program_hash`, la huella del programa
evaluado. Una decisión guardada con esos dos datos se puede reconocer después, sin el motor.

En el ejemplo, `bloqueado(desviacion)` se prueba con la cadena entera: desviación se apoya en
sobrecarga, que se apoya en ataque doble, que todavía no está sostenido. Con `explain_failures`,
`frente(horquilla)` responde por qué no: la regla `frente` falla en `no bloqueado(horquilla)`.

Las reglas con agregados u `op` no pueden ser recursivas, y por eso toda consulta sigue terminando.
Detalle: [contrato 3](docs/CONTRATO-3.md).

> **Para Chesstudia:** una conclusión del motor lógico es `COMPUTED`, una función de los hechos y
> las reglas que recibió. El motor nunca evalúa una jugada: las evaluaciones sólo salen de Stockfish
> y pueden entrar como hechos con `"source": "motor"`.

## Un contrato pequeño

<table>
<tr>
<td width="50%" valign="top">

La aplicación y el motor se hablan con un solo mensaje de ida y uno de vuelta: un JSON por entrada
estándar y otro por salida estándar.

Las reglas viajan como **datos**. El motor las interpreta con su propio evaluador; no las convierte
en código. Un texto como `"halt, shell('rm')"` es sólo un valor más.

Si algo no cuadra (un campo desconocido, una regla insegura, un límite excedido) la respuesta es
un error con código, nunca una lista vacía que parezca un éxito.

</td>
<td width="50%" valign="middle">
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/img/contrato-dark.svg">
  <img width="100%" alt="Lectora de fichas con bandeja de entrada, peines fijos de reglas y bandeja de respuesta: los datos atraviesan la máquina sin convertirse en código ejecutable" src="docs/img/contrato-light.svg">
</picture>
</td>
</tr>
</table>

| Contratos 2 y 3: entra | Vuelve |
|---|---|
| `facts`: hechos `{pred, args}` sólo para esta consulta | `answers`: por query, `holds`, `count` y `bindings` |
| `rules`: `{id, head, body}` | `proof` por respuesta con `explain: true` |
| `constraints`: cuerpos que no deberían cumplirse | `consistent` y `violations` con sus ligaduras |
| `queries`: patrones a responder | `stats`: hechos, derivados, estratos, iteraciones |
| `store`, `assert`, `retract`, `expect_revision`, `export` | `store`: nombre, revisión y conteos |

Se rechazan con un código claro las reglas inseguras (variables sin ligar), la recursión a través
de una negación y los campos desconocidos.
Detalle completo: [contrato 3](docs/CONTRATO-3.md) · [contrato 2](docs/CONTRATO-2.md) ·
[contrato 1](docs/CONTRATO.md).

### Persistencia

Sin `store`, cada consulta empieza de cero. Con `store`, el motor recuerda:

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

## Un motor, reglas por dominio

<table>
<tr>
<td width="50%" valign="top">

El motor separa lo que se comparte de lo que es propio de cada dominio.

Se comparte el protocolo: leer el JSON, despachar por contrato, aplicar límites y devolver errores.

Cada dominio trae sus reglas. Las de aprendizaje de Lienzo están fijas en `learning.pl`. Un dominio
futuro, como ajedrez para Chesstudia, traerá las suyas con sus pruebas; no hereda las de aprendizaje.

Los contratos 2 y 3 no necesitan un módulo propio: sus reglas llegan en cada consulta o desde un almacén.

</td>
<td width="50%" valign="middle">
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/img/reglas-dark.svg">
  <img width="100%" alt="Banco de cartuchos con un módulo de aprendizaje cargado y otro zócalo vacío: el protocolo se comparte, pero cada dominio necesita sus propias reglas" src="docs/img/reglas-light.svg">
</picture>
</td>
</tr>
</table>

| Archivo | Responsabilidad |
|---|---|
| `main.pl` | Protocolo, despacho por contrato, límites y errores |
| `learning.pl` | Reglas fijas del contrato 1: veredicto humano, respaldo, cadenas caídas, vigencia, contexto |
| `logic.pl` | Contratos 2 y 3: validación, estratificación, evaluación semi-ingenua, agregados, pruebas, fuentes, restricciones |
| `store.pl` | Almacenes: nombres seguros, lectura validada, escritura atómica, candado |

Un cambio de contrato es una versión nueva; el contrato 1 se mantiene para Lienzo.

## Usarlo desde otro repo

Requiere SWI-Prolog ya instalado (probado con 9.0.4). En Windows se usa el de Ubuntu WSL:

```powershell
Get-Content -Raw examples/logic.json | wsl -d Ubuntu -- swipl -q -f none -s /mnt/d/Apps/motor-logico/main.pl -g main -t halt
```

El motor no se instala ni se importa: se ejecuta. Tres formas, de la más simple a la más integrada:

1. **Copiar el cliente.** `clients/python/motor_logico.py` es un archivo; copialo y apuntalo con
   `MOTOR_LOGICO_ENGINE=/ruta/a/main.pl`. Arma el comando (WSL en Windows), traduce rutas y
   convierte cualquier fallo en `MotorError(code, message)`.
2. **Proceso directo** desde cualquier lenguaje: escribí el JSON en stdin de
   `swipl -q -f none -s main.pl -g main -t halt`, leé stdout; código distinto de 0 es error.
3. **Un adaptador propio**, como el de Lienzo, que valida versiones y limita entrada y concurrencia.

Desde Python, sin dependencias, con [clients/python/motor_logico.py](clients/python/motor_logico.py):

```python
from motor_logico import consultar, MotorError

r = consultar({
    "contract": 3, "domain": "logic",
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

Cloná el repo una sola vez (por ejemplo en `D:/Apps/motor-logico`) y apuntá cada proyecto ahí.
Cada consulta es un proceso aislado; no hay servidor, HTTP ni MCP que mantener.

| Variable | Uso |
|---|---|
| `MOTOR_LOGICO_ENGINE` | Ruta a `main.pl` para el cliente Python |
| `MOTOR_LOGICO_DATA` | Carpeta de almacenes (por defecto `data/` junto a `main.pl`, ignorada por Git) |
| `MOTOR_LOGICO_WSL_DISTRO` | Distro de WSL en Windows (por defecto `Ubuntu`) |

## Conectar Lienzo

Cloná este repo **junto** al de Lienzo: `D:/Apps/motor-logico` y `D:/Apps/lienzo`.
Repositorio público: [arielelevy/motor-logico](https://github.com/arielelevy/motor-logico).
El adaptador busca `main.pl` en esa carpeta hermana; para otra ubicación, fijá la ruta absoluta
`LIENZO_PROLOG_ENGINE` al arrancar Lienzo. Windows consulta Ubuntu WSL; Linux usa `swipl`.

El botón **Contrastar con Prolog** compara ambos motores sobre el mismo snapshot y muestra
diferencias; no valida ni modifica creencias. Actualizar Lienzo no instala ni actualiza este repo.

## Límites

| | Contrato 1 | Contratos 2 y 3 |
|---|---|---|
| Tiempo de inferencia | 2 s | 5 s por defecto, `limits.seconds` hasta 30 |
| Inferencias | 1 millón | 10 millones por segundo de límite |
| Resultados por query | todos | 100 por defecto, `limits.max_results` hasta 10 000 |
| Profundidad de prueba | n/a | 12 por defecto, `limits.proof_depth` hasta 64; 300 nodos por prueba |
| Tamaño | lo limita el cliente | 100 000 hechos, 5 000 reglas, 1 000 restricciones, 100 queries |

El cliente Python rechaza entradas de más de 8 MiB y corta el proceso a los 40 s. Un error sale
con código `2` y `{"error", "code"}` por stderr, nunca como una respuesta vacía exitosa.

Es Datalog: sin símbolos de función, y la aritmética del contrato 3 nunca entra en una recursión,
por eso toda consulta termina. `1` y `1.0` son iguales en `cmp` pero distintos al unificar. Un texto que empieza con
`?` se escribe `??`.

## Verificar y mantener

```sh
python -m unittest discover -s tests -v
```

Las pruebas no importan Lienzo: protocolo del contrato 1, razonamiento, rechazos y persistencia del
contrato 2 (incluidas escrituras concurrentes) y agregados, `op`, fuentes, huella y fallos del
contrato 3. La integración con Lienzo se prueba en su repo.

Dos herramientas más, fuera de `unittest` porque lanzan cientos de procesos:

```sh
python tests/oraculo.py 1 300                       # Datalog ingenuo en Python contra el motor
python tests/diferencial.py <versión-anterior> 1 300 # contratos 1 y 2, byte a byte
```

Las tres infografías son SVG estáticos en temas claro y oscuro, con rótulos dentro de la figura.
Sus fuentes están en `docs/figuras/`; para regenerarlas, Node y la skill Anatomy existente
(`ANATOMY_DIR` indica dónde):

```sh
node docs/build.mjs --check
```

Ver revisión y validación: [2026-10-20](code-review-2026-10-20.md) (contrato 3) ·
[2026-10-19](code-review-2026-10-19.md).
