import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/app_colors.dart';
import '../../core/widgets/common.dart';
import '../../core/widgets/state_views.dart';
import '../../providers/data_providers.dart';
import '../../providers/repositories.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _name = TextEditingController();
  bool _saving = false;
  bool _init = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await ref
          .read(userRepositoryProvider)
          .updateProfile(fullName: _name.text.trim());
      ref.invalidate(profileProvider);
      if (mounted) showSnack(context, 'Profile updated');
    } catch (e) {
      if (mounted) showSnack(context, '$e', error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final profileAsync = ref.watch(profileProvider);
    if (!_init && profileAsync.valueOrNull != null) {
      _name.text = profileAsync.value!.fullName ?? '';
      _init = true;
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: SafeArea(
        top: false,
        child: profileAsync.when(
          loading: () => const LoadingView(),
          error: (e, _) =>
              ErrorView(error: e, onRetry: () => ref.invalidate(profileProvider)),
          data: (profile) => ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const _Group('Profile'),
              SectionCard(
                child: Column(
                  children: [
                    TextField(
                      controller: _name,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(
                        labelText: 'Full name',
                        prefixIcon: Icon(Icons.person_outline_rounded),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      enabled: false,
                      decoration: InputDecoration(
                        labelText: 'Email',
                        hintText: profile.email,
                        prefixIcon: const Icon(Icons.mail_outline_rounded),
                      ),
                    ),
                    const SizedBox(height: 14),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: _saving ? null : _save,
                        child: _saving
                            ? const SizedBox(
                                height: 20,
                                width: 20,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2.2, color: Colors.white))
                            : const Text('Save changes'),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              const _Group('About & support'),
              _link(Icons.help_outline_rounded, 'Help & support',
                  'mailto:support@bluechiprewards.app'),
              _link(Icons.description_outlined, 'Terms of Service',
                  'https://bluechiprewards.app/terms'),
              _link(Icons.privacy_tip_outlined, 'Privacy Policy',
                  'https://bluechiprewards.app/privacy'),
              const SizedBox(height: 10),
              const _Group('App information'),
              const ListTile(
                leading: Icon(Icons.info_outline_rounded),
                title: Text('Version'),
                trailing: Text('1.0.0'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _link(IconData icon, String title, String url) {
    return ListTile(
      leading: Icon(icon, color: AppColors.textPrimary),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
      trailing: const Icon(Icons.open_in_new_rounded, size: 18),
      onTap: () {
        final uri = Uri.tryParse(url);
        if (uri != null) launchUrl(uri, mode: LaunchMode.externalApplication);
      },
    );
  }
}

class _Group extends StatelessWidget {
  final String title;
  const _Group(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10, left: 4),
      child: Text(title.toUpperCase(),
          style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              letterSpacing: 1,
              color: AppColors.textSecondary)),
    );
  }
}
