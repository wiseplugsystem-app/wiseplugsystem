import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../services/esp32_service.dart';
import '../services/auth_error.dart';

class AuthGate extends StatelessWidget {
  final Widget child;
  const AuthGate({super.key, required this.child});
  @override
  Widget build(BuildContext context) => StreamBuilder<User?>(
    stream: FirebaseAuth.instance.authStateChanges(),
    builder: (context, snapshot) {
      if (snapshot.connectionState == ConnectionState.waiting) {
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      }
      return snapshot.data == null
          ? const SignInScreen()
          : _NotificationSession(
              key: ValueKey(snapshot.data!.uid),
              child: child,
            );
    },
  );
}

class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key});
  @override
  State<SignInScreen> createState() => _SignInState();
}

class _SignInState extends State<SignInScreen> {
  final _email = TextEditingController(), _password = TextEditingController();
  final _confirmation = TextEditingController();
  final _form = GlobalKey<FormState>();
  bool _creatingAccount = false;
  bool _busy = false;
  String? _error;
  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (_busy || !_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_creatingAccount) {
        await FirebaseAuth.instance.createUserWithEmailAndPassword(
          email: _email.text.trim(),
          password: _password.text,
        );
      } else {
        await FirebaseAuth.instance.signInWithEmailAndPassword(
          email: _email.text.trim(),
          password: _password.text,
        );
      }
    } on FirebaseAuthException catch (e) {
      if (mounted) {
        setState(() => _error = authErrorMessage(e));
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Unable to connect. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        _creatingAccount ? 'Create your WisePlug account' : 'WisePlug sign in',
      ),
    ),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Form(
          key: _form,
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(24),
            children: [
              Text(
                _creatingAccount
                    ? 'First time here? Enter your email and choose a new password.'
                    : 'Welcome back. Sign in, or create an account if you are new to WisePlug.',
              ),
              TextFormField(
                controller: _email,
                enabled: !_busy,
                validator: (value) =>
                    RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$')
                        .hasMatch(value?.trim() ?? '')
                    ? null
                    : 'Enter a valid email address.',
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(labelText: 'Email'),
              ),
              TextFormField(
                controller: _password,
                enabled: !_busy,
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Enter your password.';
                  }
                  if (_creatingAccount && value.length < 6) {
                    return 'Use at least 6 characters.';
                  }
                  return null;
                },
                obscureText: true,
                decoration: InputDecoration(
                  labelText: _creatingAccount
                      ? 'Choose a password'
                      : 'Password',
                ),
                onFieldSubmitted: (_) {
                  if (!_busy) _login();
                },
              ),
              if (_creatingAccount) ...[
                TextFormField(
                  controller: _confirmation,
                  enabled: !_busy,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Confirm password',
                  ),
                  validator: (value) => value == _password.text
                      ? null
                      : 'Passwords do not match.',
                  onFieldSubmitted: (_) => _login(),
                ),
                const Padding(
                  padding: EdgeInsets.only(top: 16),
                  child: Text(
                    'After creating your account, ask your WisePlug administrator to link your account to your device.',
                  ),
                ),
              ],
              if (_error != null)
                Text(_error!, style: const TextStyle(color: Colors.red)),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _busy ? null : _login,
                child: Text(
                  _busy
                      ? 'Please wait…'
                      : _creatingAccount
                      ? 'Create account'
                      : 'Sign in',
                ),
              ),
              TextButton(
                onPressed: _busy
                    ? null
                    : () {
                        _form.currentState?.reset();
                        setState(() {
                          _creatingAccount = !_creatingAccount;
                          _error = null;
                          _password.clear();
                          _confirmation.clear();
                        });
                      },
                child: Text(
                  _creatingAccount
                      ? 'Already have an account? Sign in'
                      : 'New to WisePlug? Create account',
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _NotificationSession extends StatefulWidget {
  final Widget child;
  const _NotificationSession({super.key, required this.child});
  @override
  State<_NotificationSession> createState() => _NotificationSessionState();
}

class _NotificationSessionState extends State<_NotificationSession> {
  StreamSubscription<String>? _tokens;
  StreamSubscription<RemoteMessage>? _messages;
  late final String _uid = FirebaseAuth.instance.currentUser!.uid;
  Future<void> _saveToken(String token) =>
      Esp32Service().database.ref('users/$_uid/fcmTokens/$token').set(true);
  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    if (kIsWeb ||
        (defaultTargetPlatform != TargetPlatform.android &&
            defaultTargetPlatform != TargetPlatform.iOS)) {
      return;
    }
    try {
      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission(alert: true, sound: true, badge: true);
      await messaging.setForegroundNotificationPresentationOptions(
        alert: true,
        sound: true,
        badge: true,
      );
      final token = await messaging.getToken();
      if (!mounted) return;
      if (token != null) await _saveToken(token);
      if (!mounted) return;
      _tokens = messaging.onTokenRefresh.listen((token) async {
        try {
          await _saveToken(token);
        } catch (_) {
          /* Retried on next sign-in. */
        }
      });
      _messages = FirebaseMessaging.onMessage.listen((message) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                message.notification?.body ??
                    'WisePlug safety alert. Check your outlets.',
              ),
              duration: const Duration(seconds: 10),
            ),
          );
        }
      });
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Push notifications are unavailable. Live safety status remains on the dashboard.',
            ),
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    _tokens?.cancel();
    _messages?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
