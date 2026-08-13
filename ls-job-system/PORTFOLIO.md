# ls-job-system — guía rápida para entrevista

## Qué hace el proyecto

Es un resource independiente de FiveM para un trabajo de repartidor sobre QBCore. El jugador habla con un NPC mediante qb-target, recibe una ruta aleatoria y un vehículo, completa las entregas en orden, vuelve al depósito y cobra. El progreso temporal vive en memoria del servidor; las estadísticas acumuladas se guardan en MySQL mediante oxmysql.

La primera implementación está terminada, pero todavía no fue validada dentro de un servidor FiveM real. Esa diferencia es importante: revisión estática no equivale a prueba de integración.

## Arquitectura

```text
Jugador
  → NPC + qb-target
  → evento de solicitud del cliente
  → validación y sesión autoritativa del servidor
  → entrega actual enviada al cliente
  → validación server-side de la entrega
  → cálculo y acreditación con QBCore
  → UPSERT de estadísticas con oxmysql
  → MySQL / MariaDB
```

- `config.lua`: valores de gameplay y presentación que deberían variar entre servidores.
- `shared/constants.lua`: nombres de eventos y estados usados por ambos runtimes.
- `client/main.lua`: NPC, target, blip, marker, animación, teclas, notificaciones y resincronización.
- `server/main.lua`: sesiones, orden de entregas, distancias, vehículo, pago y lifecycle.
- `server/repository.lua`: única operación SQL del flujo.
- `sql/install.sql`: esquema versionable para instalar la tabla.

## Flujo completo

1. El cliente crea un NPC local, invencible, congelado y ajeno a eventos ambientales.
2. qb-target muestra “Iniciar trabajo de repartidor” cuando el cliente no conoce una sesión activa.
3. El click sólo dispara una solicitud sin monto, ruta ni permisos enviados por el cliente.
4. El servidor controla cooldown, jugador QBCore, ausencia de otra sesión y distancia al NPC.
5. El servidor reserva una matrícula única, crea un único vehículo server-side y entrega las llaves mediante los exports actuales de qb-vehiclekeys.
6. Guarda la sesión por `source`, además del `citizenid`, el handle/net ID del vehículo y la matrícula, y envía sólo los datos de presentación necesarios.
7. El cliente dibuja ruta, blip y marker. Al presionar `E`, reproduce UX local y solicita completar.
8. El servidor busca el destino esperado en su propia sesión, confirma personaje, estado, lock y distancia.
9. Si es válido, incrementa el progreso y envía el siguiente destino. El cliente no elige el índice.
10. Al terminar, el servidor cambia a `awaiting_return`; el cliente enruta al depósito.
11. Para cerrar, el servidor exige todas las entregas, jugador y vehículo asignado cerca del depósito.
12. Calcula el pago con su configuración y llama a `Player.Functions.AddMoney`.
13. Si el pago fue exitoso, separa la sesión del mapa autoritativo, revoca llaves y elimina el vehículo.
14. Con la sesión ya inutilizable para un segundo cobro, espera el `INSERT ... ON DUPLICATE KEY UPDATE` de estadísticas.

## Qué hace el cliente

- Carga, configura y elimina el NPC.
- Registra las opciones de qb-target.
- Mantiene una copia de presentación de la sesión, no el estado autoritativo.
- Crea y reemplaza el blip de la entrega o del regreso.
- Dibuja el marker sólo cuando el jugador está razonablemente cerca.
- Ejecuta la animación y evita interacciones repetidas para mejorar la UX.
- Espera de forma acotada a que el Network ID resuelva a una entidad local válida y recién entonces configura aspectos visuales del vehículo.
- Limpia NPC y blips en `onResourceStop`.
- Pide una instantánea al servidor si su resource se reinicia.

Que el cliente oculte una opción con `canInteract` no es seguridad. Un atacante puede llamar el evento igualmente; por eso el servidor repite todas las reglas importantes.

## Qué hace el servidor

- Es propietario de `Sessions[source]` y del lock `Starting[source]`.
- Usa un token único por intento para que una desconexión o reutilización de `source` durante la creación del vehículo no deje una sesión vieja.
- Vincula la sesión al `citizenid`, no solamente al ID de conexión reutilizable.
- Elige cantidad y orden de destinos.
- Crea y conserva el handle del vehículo asignado.
- Genera la matrícula y gestiona las llaves del vehículo exclusivamente en servidor.
- Decide cuál es la única entrega válida en cada momento.
- Consulta las coordenadas sincronizadas del ped y del vehículo mediante OneSync.
- Aplica cooldowns y un lock de procesamiento.
- Calcula y acredita la recompensa.
- Persiste estadísticas una vez por turno terminado.
- Revoca llaves, limpia sesiones y elimina vehículos al cancelar, desconectar o detener el resource.

## Cómo funciona la persistencia

`ls_delivery_stats` tiene un ID interno y un `citizenid` único. Guarda trabajos terminados, entregas, dinero acumulado y timestamps.

Al finalizar se ejecuta una sola sentencia parametrizada:

