# Contrato 3 · dominio logic

El contrato 3 es el contrato 2 más cuatro cosas: agregados, aritmética no recursiva, procedencia de
hechos y huella del programa. Opcionalmente explica por qué una query no se cumple. Todo lo que
[el contrato 2](CONTRATO-2.md) dice de términos, reglas, comparaciones, almacenes, límites y errores
vale igual acá, salvo lo que este documento cambia.

**Convive con el 2, no lo reemplaza.** El repo es público desde el 2026-10-19 y no hay forma de saber
si alguien ya usa el 2; mantenerlo cuesta un filtro de campos, porque los dos comparten evaluador.
Una consulta de contrato 2 da hoy exactamente la misma salida que antes (diferencial en
`tests/diferencial.py`).

Una conclusión del motor es una función de los hechos y las reglas recibidos: en el vocabulario de
Chesstudia, `COMPUTED`. El motor nunca evalúa una jugada; una evaluación de Stockfish puede entrar
como hecho con `"source": "motor"`.

## Entrada

Los campos del contrato 2, con `contract: 3`, más:

| Campo | Contenido |
|---|---|
| `facts[].source` | Opcional. Nombre `[a-z][a-z0-9_]{0,31}` que dice de dónde salió el hecho: `motor`, `reglas`, `fragmento`, `modelo`, `prior`… El vocabulario es abierto |
| `assert.facts[].source` | Igual, y se guarda en el almacén |
| `explain_failures` | `true` agrega `failures` a cada query que no se cumple |

`retract.facts` no lleva `source`: quitar un hecho lo quita con todas sus fuentes (`invalid_fact`).

### Un hecho con varias fuentes

Un hecho es su predicado y sus argumentos; las fuentes son un conjunto pegado a él. Dar el mismo hecho
dos veces con fuentes distintas, o tenerlo en el almacén con una y en `facts` con otra, deja **un**
hecho con las dos fuentes. Se deduce una sola vez y las dos aparecen en su prueba.

### Agregados

Un elemento del cuerpo:

```json
{"agg": "count", "pred": "fallo", "args": ["?C", "?_"], "as": "?N"}
{"agg": "sum",   "pred": "tiempo", "args": ["?C", "?S", "?T"], "value": "?T", "as": "?Total"}
```

| Campo | Contenido |
|---|---|
| `agg` | `count`, `sum`, `min` o `max` |
| `pred`, `args` | El literal que se agrega, como cualquier literal |
| `value` | Variable del literal que se suma o compara. Obligatoria en `sum`, `min` y `max`; prohibida en `count` |
| `as` | Variable nueva que recibe el resultado |

Las variables del literal se reparten en tres grupos:

| Grupo | Cuáles | Qué hacen |
|---|---|---|
| Externas | Aparecen también en un literal positivo de la regla | Fijan el grupo desde afuera; se ligan antes de agregar |
| De grupo | No aparecen en ningún literal positivo, pero sí en otra parte de la regla (cabeza, negación, comparación, `op`) | El agregado las liga: hay un resultado por cada combinación presente en los hechos |
| Locales | Sólo aparecen dentro del agregado (incluida `?_`) | Se agregan |

`count` cuenta tuplas distintas del literal. `sum`, `min` y `max` operan sobre los valores
numéricos de `value` en esas tuplas; una tupla con `value` no numérico no aporta, como una
comparación con texto no se cumple. Un `sum` que da un float entero se devuelve entero, como en la
entrada.

Sin variables de grupo hay un solo resultado: `count` y `sum` dan `0` si no hay tuplas; `min` y
`max` no dan nada. Con variables de grupo, sólo existen los grupos que tienen tuplas: para un `0`
por concepto, ligá el concepto con un literal positivo (variable externa).

### Aritmética

```json
{"op": "-", "args": ["?Hoy", "?Dia"], "as": "?Dias"}
```

`op` es `+`, `-`, `*` o `/`. Los dos argumentos son números o variables ligadas; `as` es una
variable nueva. Con un argumento no numérico, dividiendo por cero o con un desborde, el elemento no
se cumple. Un resultado float entero se devuelve entero. Un entero calculado (por `op` o por `sum`)
con valor absoluto mayor que 2^53 tampoco se cumple: no viaja exacto por JSON y, sin esa cota, una
cadena corta de multiplicaciones produce números de megabytes.

### Seguridad

Además de las reglas del contrato 2 (`unsafe_rule`):

- Una variable que no liga un literal positivo la liga, a lo sumo, un agregado o una `op`.
- `as` es una variable nueva: no aparece en literales positivos ni en su propio literal.
- Los argumentos de una `op` están ligados por literales positivos, agregados u otras `op`, sin
  ciclos entre `op`.
- La cabeza, las negaciones y las comparaciones pueden usar variables que ligan agregados y `op`.
- `?_` no va en los argumentos de una `op`. En `value` o en `as` es `invalid_rule`.

