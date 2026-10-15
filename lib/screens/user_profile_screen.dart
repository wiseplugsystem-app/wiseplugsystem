import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../services/auth_error.dart';
import '../services/device_binding.dart';
import '../services/esp32_service.dart';

/// Shows the signed-in account and the 1:1 bound gadget, and lets the user
/// permanently delete their account after re-entering their password.
class UserProfileScreen extends StatelessWidget {
  final Esp32Service service;
  final FirebaseAuth? auth;
  final Future<String> Function()? loadBinding;
  const UserProfileScreen({
    super.key,
    required this.service,
    this.auth,
    this.loadBinding,
  });

  FirebaseAuth get _auth => auth ?? FirebaseAuth.instance;

  Future<void> _signOut(BuildContext context) async {
    Navigator.of(context).popUntil((route) => route.isFirst);
    await _auth.signOut();
  }

  Future<void> _delete(BuildContext context) async {
    final deleted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => DeleteAccountDialog(
        auth: _auth,
        removeUserData: (uid) => service.database.ref('users/$uid').remove(),
      ),
    );
    if (deleted == true && context.mounted) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = _auth.currentUser;
    return Scaffold(
      appBar: AppBar(title: const Text('User Profile')),
      body: ListView(
        padding: const EdgeInsets.all(22),
        children: [
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.email_outlined),
                  title: const Text('Account email'),
                  subtitle: Text(user?.email ?? 'Not signed in'),
                ),
                const Divider(height: 1),
                FutureBuilder<String>(
                  future: (loadBinding ?? DeviceBinding.ensureBound)(),
                  builder: (context, snapshot) => ListTile(
                    leading: const Icon(Icons.memory),
                    title: const Text('Bound device ID'),
                    subtitle: Text(
                      '${snapshot.data ?? DeviceBinding.gadgetId} · '
                      'locked 1:1 (one app, one gadget)',
                    ),
                    trailing: const Icon(Icons.lock_outline),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          OutlinedButton.icon(
            onPressed: user == null ? null : () => _signOut(context),
            icon: const Icon(Icons.logout),
            label: const Text('Sign out'),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
            onPressed: user == null ? null : () => _delete(context),
            icon: const Icon(Icons.delete_forever_outlined),
            label: const Text('Delete account'),
          ),
        ],
      ),
    );
  }
}

/// Always re-authenticates with the password before deleting, even when the
/// session is recent. Pops `true` once the account has been deleted.
class DeleteAccountDialog extends StatefulWidget {
  final FirebaseAuth auth;
  final Future<void> Function(String uid) removeUserData;
  const DeleteAccountDialog({
    super.key,
    required this.auth,
    required this.removeUserData,
  });

  @override
  State<DeleteAccountDialog> createState() => _DeleteAccountDialogState();
}

class _DeleteAccountDialogState extends State<DeleteAccountDialog> {
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    final user = widget.auth.currentUser;
    final email = user?.email;
    if (user == null || email == null) {
      setState(() => _error = 'Only email/password accounts can be deleted here.');
      return;
    }
    if (_password.text.isEmpty) {
      setState(() => _error = 'Enter your password to confirm.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await user.reauthenticateWithCredential(
        EmailAuthProvider.credential(email: email, password: _password.text),
      );
      await widget.removeUserData(user.uid);
      await user.delete();
      if (mounted) Navigator.of(context).pop(true);
    } on FirebaseAuthException catch (e) {
      if (mounted) {
        setState(
          () => _error =
              ['wrong-password', 'invalid-credential'].contains(e.code)
              ? 'Incorrect password. Your account was not deleted.'
              : authErrorMessage(e),
        );
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Could not delete your account data. Check your connection and try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Delete account?'),
    content: SizedBox(
      width: 380,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'This permanently deletes your WisePlug account and your saved settings. Enter your password to confirm.',
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _password,
            enabled: !_busy,
            obscureText: true,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Password',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (_) => _busy ? null : _confirm(),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_error!, style: const TextStyle(color: Colors.red)),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: _busy ? null : () => Navigator.of(context).pop(false),
        child: const Text('Cancel'),
      ),
      FilledButton(
        style: FilledButton.styleFrom(backgroundColor: Colors.red),
        onPressed: _busy ? null : _confirm,
        child: Text(_busy ? 'Deleting…' : 'Delete account'),
      ),
    ],
  );
}
