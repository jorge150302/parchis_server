# Parchís Multiplayer Server 🎲🤖

Servidor de alto rendimiento para un juego de Parchís multijugador, desarrollado con **Dart Frog** y **WebSockets**.

## 🚀 Características principales

- **Multi-sala**: Soporta múltiples partidas simultáneas mediante códigos de sala de 5 dígitos.
- **IA de Sustitución**: Si un jugador se desconecta, una IA toma el control de su ficha automáticamente tras 2 segundos.
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
