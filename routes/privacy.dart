import 'package:dart_frog/dart_frog.dart';

Response onRequest(RequestContext context) {
  final htmlContent = '''
<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Política de Privacidad - Parchís Online</title>
    <style>
        body { font-family: sans-serif; line-height: 1.6; padding: 20px; max-width: 800px; margin: auto; color: #333; }
        h1 { color: #2c3e50; }
        h2 { color: #2980b9; margin-top: 30px; }
        .highlight { background: #f9f9f9; padding: 20px; border-left: 5px solid #e74c3c; margin: 20px 0; border-radius: 5px; }
        ul { padding-left: 20px; }
        li { margin-bottom: 10px; }
        .footer { margin-top: 50px; font-size: 0.9em; color: #7f8c8d; border-top: 1px solid #eee; padding-top: 20px; }
    </style>
</head>
<body>
    <h1>Política de Privacidad</h1>
    <p><strong>Última actualización:</strong> ${DateTime.now().day}/${DateTime.now().month}/${DateTime.now().year}</p>

    <p>En <strong>Parchís Online</strong>, nos tomamos muy en serio la protección de tus datos personales. Esta Política de Privacidad explica qué información recopilamos, cómo la usamos y, lo más importante, cómo puedes controlarla.</p>

    <h2>1. Información que recopilamos</h2>
    <p>Para ofrecerte una experiencia de juego en línea, recopilamos los siguientes datos mínimos:</p>
    <ul>
        <li><strong>Identificador de Usuario (clientId):</strong> Un código único generado automáticamente para identificarte en el servidor.</li>
        <li><strong>Nombre de Usuario:</strong> El nombre que eliges mostrar a otros jugadores durante las partidas.</li>
        <li><strong>Datos de Juego:</strong> Posición de tus fichas, turnos y estadísticas básicas necesarias para la lógica del juego.</li>
    </ul>

    <div class="highlight">
        <h2>2. Derecho al Borrado de Datos (Google Play Compliance)</h2>
        <p>De acuerdo con las políticas de seguridad de datos de Google Play, proporcionamos un método sencillo y directo para que elimines toda tu información de nuestros sistemas:</p>
        <ul>
            <li><strong>Borrado desde la Aplicación:</strong> Dentro del menú de Ajustes de la App, encontrarás la opción "Eliminar mi cuenta y datos". Al confirmarlo, el servidor recibirá una orden inmediata para borrar permanentemente tu ID, nombre y cualquier registro asociado.</li>
            <li><strong>Solicitud Manual:</strong> También puedes solicitar el borrado enviando un correo electrónico a <strong>jorgeluisalmanzar@gmail.com</strong>.</li>
        </ul>
        <p><em>Nota: Una vez ejecutado el borrado, la acción es irreversible y perderás todo tu progreso en el juego.</em></p>
    </div>

    <h2>3. Uso de la Información</h2>
    <p>Utilizamos tus datos exclusivamente para:</p>
    <ul>
        <li>Permitir el emparejamiento con otros jugadores en tiempo real.</li>
        <li>Mantener la sincronización de la partida (fichas, turnos y ganadores).</li>
        <li>Mostrar tu nombre en el podio de ganadores al finalizar el juego.</li>
    </ul>

    <h2>4. Seguridad</h2>
    <p>Toda la comunicación entre la aplicación y nuestro servidor se realiza de forma cifrada para proteger tu información durante el juego.</p>

    <div class="footer">
        <p>Parchís Online - Desarrollado para ofrecer diversión segura.</p>
        <p>Contacto: jorgeluisalmanzar@gmail.com</p>
    </div>
</body>
</html>
''';

  return Response(
    body: htmlContent,
    headers: {
      'Content-Type': 'text/html; charset=utf-8',
      'X-Content-Type-Options': 'nosniff',
    },
  );
}
