# Revisión · v0.1.0 · 2026-10-19

Alcance: main.pl, learning.pl, logic.pl, store.pl, clients/python/motor_logico.py, docs y tests.
Sin imports de Lienzo, SQL, llamadas externas ni goals proporcionados por el cliente.

## Contrato 1 (learning)

Semántica congelada: `learning.pl` sólo cambió estructuras (índice de aristas, cola O(1), visitados
en assoc). Diferencial contra la versión anterior: 120 snapshots aleatorios con ciclos, 0
diferencias en estados, cadenas y orden. Lienzo verificó los mismos hashes (main 71c66443,
learning ba70caad) con su suite real. Único cambio visible: el error por stderr suma `code` y ya
no repite el snapshot.

## Contrato 2 (logic)

Revisión independiente (subagente, con ejecuciones reales). Corregido y con prueba de regresión:

- Crítico: un emoji enviado como par surrogate (`ensure_ascii`) se guardaba y el almacén ya no
  se podía releer; un surrogate suelto rompía el cliente. Ahora se unen los pares, se rechaza el
  suelto, el cliente envía UTF-8 y `store_save` relee y compara antes del rename.
- Alto: un timeout del cliente mataba `wsl.exe` pero no `swipl`, que retenía el candado 120 s.
  El cliente ahora envuelve `swipl` con `timeout --kill-after`; el candado guarda dueño y token,
  se roba atómicamente si el dueño murió y cada proceso libera sólo el suyo.
- Medio: `< <= > >=` con constante no numérica se rechaza; `1.0`/`-0.0` se normalizan;
  temporales se borran al fallar; nombres reservados de Windows rechazados.
- Rendimiento: el literal delta no ligaba la generación (sin índice). 45 mil hechos: 5,8 s → 0,84 s.

Documentado como decisión: las restricciones informan y no bloquean escrituras; un timeout del
cliente deja la escritura indeterminada (reconciliar con `expect_revision`).

v0.1.1 (main.pl cambia; learning.pl no):

- Texto después del JSON es `invalid_json`; espacios y saltos de línea finales se aceptan.
- Límite total de 35 s por proceso que cubre lectura, almacén, evaluación y serialización. La
  respuesta se serializa completa antes de escribirla: un error nunca deja stdout a medias.
- `store_save` hace fsync del temporal antes del rename y de la carpeta después (`sync <ruta>` de
  coreutils; si no existe, se omite). Error nuevo: `store_io`.
- Diferencial contrato 1 con el main nuevo: 60/60 iguales.

## Evidencia

- `python -m unittest discover -s tests`: 32 OK (SWI-Prolog 9.0.4 en Ubuntu WSL).
- Oráculo Datalog ingenuo en Python: 260 programas aleatorios (recursión lineal, no lineal y
  mutua, negación, comparaciones), 0 diferencias.
- Concurrencia: 6 escritores sin `expect_revision` → revisiones 1..6 sin pérdidas; 16 con
  `expect_revision` → 1 éxito y 15 `conflict`.

Límites: no probado con SWI nativo de Windows; sin baseline aprobado ni PASS de aceptación global.
