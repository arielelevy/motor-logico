# Revisión · v0.2.0 · 2026-10-20

Alcance: contrato 3 (`logic.pl`, `store.pl`, `main.pl`), `docs/CONTRATO-3.md`, pruebas y
herramientas nuevas (`tests/test_contract3.py`, `tests/oraculo.py`, `tests/diferencial.py`),
`examples/chesstudia.json`. Encargo de la sesión de Chesstudia, pedido por Ariel. `learning.pl` no
cambió (mismo blob `f08436bd`).

## Qué entró

- Contrato 3, que convive con el 2 y comparte evaluador. Agrega:
  - agregados estratificados (`count`, `sum`, `min`, `max`) con variables externas, de grupo y locales;
  - aritmética `op` no recursiva;
  - `source` por hecho, persistido en el almacén;
  - `sources` por resultado y por hoja de la prueba;
  - `engine` y `program_hash`;
  - `explain_failures`.
- Almacén formato 2 (`fact/3`), escrito sólo cuando hace falta. El contrato 2 sigue leyendo y
  escribiendo el formato 1.

## Revisión independiente

Un subagente revisó el diff con ejecuciones reales y lo comparó contra HEAD. No encontró nada
crítico. Corregido, con prueba de regresión:

- **Alto:** el contrato 2 arrancaba más lento: fusionaba fuentes dentro del límite de tiempo, y con
  100 000 hechos y `seconds: 1` fallaba donde antes respondía. Ahora la fusión corre fuera del límite
  y sólo en el 3. En 8 repeticiones, la versión nueva respondió 8 y la anterior también 8.
- **Alto:** `sources` se recalculaba por resultado: 20 000 ítems contados agotaban las inferencias.
  Ahora se memoriza por hecho (`smemo`, indexado por `term_hash`): 1,08 s.
- **Medio:** con el mismo `program_hash`, `sources` cambiaba con el orden de las reglas. El contrato
  3 evalúa ahora en orden canónico: mismo hash y mismas queries dan la misma salida
  (`test_misma_huella_misma_salida`).
- **Medio:** cualquier escritura del 3 pasaba el almacén al formato 2 y dejaba fuera al 2. Ahora
  escribe el formato mínimo (`test_formato_minimo_y_compatibilidad_con_el_contrato_2`).
- **Medio:** una cadena corta de `op *` producía enteros de megabytes. Un entero calculado con
  |n| > 2^53 no se cumple (`test_enteros_fuera_de_2_53_no_se_cumplen`).
- **Bajo:** los términos de agregados y `op` leídos del almacén se validan como en la entrada.
  En el contrato se documentan dos detalles: `invalid_literal` para el literal de un agregado, y que
  `store.facts` cuenta hechos y no fuentes.

Documentado como decisión:

- `sources` es la procedencia de la derivación registrada, no de todas.
- El mensaje de `unsupported_contract` ahora lista "1, 2, 3". El código no cambia; es lo único
  visible para Lienzo.

## Evidencia

- `python -m unittest discover -s tests`: 54 OK con las correcciones (SWI-Prolog 9.0.4, Ubuntu WSL).
- Diferencial contra HEAD, antes de las correcciones de la revisión (`tests/diferencial.py`, semilla
  20261020): 485 consultas, de ellas 81 del contrato 1 y 404 del contrato 2 (incluidas 259 de
  almacén). Hubo 3 diferencias, todas código 124: `timeout` cortó un proceso que ya había respondido
  mientras corrían en paralelo el oráculo, la suite y el revisor (una del lado viejo y dos del
  nuevo). Repetidos esos 3 casos tres veces: 0 diferencias. El revisor comparó además 17 entradas
  del contrato 2 byte a byte, todas iguales.
- Oráculo Datalog ingenuo extendido (`tests/oraculo.py`), antes de las correcciones: 300 programas
  con agregados, `op`, negación y recursión sobre valores calculados, 0 diferencias.
- Corrida final después de las correcciones, una por vez y sin nada en paralelo (2026-10-20, WSL
  con 12 CPU y 12 GB; a Windows le quedaban entre 0,3 y 2,3 GB libres):
  - **Diferencial** contra HEAD anterior (semilla 20261020): 485 consultas (81 del contrato 1, 404
    del 2) en 325 s, con carga 2,15 → 0,92. Hubo 1 diferencia: código 124 del lado nuevo en un caso
    que falla con `unsafe_rule`. Repetido 5 veces: 0 diferencias, unos 670 ms ida y vuelta.
  - **Oráculo** (semilla 20261021): 300 programas en 116 s, con carga 0,95 → 0,42 y 0,31 GB libres
    al empezar. 0 diferencias y 1 reintento por el entorno. Dos corridas anteriores se cortaron con
    124, en el programa 167 y después en el 41. El 167, solo, respondió 20 de 20 veces en 0,2 s.
  - **Latencia** de `examples/chesstudia.json` (con `explain` y `explain_failures`), 30 corridas
    con carga 0,78 → 0,81: desde `/mnt/d`, mediana 240 ms, p90 267, máximo 299; con los `.pl` en
    ext4, mediana 170 ms, p90 187, máximo 195.
- **Cuelgues de WSL.** Los 124 son del entorno, no del motor:
  - El proceso no llega a correr `main`: el límite interno de 35 s nunca dispara y el `timeout` del
    cliente corta a los 40 s.
  - El punto cambia entre corridas y el mismo programa, solo, responde enseguida.
  - Aparecen con poca memoria libre en Windows: uno cada ~300 a 500 procesos.
  - Un cliente que reintente una vez ante 124 los absorbe. `tests/oraculo.py` lo hace y lo cuenta.

Límites: no probado con SWI nativo de Windows; sin baseline aprobado ni PASS de aceptación global.
