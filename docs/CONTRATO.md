# Contrato 1 · reglas 1

Una consulta JSON en stdin; una respuesta en stdout, sin texto extra. Error: código 2 y JSON
`{error, code}` en stderr (el mensaje no repite el snapshot). Éxito: código 0. El cliente valida versiones y que responda todas las creencias.

| Campo de entrada | Contenido |
|---|---|
| `contract`, `domain` | `1`, `"learning"` |
| `now` | Epoch UTC elegido por el cliente para todo el snapshot |
| `context` | Objeto de dimensiones con valores string |
| `nodes` | Lista de `{id, kind, state}` con IDs únicos |
| `edges` | Relaciones activas `{from, to, relation}`; ambos extremos existen |
| `beliefs` | `{id, state, verdict, approved_by, evidence, until, required}` |

`until` es epoch UTC o null. `required` conserva el contexto registrado, incluso si está inválido:
una creencia inválida debe poder explicarse. Dimensiones admitidas: agente, modelo, fase,
tipo_trabajo, tecnologia, area, version_agente, version_modelo.

Relaciones: `apoya` conecta creencia y evidencia específica del veredicto; `motivada_por` conecta
decisiones con sus respaldos. Sólo se continúa transitivamente por decisiones. Los respaldos
caídos son hallazgo/rechazado, medicion/rechazada o decision/revertida.

La salida incluye `contract:1`, `domain:"learning"`, `rules:1`, `authority:"observation_only"`
y `conclusions`: `{id, status, rule, chains}` por cada creencia. `rule` identifica el motivo
determinante y coincide con `status`. Cada cadena empieza con la creencia y termina en un respaldo
caído; devuelve un camino mínimo por respaldo, con visita única y desempate por ID.

Prioridad de estados: refutada → sin_veredicto → respaldo_retirado → respaldo_caido → vencida →
contexto_invalido → contexto_insuficiente → fuera_de_contexto → aplicable. Que una conclusión diga
`aplicable` no autoriza una acción ni convierte un hecho en verdadero.

El motor no lee bases de datos ni verifica firmas humanas: razona sobre la representación que
el cliente envía. El cliente es responsable de autenticidad, snapshot coherente y autorización.
Una tool puede encapsular este protocolo; no acepta consultas arbitrarias ni texto Prolog.
