# Contrato 2 · dominio logic

Una consulta JSON en stdin; una respuesta en stdout. Éxito: código 0. Error: código 2 y
`{"error": "<mensaje>", "code": "<código>"}` en stderr, sin nada en stdout.

## Términos

| JSON | Significa |
|---|---|
| `"texto"`, `3`, `2.5`, `true`, `false` | Constante |
| `"?X"` | Variable (letras, dígitos y `_`, hasta 64) |
| `"?_"` | Variable anónima: cada aparición es distinta |
| `"??x"` | La constante `"?x"` |

Un literal es `{"pred": "nombre", "args": [...]}` (pred de 1 a 128 caracteres, hasta 32 args).
`pred` + cantidad de args identifican la relación: `p/1` y `p/2` son distintas.

## Entrada

| Campo | Contenido |
|---|---|
| `contract`, `domain` | `2`, `"logic"` |
| `facts` | Literales sin variables. Valen sólo para esta consulta |
| `rules` | `{id, head, body}`. `body` lista literales, negaciones `{..., "not": true}` y comparaciones `{"cmp": op, "args": [a, b]}` |
| `constraints` | `{id, message, body}`: se viola cuando el cuerpo se cumple |
| `queries` | Literales con o sin variables |
| `explain` | `true` agrega la prueba de cada respuesta y las premisas de cada violación |
| `limits` | `{seconds, max_results, proof_depth}` (ver README) |
| `store` | Nombre de almacén `[a-z0-9][a-z0-9._-]{0,63}` |
| `assert` | `{facts, rules, constraints}` a guardar; una regla con id existente se reemplaza |
| `retract` | `{facts: [literales], rules: [ids], constraints: [ids]}` |
| `expect_revision` | Entero: si la revisión actual difiere, `conflict` |
| `export` | `true` devuelve el contenido del almacén en `store.content` |

Cualquier otro campo es un error (`invalid_request`): una errata no se ignora en silencio.

Reglas válidas: toda variable de la cabeza, de una negación o de una comparación aparece en un
literal positivo del cuerpo (`unsafe_rule`); `?_` no va en la cabeza. Un `id` se repite una sola vez
entre almacén y consulta (`duplicate_id`). La recursión a través de una negación se rechaza
(`unstratified`).

Comparaciones: `=` y `!=` comparan cualquier constante (números por valor); `< <= > >=` sólo
números: una constante no numérica en ellas se rechaza (`invalid_rule`) y una variable ligada a
texto simplemente no cumple.

Normalización de la entrada: un float entero se vuelve entero (`1.0` → `1`, `-0.0` → `0`), los
pares surrogate UTF-16 se unen y un surrogate suelto es `invalid_term`.

## Semántica

Datalog estratificado, evaluado de abajo hacia arriba con el método semi-ingenuo: cada estrato se
calcula hasta el punto fijo antes del siguiente, y la negación consulta sólo estratos cerrados.
El resultado es el modelo perfecto, único, y no depende del orden de reglas o hechos.

Orden de una consulta con almacén: leer almacén → comprobar `expect_revision` → aplicar `retract`
y luego `assert` → combinar con `facts`/`rules`/`constraints` locales → evaluar → guardar si hubo
cambios. Si cualquier paso falla, el almacén no cambia. Una consulta sin `assert`/`retract` no
toma el candado.

Las restricciones informan; no bloquean: una escritura que deja `consistent: false` se guarda
igual. Para rechazarla, consultá primero sin `assert` (o con las reglas en `facts` locales) y
escribí sólo si `consistent` es `true`, usando `expect_revision`.

Si el cliente corta por tiempo durante una escritura, el resultado es indeterminado: releé el
almacén y reconciliá con `expect_revision`.

## Salida

```json
{"contract": 2, "domain": "logic",
 "store": {"name": "s", "revision": 3, "facts": 10, "rules": 2, "constraints": 0, "changed": true},
 "answers": [{"query": 1, "pred": "ancestro", "holds": true, "count": 2, "truncated": false,
              "results": [{"bindings": {"Q": "beto"}, "proof": {...}}]}],
 "consistent": true, "violations": [],
 "stats": {"facts": 13, "derived": 3, "strata": 1, "iterations": 4}}
```

`store` es `null` sin almacén. Las respuestas no se repiten y vienen ordenadas; `truncated` indica
que hay más de `max_results`. Una prueba es `{fact, by}` con `by` igual a `given` (de la consulta),
`stored` (del almacén), `rule` (con `rule` y `premises` en el orden del cuerpo; una negación
aparece como `{"not": literal}`) o `truncated` (por profundidad o tamaño).

Cada violación: `{constraint, message, count, truncated, results}` con `bindings` y, con
`explain`, `premises`.

## Códigos de error

`invalid_json`, `invalid_request`, `unsupported_contract`, `unsupported_domain`, `invalid_fact`,
`invalid_rule`, `invalid_constraint`, `invalid_literal`, `invalid_term`, `invalid_limit`,
`unsafe_rule`, `unstratified`, `duplicate_id`, `too_large`, `store_required`, `invalid_store`,
`corrupt_store`, `store_busy`, `conflict`, `time_limit`, `inference_limit`, `resource_limit`.

## Almacenes

`<MOTOR_LOGICO_DATA>/<store>.pl`, en UTF-8: una línea `store_meta(1, Revisión).` y luego
`fact/2`, `rule/3` y `constraint/3` como términos ground. Se leen con `read_term` y se valida cada
término; uno desconocido (incluida una directiva `:-`) produce `corrupt_store`. La escritura va a
un temporal, se relee y se compara antes de renombrar. El candado es el directorio
`<store>.pl.lock` con `owner(Pid, Token)`: se espera hasta 3 s; se roba (con rename atómico) si
el proceso dueño ya no existe en este sistema o si tiene más de 120 s, y cada proceso libera sólo
su propio token. Nombres reservados de Windows (`con`, `nul`, `aux`, `com1`…) no se aceptan.