### Estratificación y terminación

Un agregado sobre `p` exige que `p` esté en un estrato más bajo que la cabeza, igual que una
negación. Una regla con un agregado o una `op` **no es recursiva**: su cabeza queda en un estrato
más alto que todo su cuerpo. Si no se puede, `unstratified`.

Por eso toda consulta sigue terminando. Dentro de un estrato, las reglas recursivas no tienen
agregados ni `op`, así que no crean valores: sólo combinan las constantes que ya hay, que son
finitas. Las reglas con agregados u `op` leen estratos ya cerrados y finitos, y se aplican una
vez: crean finitos valores nuevos. Por inducción sobre los estratos, cada uno es finito.
Lo prueban `test_op_recursiva_se_rechaza` y `test_agregado_recursivo_se_rechaza`.

## Salida

La del contrato 2, con `contract: 3` y además:

| Campo | Contenido |
|---|---|
| `engine` | `{"name": "motor-logico", "version": "0.2.0"}` |
| `program_hash` | `"sha256:<hex>"` del programa evaluado: hechos con sus fuentes, reglas y restricciones, del almacén y de la consulta juntos |
| `answers[].results[].sources` | Fuentes de todos los hechos de los que depende ese resultado, ordenadas y sin repetir. Se recorre la derivación completa, no la prueba recortada. Una negación no aporta fuentes: lo que falta no tiene procedencia |
| `violations[].results[].sources` | Igual, para cada violación |
| `answers[].failures` | Con `explain_failures`, en cada query que no se cumple |

`sources` es la procedencia de **una** derivación: la que el motor registró, que es la primera que
encontró y la misma que muestra la prueba. Si una conclusión también se deduce por otro camino con
otras fuentes, ese camino no aparece. Para preguntar "¿vale sin lo que dijo el modelo?", consultá de
nuevo sin esos hechos.

En el contrato 3 el motor evalúa en orden canónico: hechos fusionados y ordenados, reglas y
restricciones por `id`. Por eso dos consultas con el mismo `program_hash` y las mismas queries dan
la misma salida, incluidas pruebas y `sources`; sólo cambia `by` (`stored` o `given`) según de
dónde vino cada hecho. Las violaciones salen ordenadas por `id` de restricción.

La huella no depende del orden de hechos, reglas ni restricciones, ni de si un hecho vino del
almacén o de la consulta. Sí cambia con un nombre de variable, un `id` o una fuente. Compará
siempre `program_hash` junto con `engine.version`: una versión nueva puede cambiar la forma interna.

### Pruebas

Una hoja `given` o `stored` lleva `sources` (lista, quizá vacía). Una premisa de agregado es:

```json
{"agg": "count", "of": {"pred": "fallo", "args": ["horquilla", "?_"]}, "result": 3,
 "items": [{"fact": {...}, "by": "given", "sources": ["reglas"]}, ...], "truncated": false}
```

`items` son las tuplas que aportaron, ordenadas, con su prueba, hasta 50 (`truncated` si hay más).
Una premisa de `op` es `{"op": "-", "args": [20, 5], "result": 15}`.

### Explicación de fallos

Para cada regla cuya cabeza unifica con la query, `failures` dice el primer elemento del cuerpo que
no se cumple, en el orden en que el motor lo evalúa:

```json
"failures": [{"rule": "frente", "position": 2, "item": {"pred": "bloqueado", "args": ["?C"], "not": true}}]
```

`position` es la posición en el cuerpo, desde 1. Una query sin reglas que concluyan su predicado
tiene `failures: []`: sólo podría salir de hechos, y no hay ninguno que coincida.

## Almacenes

El contrato 3 escribe el formato más chico que alcanza. Sin fuentes, agregados ni `op`, el almacén
queda en formato 1, el del contrato 2, y el 2 lo sigue leyendo. Si aparece alguno de los tres, queda
con `store_meta(2, Revisión)` y hechos `fact(Pred, Args, Fuentes)`. El 3 lee los dos formatos. El 2
lee sólo el 1: ante uno de formato 2 responde `corrupt_store` y avisa que es del contrato 3 (no hay
código nuevo, porque el contrato 2 no cambia). Si el contenido deja de necesitar el formato 2, la
siguiente escritura vuelve al 1.

`export` devuelve un hecho por fuente, así el contenido exportado se puede volver a asertar tal cual.
`store.facts` cuenta hechos, no fuentes: un hecho con dos fuentes es 1 en `facts` y 2 en `export`.

## Errores

Los del contrato 2. No hay códigos nuevos: un agregado o una `op` mal formados son `invalid_rule`,
salvo el literal de un agregado sin `pred` o con `args` inválidos, que es `invalid_literal` como en
cualquier literal; un `source` inválido o en `retract`, `invalid_fact`.
