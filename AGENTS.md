# Motor lógico

Motor opcional, independiente de las aplicaciones y reutilizable desde varios repos. Contrato JSON
versionado por stdin/stdout; cada consulta usa un proceso. Nunca ejecuta goals ni código recibidos
ni lee almacenes como código. Cambios de contrato requieren versión nueva.
Contrato 1 (learning): sin persistencia, semántica congelada porque Lienzo la compara; cualquier
cambio en `learning.pl` exige prueba diferencial contra la versión anterior y aviso a Lienzo.
Contrato 2 (logic): persistencia sólo en almacenes con nombre bajo `MOTOR_LOGICO_DATA`, escritura
todo o nada. Las reglas de aprendizaje no son reglas de ajedrez.
No instalar runtimes ni reiniciar las aplicaciones consumidoras para probar cambios.
Aplicar las preferencias de Ariel: pruebas-agenticas con cinco roles secuenciales y code review.
