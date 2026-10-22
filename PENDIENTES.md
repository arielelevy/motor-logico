# Pendientes

Mejoras vistas desde los proyectos que usan el motor. Cada una se trabaja acá, con sus pruebas y
su code review.

## 2026-10-22 — Las comparaciones no aparecen en la prueba (contrato 3)

- **Qué:** en `explain`, la prueba de una regla trae una premisa por cada literal, negación, agregado
  y `op`, pero ninguna por `{"cmp": …}`. Quien verifica la prueba no puede contar premisas contra el
  cuerpo ni ver con qué valores se cumplió la comparación: tiene que saltear los `cmp` y
  recalcularlos con las ligaduras.
- **Dónde:** `logic.pl`, la construcción de `premises` de una regla (las `op` sí se registran como
  `{"op", "args", "result"}`, según `docs/CONTRATO-3.md`, «Pruebas»).
- **Cómo se reproduce:** una regla `ok(?B) :- h(?B, ?T), n(?N), cmp(">", ?T, ?N)` con `explain: true`
  devuelve `premises` con dos elementos (`h` y `n`) para un cuerpo de tres.
- **Por qué importa:** Lienzo verifica cada prueba contra sus propias reglas
  (`lienzo/prolog_contraste.py`, `_prueba`) y hoy tiene que saltear los `cmp`.
- **Ojo:** agregar la premisa cambia la salida del contrato 3, así que va con contrato nuevo, o como
  campo opcional que se pide, y con aviso a Lienzo.
- **De dónde salió:** encargo J de Lienzo (checklist sostenido por el motor), 2026-10-22.

## 2026-10-22 — El costo por consulta es casi todo arranque

- **Qué:** con WSL despierto, una consulta mínima tarda unos 400 ms desde Windows: ~190 ms de
  `wsl.exe` y 210–270 ms de `swipl`, de los que 20–25 ms son el binario vacío y el resto es cargar
  `main.pl` y sus módulos desde `/mnt/d` (9P). El checklist de Lienzo pasa de 9 ms en Python a
  ~420 ms con 5 creencias y ~1,15 s con 200 creencias (2755 hechos).
- **Medido:** `qcompile(main)` no mejora (241 contra 236 ms en NTFS) porque sólo compila `main`; una
  copia en ext4 baja la carga a ~160 ms. Falta medir `qcompile` de `logic` y `learning`, y un modo
  persistente (un proceso que atiende varias consultas) que evite los dos arranques.
- **Cómo se mide:** `.temp/latencia.sh` de este repo, y en Lienzo
  `.temp/resultados/2026-10-22-J/medir_motor.py` (tiempos por tamaño de grafo).
- **De dónde salió:** encargo J de Lienzo, 2026-10-22.