- si el `citizenid` no existe, inserta una fila;
- si existe, incrementa los tres contadores;
- no se hace primero un `SELECT`, evitando una ida extra y una carrera entre “consultar” e “insertar”.

Los parámetros evitan concatenar valores del jugador en SQL. El pago de QBCore y las estadísticas no son una transacción única: si el UPSERT falla después de pagar, se conserva el pago y se loguea la inconsistencia. El resultado sólo vuelve al cliente si, después del `await`, el `source` sigue siendo del mismo `citizenid` y no tiene una sesión nueva o un inicio pendiente. Una evolución razonable sería una cola de reintentos.

## Seguridad con ejemplos concretos

### “¿Qué impide que un cheater llame al evento de completar?”

El evento no recibe ni índice ni destino. El servidor exige una sesión del mismo personaje en estado `delivering`, toma `deliveries[currentDelivery]` de su memoria, comprueba el lock/cooldown y mide la distancia del ped sincronizado hasta ese punto. Un evento remoto o fuera de orden no avanza.

### “¿Qué impide que llame al evento de terminar con $50.000?”

El evento de terminar no acepta monto. El servidor verifica que el contador coincida con la cantidad asignada, que el estado sea `awaiting_return`, y que jugador y vehículo estén en el depósito. Recién entonces suma valores de `Config.Rewards` del runtime server-side.

### “¿Cómo evitás dos pagos simultáneos?”

La sesión posee `processing` y pasa a `paying`. Si `AddMoney` devuelve éxito, se elimina de `Sessions` antes de esperar el UPSERT. Una segunda ejecución ya no encuentra una sesión cobrable.

### “¿Puedo confiar totalmente en la distancia server-side?”

No. OneSync permite leer el sync tree desde el servidor y evita confiar en coordenadas incluidas en el evento, lo cual frena el exploit básico. Pero hay latencia y el estado de movimiento se origina en la simulación de red; se necesita tolerancia y un anticheat separado para teleports sofisticados.

### “¿Qué pasa si cambia de personaje sin cambiar de source?”

Cada operación sensible vuelve a comparar `PlayerData.citizenid` con el de la sesión. Si no coincide, se limpia la sesión. Además, el handler server-side `QBCore:Server:OnPlayerUnload` limpia la sesión mientras el objeto Player todavía está disponible; no depende de que el cliente solicite la cancelación.

### “¿Por qué las llaves se gestionan desde el servidor?”

La versión upstream revisada de qb-vehiclekeys expone `GiveKeys(source, plate)`, `RemoveKeys(source, plate)` y `HasKeys(source, plate)` en servidor. El resource usa esa interfaz y no el evento cliente legacy `vehiclekeys:client:SetOwner`. La revocación forma parte de todos los caminos de cleanup porque qb-vehiclekeys puede persistir llaves en metadata; en el unload se vuelve a guardar el Player después de removerlas.

### “¿Un Network ID válido garantiza que ya existe la entidad en mi cliente?”

No. El identificador puede existir en la red antes de que la entidad se haya materializado localmente. El cliente reintenta con `Wait(50)` hasta que obtiene un handle distinto de cero y `DoesEntityExist` confirma la entidad, con un timeout configurable. Si vence, no usa el handle inválido ni altera el estado autoritativo del turno.

### “¿Cómo evitás colisiones de matrícula?”

La matrícula se genera en servidor con un prefijo identificable y un sufijo numérico configurable, respetando el límite de ocho caracteres usado por GTA/FiveM. Se compara contra reservas, sesiones, inicios pendientes y vehículos existentes. Hay una cantidad finita de intentos; si se agotan, el inicio aborta y limpia lo que corresponda. Las matrículas emitidas no se reutilizan durante la vida del resource.

## Decisiones técnicas

- **QBCore:** aporta identidad estable (`citizenid`), objeto Player, cuentas de dinero, notificaciones y creación server-side del vehículo.
- **oxmysql:** ofrece queries parametrizadas y API `await`; el UPSERT reduce round trips y evita un patrón check-then-insert.
- **qb-target:** resuelve de forma coherente la interacción con la entidad NPC sin introducir otro menú para una sola acción.
- **Estado server-authoritative:** los datos que producen progreso o dinero no dependen de una copia modificable en el cliente.
- **Configuración separada:** permite cambiar balance, ubicaciones y entidades sin tocar reglas del flujo.
- **Sesión en memoria:** una ruta activa es efímera. No persistirla hace explícito que una desconexión cancela el turno y evita sesiones fantasma cobrables.
- **Un repositorio SQL pequeño:** separa persistencia sin construir una capa genérica innecesaria.
- **Vehículo server-side:** el servidor conserva y vuelve a comprobar handle, Network ID y hash del modelo esperado; una matrícula distinta se registra como anomalía, pero no impide por sí sola el cleanup.
- **Llaves server-side:** usa los exports actuales de qb-vehiclekeys, confirma la asignación y revoca la matrícula temporal durante el cleanup; no usa `SetOwner` legacy.
- **OneSync obligatorio:** permite crear la entidad desde servidor y consultar coordenadas sincronizadas. El manifest lo expresa con el constraint `/onesync`.
- **Matrícula server-side:** amplía el espacio de combinaciones, evita colisiones con usos activos y limita los reintentos para no bloquear.

