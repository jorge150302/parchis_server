# Parchís Multiplayer Server 🎲🤖

Servidor de alto rendimiento para un juego de Parchís multijugador, desarrollado con **Dart Frog** y **WebSockets**.

## 🚀 Características principales

- **Multi-sala**: Soporta múltiples partidas simultáneas mediante códigos de sala de 5 dígitos.
- **IA de Sustitución**: Si un jugador se desconecta, una IA toma el control de sus fichas tras 90 segundos de gracia.
- **Chat en tiempo real**: Sistema de mensajería integrado por sala.
- **Sincronización de UI**: Envío optimizado de eventos para animaciones fluidas (delay entre dado y movimiento).
- **Slots Fijos**: Asignación de colores persistente mediante índices (0-3).

## 🛠️ Requisitos

- Dart SDK
- Dart Frog CLI (`dart pub global activate dart_frog_cli`)

## 💻 Cómo ejecutar el servidor

Para desarrollo local y conexión con dispositivos móviles en la misma red:

```bash
dart_frog dev --hostname 0.0.0.0
```

El servidor escuchará en el puerto **8080**.

### Variables de entorno

| Variable | Efecto |
|---|---|
| `FIREBASE_SERVICE_ACCOUNT_JSON` | Contenido JSON de la cuenta de servicio de Firebase (recomendado en producción: como secreto del hosting). |
| `GOOGLE_APPLICATION_CREDENTIALS` | Alternativa: ruta al archivo de la cuenta de servicio. Si ninguna está definida, se usa `service_account.json` en la carpeta actual. |
| `PORT` | Puerto (por defecto 8080). |
| `PARCHIS_DEV_AUTH_BYPASS=true` | Sin credenciales de Firebase, acepta conexiones sin verificar el token de Firebase. **Solo desarrollo local.** Si falta el archivo y no se define, el servidor rechaza a todos. |
| `PARCHIS_ALLOW_TEST_MODE=true` | Permite salas `testMode` (dados forzados con `debug_set_dice`). Siempre privadas. **Nunca en producción.** |

```bash
PARCHIS_DEV_AUTH_BYPASS=true dart_frog dev --hostname 0.0.0.0
```

### Producción (Docker)

```bash
docker build -t parchis-server .
docker run -p 8080:8080 -e FIREBASE_SERVICE_ACCOUNT_JSON="$(cat service_account.json)" parchis-server
```

La imagen nunca incluye `service_account.json` (ver `.dockerignore`); la credencial se pasa al arrancar.

### Tests

```bash
dart test
```

## 📱 Conexión desde el Cliente (Flutter)

URL del WebSocket:
- **Emulador Android**: `ws://10.0.2.2:8080/ws`
- **Móvil Real / Desktop**: `ws://tu_ip_local:8080/ws`

## 🧪 Pruebas por Consola

Puedes probar el servidor sin necesidad de la App usando el cliente de prueba incluido:

```bash
dart bin/client_test.dart
```

---
Desarrollado con ❤️ usando Dart Frog.
