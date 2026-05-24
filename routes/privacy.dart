import 'package:dart_frog/dart_frog.dart';

Response onRequest(RequestContext context) {
  final langParam = context.request.uri.queryParameters['lang'];
  final acceptLang = context.request.headers['accept-language'] ?? '';
  final isSpanish = langParam == 'es' ||
      (langParam == null && acceptLang.toLowerCase().contains('es'));

  final date = isSpanish
      ? '13 de mayo de 2026'
      : 'May 13, 2026';

  final html = isSpanish ? _htmlSpanish(date) : _htmlEnglish(date);

  return Response(
    body: html,
    headers: {
      'Content-Type': 'text/html; charset=utf-8',
      'X-Content-Type-Options': 'nosniff',
    },
  );
}

String _htmlEnglish(String date) => '''
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Privacy Policy – Parché</title>
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; line-height: 1.7; padding: 24px; max-width: 800px; margin: auto; color: #333; background: #fafafa; }
    h1 { color: #5d4037; font-size: 1.8em; }
    h2 { color: #6d4c41; margin-top: 32px; font-size: 1.1em; border-bottom: 1px solid #e0d3c8; padding-bottom: 6px; }
    p, li { font-size: 0.95em; color: #555; }
    ul { padding-left: 22px; }
    li { margin-bottom: 8px; }
    .highlight { background: #fdf3ee; padding: 18px 20px; border-left: 5px solid #8d6e63; margin: 24px 0; border-radius: 6px; }
    .highlight h2 { color: #5d4037; border: none; padding: 0; margin-top: 0; }
    .lang-switch { text-align: right; margin-bottom: 8px; font-size: 0.85em; }
    .lang-switch a { color: #8d6e63; text-decoration: none; }
    .footer { margin-top: 50px; font-size: 0.85em; color: #9e9e9e; border-top: 1px solid #eee; padding-top: 20px; }
  </style>
</head>
<body>
  <div class="lang-switch"><a href="?lang=es">🇪🇸 Español</a></div>
  <h1>Privacy Policy</h1>
  <p><strong>Last updated:</strong> $date</p>

  <p>At <strong>Parché</strong>, we take the protection of your personal data seriously. This Privacy Policy explains what information we collect, how we use it, and how you can control it. By using the app, you agree to the practices described here.</p>

  <h2>1. Information We Collect</h2>
  <p>We collect the following data to provide you with the gaming experience:</p>
  <ul>
    <li><strong>Google Account:</strong> Name, email address, and profile photo when you sign in with Google.</li>
    <li><strong>Device identifier:</strong> A UUID generated to identify you in matches.</li>
    <li><strong>Game data:</strong> XP, level, wins, match statistics, and chosen username.</li>
    <li><strong>Chat messages:</strong> Messages you send during matches.</li>
  </ul>

  <h2>2. How We Use Your Information</h2>
  <p>We use your data exclusively to:</p>
  <ul>
    <li>Manage your account and in-game progression.</li>
    <li>Enable real-time multiplayer gaming.</li>
    <li>Sync your progress across devices.</li>
    <li>Display your name and stats on the board and leaderboards.</li>
    <li>Moderate content and ensure a fair gaming environment.</li>
  </ul>

  <h2>3. Third-Party Services</h2>
  <p>The app uses the following third-party services that may process your data:</p>
  <ul>
    <li><strong>Google Firebase</strong> (Authentication, Firestore, Cloud Services) — provided by Google LLC. See <a href="https://policies.google.com/privacy" target="_blank">Google's Privacy Policy</a>.</li>
    <li><strong>Google Sign-In</strong> — for secure account authentication.</li>
  </ul>

  <h2>4. Data Sharing</h2>
  <p>We do not sell, rent, or share your personal data with third parties for advertising or commercial purposes. Data is only shared with the third-party services listed above, which are required for the app to function.</p>

  <h2>5. Data Retention</h2>
  <p>We retain your data for as long as your account remains active. When you delete your account, all your data (profile, progress, match history) is permanently deleted from our servers within 30 days.</p>

  <div class="highlight">
    <h2>6. Your Rights &amp; Data Deletion (Google Play &amp; App Store Compliance)</h2>
    <p>You have the right to access, correct, and delete your personal data at any time.</p>
    <ul>
      <li><strong>In-App Deletion:</strong> Go to Settings → <em>"Delete account"</em> to permanently erase all your data immediately.</li>
      <li><strong>Web Form:</strong> Visit <a href="/delete_account">/delete_account</a> to request deletion without logging in.</li>
      <li><strong>Email Request:</strong> Send an email to <strong>jorgeluisalmanzar@gmail.com</strong> with the subject <em>"Data Deletion Request"</em>.</li>
    </ul>
    <p><em>Warning: Once your account is deleted, this action is irreversible and all your progress will be lost.</em></p>
    <p>We comply with Google Play Data Safety policies and Apple App Store privacy requirements.</p>
  </div>

  <h2>7. Children's Privacy</h2>
  <p>Parché's <strong>offline mode</strong> is available to users of all ages and collects no personal data.</p>
  <p><strong>Online features</strong> (Google Sign-In, multiplayer, cloud sync) require users to be 13 or older, in accordance with Google's Terms of Service and COPPA regulations. We do not knowingly collect personal data from children under 13 through our online services. If you believe a child has provided personal data, contact us at the email below to have it removed.</p>

  <h2>8. Security</h2>
  <p>All communication between the app and our servers uses SSL/TLS encryption. Data is securely stored in Google Firebase, which complies with ISO 27001 and SOC 2 security standards.</p>

  <h2>9. Changes to This Policy</h2>
  <p>We may update this Privacy Policy periodically. We will notify you of significant changes through the app. Continued use of the app after changes constitutes acceptance of the updated policy.</p>

  <h2>10. Contact Us</h2>
  <p>If you have questions about this Privacy Policy or wish to exercise your rights, contact us:</p>
  <p><strong>Email:</strong> <a href="mailto:jorgeluisalmanzar@gmail.com">jorgeluisalmanzar@gmail.com</a></p>

  <div class="footer">
    <p>Parché — Developed to bring safe and fun gaming experiences.</p>
  </div>
</body>
</html>
''';

