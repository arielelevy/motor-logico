# Contrato 4: servicio persistente de lectura

Entrada: swipl -q -f none -s servicio.pl -g servicio_main -t halt.
Una solicitud y una respuesta JSON por línea UTF-8. El cliente conserva stdin abierto hasta recibir la respuesta; EOF cancela el worker activo y termina el servicio. No enviar EOF para pedir la última respuesta.

Solicitud:
```json
{"contract":4,"request_id":"id-unico","op":"query","archivos":[],"payload":{"contract":3,"domain":"logic","facts":[],"rules":[],"queries":[]}}
```

Respuesta correcta: request_id, ok:true, resultado (contrato 3), pid y cargas.
Error: request_id, ok:false, code y error. Una consulta rechazada no agrega hechos a la siguiente.
Los contratos 1–3 mantienen main.pl y sus entrypoints; servicio.pl no reemplaza main.pl.

archivos: hasta 100 objetos {path,hash}; hash SHA-256 hexadecimal de los bytes del archivo. Se cachea cada path/hash, y se valida semánticamente antes de usar reglas. La proyección contiene sólo términos ground proyecto/1, creencia/3, regla_logica/2, datos_creencia/2 o sin_formalizar/1. El segundo argumento de regla_logica contiene JSON AST. Cada regla cargada agrega la premisa creencia_habilitada(id): la proyección no concede autoridad.

Nunca consult/1 ni ejecución de goals recibidos. Rechaza directivas, almacenes y assert/retract. El payload se evalúa con logic_request(3); los hechos se aíslan por solicitud. Límite de línea 4 MiB, plazo interno 30 segundos; el consumidor también debe limitar escritura/lectura y recoger el proceso al cancelar.

Validación AA: 54 pruebas de contratos previos verdes, 3 del contrato4 verdes; pruebas integradas en Lienzo verifican carga/hash, reutilización, rechazo sin efecto y terminación del PID SWI real. Evidencia en D:/Apps/lienzo/.temp/resultados/2026-10-22-AA/. Sin instalación de runtimes ni reinicio de consumidores.

