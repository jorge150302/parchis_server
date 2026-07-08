import 'dart:convert';
import 'dart:io';

import 'package:dart_firebase_admin/auth.dart';
import 'package:dart_firebase_admin/dart_firebase_admin.dart';
import 'package:dart_firebase_admin/firestore.dart';

FirebaseAdminApp? _adminApp;
late Auth _adminAuth;
late Firestore _adminFirestore;

/// Returns the lazily-initialised [FirebaseAdminApp].
/// Throws [StateError] if `service_account.json` is missing.
FirebaseAdminApp getAdminApp() {
  if (_adminApp != null) return _adminApp!;

  final saFile = File('service_account.json');
  if (!saFile.existsSync()) {
    throw StateError(
      'service_account.json not found. Place the Firebase service account '
      'file in the parchis_server/ root directory.',
    );
  }

  final saJson = jsonDecode(saFile.readAsStringSync()) as Map<String, dynamic>;
  final projectId = saJson['project_id'] as String;
  final clientEmail = saJson['client_email'] as String;
  final privateKey = saJson['private_key'] as String;
  final clientId = saJson['client_id'] as String;

  _adminApp = FirebaseAdminApp.initializeApp(
    projectId,
    Credential.fromServiceAccountParams(
      clientId: clientId,
      privateKey: privateKey,
      email: clientEmail,
    ),
  );
  _adminAuth = Auth(_adminApp!);
  _adminFirestore = Firestore(_adminApp!);
  return _adminApp!;
}

/// Returns the [Auth] instance, initialising Firebase Admin if needed.
Auth getAdminAuth() {
  getAdminApp();
  return _adminAuth;
}

/// Returns the [Firestore] instance, initialising Firebase Admin if needed.
Firestore getAdminFirestore() {
  getAdminApp();
  return _adminFirestore;
}

/// Verifies [idToken] and returns the authenticated user's UID.
///
/// Returns `null` if invalid or expired.
/// Returns `null` (not a bypass) when `service_account.json` is absent —
/// callers that need a dev bypass should check [isAdminConfigured] themselves.
Future<String?> getUidFromToken(String? idToken) async {
  if (idToken == null || idToken.isEmpty) return null;
  try {
    final decoded = await getAdminAuth().verifyIdToken(idToken);
    return decoded.uid;
  } catch (_) {
    return null;
  }
}

/// `true` when `service_account.json` exists next to the server root.
bool get isAdminConfigured => File('service_account.json').existsSync();

/// Verifies [idToken] against Firebase Auth.
///
/// Returns `true` if valid. Returns `false` if the token is invalid/expired.
/// Returns `true` as a dev bypass when `service_account.json` is absent.
Future<bool> verifyIdToken(String? idToken) async {
  if (!isAdminConfigured) return true; // Dev mode bypass
  if (idToken == null || idToken.isEmpty) return false;
  return await getUidFromToken(idToken) != null;
}