String _htmlSpanish(String date) => '''
<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Política de Privacidad – Parché</title>
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; line-height: 1.7; padding: 24px; max-width: 800px; margin: auto; color: #333; background: #fafafa; }
    h1 { color: #5d4037; font-size: 1.8em; }
    h2 { color: #6d4c41; margin-top: 32px; font-size: 1.1em; border-bottom: 1px solid #e0d3c8; padding-bottom: 6px; }
    p, li { font-size: 0.95em; color: #555; }
    ul { padding-left: 22px; }
    li { margin-bottom: 8px; }
    .highlight { background: #fdf3ee; padding: 18px 20px; border-left: 5px solid #8d6e63; margin: 24px 0; border-radius: 6px; }
    .highlight h2 { color: #5d4037; border: none; padding: 0; margin-top: 0; }
    .lang-switch { text-align: right; margin-bottom: 8px; font-size: 0.85em; }
    .lang-switch a { color: #8d6e63; text-decoration: none; }
    .footer { margin-top: 50px; font-size: 0.85em; color: #9e9e9e; border-top: 1px solid #eee; padding-top: 20px; }
  </style>
</head>
<body>
  <div class="lang-switch"><a href="?lang=en">🇬🇧 English</a></div>
  <h1>Política de Privacidad</h1>
  <p><strong>Última actualización:</strong> $date</p>

  <p>En <strong>Parché</strong>, nos tomamos muy en serio la protección de tus datos personales. Esta Política de Privacidad explica qué información recopilamos, cómo la usamos y cómo puedes controlarla. Al usar la app, aceptas las prácticas descritas aquí.</p>

  <h2>1. Información que Recopilamos</h2>
  <p>Recopilamos los siguientes datos para ofrecerte la experiencia de juego:</p>
  <ul>
    <li><strong>Cuenta Google:</strong> Nombre, correo electrónico y foto de perfil al iniciar sesión con Google.</li>
    <li><strong>Identificador de dispositivo:</strong> Un UUID generado para identificarte en las partidas.</li>
    <li><strong>Datos de juego:</strong> XP, nivel, victorias, estadísticas de partidas y nombre de usuario elegido.</li>
    <li><strong>Mensajes de chat:</strong> Los mensajes que envías durante las partidas.</li>
  </ul>

  <h2>2. Uso de la Información</h2>
  <p>Utilizamos tus datos exclusivamente para:</p>
  <ul>
    <li>Gestionar tu cuenta y progresión en el juego.</li>
    <li>Habilitar el juego multijugador en tiempo real.</li>
    <li>Sincronizar tu progreso entre dispositivos.</li>
    <li>Mostrar tu nombre y estadísticas en el tablero y clasificaciones.</li>
    <li>Moderar el contenido y garantizar un entorno de juego justo.</li>
  </ul>

  <h2>3. Servicios de Terceros</h2>
  <p>La aplicación usa los siguientes servicios de terceros que pueden procesar tus datos:</p>
  <ul>
    <li><strong>Google Firebase</strong> (Autenticación, Firestore, Cloud) — proporcionado por Google LLC. Consulta la <a href="https://policies.google.com/privacy" target="_blank">Política de Privacidad de Google</a>.</li>
    <li><strong>Google Sign-In</strong> — para autenticación segura de cuentas.</li>
  </ul>

  <h2>4. Compartición de Datos</h2>
  <p>No vendemos, alquilamos ni compartimos tus datos personales con terceros con fines publicitarios o comerciales. Los datos solo se comparten con los servicios mencionados arriba, necesarios para el funcionamiento de la app.</p>

  <h2>5. Retención de Datos</h2>
  <p>Conservamos tus datos mientras tu cuenta permanezca activa. Al eliminar tu cuenta, todos tus datos (perfil, progreso, historial de partidas) se borran permanentemente de nuestros servidores en un plazo de 30 días.</p>

  <div class="highlight">
    <h2>6. Tus Derechos y Eliminación de Datos (Cumplimiento Google Play y App Store)</h2>
    <p>Tienes derecho a acceder, corregir y eliminar tus datos personales en cualquier momento.</p>
    <ul>
      <li><strong>Eliminación desde la App:</strong> Ve a Ajustes → <em>"Eliminar cuenta"</em> para borrar todos tus datos permanentemente.</li>
      <li><strong>Formulario web:</strong> Visita <a href="/delete_account">/delete_account</a> para solicitar la eliminación sin iniciar sesión.</li>
      <li><strong>Solicitud por correo:</strong> Envía un correo a <strong>jorgeluisalmanzar@gmail.com</strong> con el asunto <em>"Solicitud de eliminación de datos"</em>.</li>
    </ul>
    <p><em>Aviso: Una vez eliminada tu cuenta, la acción es irreversible y perderás todo tu progreso.</em></p>
    <p>Cumplimos con las políticas de seguridad de datos de Google Play y los requisitos de privacidad de la App Store de Apple.</p>
  </div>

  <h2>7. Privacidad de Menores</h2>
  <p>El <strong>modo sin conexión</strong> de Parché está disponible para usuarios de todas las edades y no recopila ningún dato personal.</p>
  <p>Las <strong>funciones en línea</strong> (inicio de sesión con Google, multijugador, sincronización en la nube) requieren tener 13 años o más, conforme a los Términos de Servicio de Google y la normativa COPPA. No recopilamos intencionalmente datos personales de menores de 13 años a través de los servicios en línea. Si crees que un menor ha proporcionado datos, contáctanos para eliminarlos.</p>

  <h2>8. Seguridad</h2>
  <p>Toda la comunicación entre la app y nuestros servidores usa cifrado SSL/TLS. Los datos se almacenan de forma segura en Google Firebase, que cumple con los estándares de seguridad ISO 27001 y SOC 2.</p>

  <h2>9. Cambios en Esta Política</h2>
  <p>Podemos actualizar esta Política de Privacidad periódicamente. Te notificaremos de cambios significativos a través de la aplicación. El uso continuado de la app tras los cambios implica aceptación de la nueva política.</p>

  <h2>10. Contacto</h2>
  <p>Si tienes preguntas sobre esta Política de Privacidad o deseas ejercer tus derechos, contáctanos:</p>
  <p><strong>Correo:</strong> <a href="mailto:jorgeluisalmanzar@gmail.com">jorgeluisalmanzar@gmail.com</a></p>

  <div class="footer">
    <p>Parché — Desarrollado para ofrecer diversión segura.</p>
  </div>
</body>
</html>
''';