## Posibles preguntas de entrevista

1. **¿Por qué no calculás el dinero en el cliente?**  
   Porque cualquier cliente puede modificar o disparar eventos. El servidor usa sólo su progreso y su configuración.

2. **¿Cómo evitás que repitan un evento?**  
   Con estado esperado, cooldown por acción, lock `processing` y eliminación de la sesión después del pago.

3. **¿Por qué guardás `source` y `citizenid`?**  
   `source` identifica la conexión actual; `citizenid` verifica que sigue siendo el mismo personaje.

4. **¿Cómo se comunica Lua con QBCore?**  
   Se obtiene el core mediante el export y se usan funciones documentadas del core y del objeto Player.

5. **¿Cómo funciona un resource FiveM?**  
   Es una carpeta con un manifest y scripts cargados en runtimes client, server o shared, iniciada por la configuración del servidor.

6. **¿Qué es `fxmanifest.lua`?**  
   Declara metadata, juego, scripts y dependencias que FiveM necesita para cargar el resource.

7. **¿Cuál es la diferencia entre client y server?**  
   El cliente controla presentación y natives locales; el servidor conserva autoridad, integra economía y persiste datos.

8. **¿Qué persistís y qué queda en memoria?**  
   Persisto contadores acumulados. La ruta, índice, vehículo y locks existen sólo durante la sesión.

9. **¿Por qué un UPSERT?**  
   Inserta o incrementa atómicamente por clave única en una sola ida a la base.

10. **¿Por qué no persistís cada entrega?**  
    No es necesario para el objetivo y generaría más escrituras. La regla actual cancela rutas incompletas.

11. **¿Qué limpia `onResourceStop`?**  
    En servidor, vehículos y sesiones. En cliente, target, NPC, blip y referencias locales.

12. **¿Qué aporta OneSync aquí?**  
    Entidades creadas/controladas desde el servidor y lectura server-side de posiciones sincronizadas.

13. **¿Qué pasa si MySQL falla después del pago?**  
    El pago no se duplica ni revierte; se registra el fallo. La consistencia completa requeriría un mecanismo de retry/outbox.

14. **¿La matrícula prueba que volvió el vehículo correcto?**  
    No. El servidor valida handle, Network ID y modelo guardados para esa sesión. La matrícula server-side sirve para integrar llaves y detectar anomalías, pero un cambio de matrícula no redefine la identidad del vehículo.

15. **¿Por qué no agregaste una abstracción genérica de jobs?**  
    Sólo existe un flujo. Una abstracción sin un segundo caso real agregaría complejidad y haría más difícil explicar el código.

16. **¿Por qué no usás `vehiclekeys:client:SetOwner`?**  
    Es una interfaz legacy. La integración actual usa `GiveKeys`, `RemoveKeys` y `HasKeys` desde servidor.

17. **¿Network ID y entidad local son lo mismo?**  
    No. El ID identifica la entidad en red; cada cliente puede necesitar tiempo para resolverlo a un handle local existente.

18. **¿Qué ocurre si falla `AddMoney`?**  
    Se libera el lock, se restaura `awaiting_return`, no se elimina la sesión y no se persisten estadísticas, de modo que el jugador puede reintentar sin pago fantasma.

19. **¿Qué ocurre si MySQL falla después del pago?**  
    La sesión ya fue eliminada para impedir otro cobro. Se conserva el pago, se loguea el fallo y se informa que las estadísticas no se guardaron; no se simula un rollback entre sistemas distintos.

## Puntos que debería poder explicar sin mirar código

- [ ] Qué archivos carga `fxmanifest.lua` y en qué orden.
- [ ] La diferencia entre solicitud del cliente y decisión del servidor.
- [ ] La forma exacta de una sesión en memoria.
- [ ] Cómo se selecciona una ruta sin repetir ubicaciones.
- [ ] Por qué el evento de entrega no necesita parámetros.
- [ ] Todas las condiciones para aceptar una entrega.
- [ ] Todas las condiciones para cerrar y pagar un turno.
- [ ] Cuándo se toma y libera cada lock.
- [ ] Cómo se evita un pago duplicado mientras se espera MySQL.
- [ ] Qué significa validar distancia con OneSync y cuáles son sus límites.
- [ ] Por qué `citizenid` tiene un índice único.
- [ ] Qué hace el UPSERT y por qué no hay un `SELECT` previo.
- [ ] Qué ocurre al cancelar, desconectar y reiniciar el resource.
- [ ] Cómo se entregan, verifican, revocan y persisten las llaves temporales con `qb-vehiclekeys`.
- [ ] Por qué un Network ID todavía puede no tener una entidad local disponible.
- [ ] Cómo se generan matrículas sin colisiones activas y por qué los reintentos son finitos.
- [ ] Por qué `/onesync` es una dependencia funcional del manifest.
- [ ] Qué se revisó estáticamente y qué falta probar dentro de FiveM.
