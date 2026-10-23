# Revisión AA — servicio persistente, 2026-10-22

Alcance: servicio.pl y tests/test_servicio.py, nuevo contrato 4 autorizado por Ariel. Revisión estática en la sesión AA, sin agentes independientes. Contratos 1–3 sin cambios.

- read_term lee datos ground con lista cerrada; no consult ni goals de cliente.
- AST se valida mediante logic_request(3) antes de cachear. Guard creencia_habilitada impide habilitar propuestas por tener archivo.
- Caché path/hash SHA-256 binario; no se mezclan hechos de consultas consecutivas.
- Rechazo de store/assert/retract. Plazo interno y máximo de archivos/línea.
- EOF cancela worker; cliente interactivo recibe cada respuesta antes de cerrar. Se detectó un test que enviaba EOF anticipado: se conservó su rojo y se corrigió la precondición del cliente.
- Tests conductuales: directiva intentaría crear sentinel, se rechaza sin efecto; hash incorrecto y store se rechazan y la consulta siguiente funciona.
- 54 contratos anteriores verdes + 3 nuevos verdes. Integración real Lienzo verifica PID SWI terminado, T3 escritura bloqueada y T11 efecto prohibido.
- Revisión focal sin auditoría de dependencias no modificadas. No push, runtime instalado ni reinicio.
- Cinco roles secuenciales y artefactos del encargo: D:/Apps/lienzo/.temp/resultados/2026-10-22-AA/runner/. Baseline/mutaciones quedan a la coordinadora; no se atribuye PASS a la compuerta.

ESTADO: delta de motor listo para commit local.

