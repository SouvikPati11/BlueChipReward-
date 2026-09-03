import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/push/reminder_service.dart';
import '../../core/widgets/common.dart';
import '../../core/widgets/state_views.dart';
import '../../providers/data_providers.dart';
import '../../providers/repositories.dart';
import '../../providers/theme_provider.dart';
import 'package:bluechip_rewards/core/theme/app_palette.dart';

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
              const _Group('Notifications'),
              const SectionCard(
                padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                child: _RemindersTile(),
              ),
              const SizedBox(height: 20),
              const _Group('Appearance'),
              SectionCard(
                padding: const EdgeInsets.all(14),
                child: _ThemePicker(
                  mode: ref.watch(themeModeProvider),
                  onChanged: (m) =>
                      ref.read(themeModeProvider.notifier).setMode(m),
                ),
              ),
              const SizedBox(height: 20),
              const _Group('About & support'),
              ref.watch(appLinksProvider).maybeWhen(
                    data: (links) => links.isEmpty
                        ? _fallbackLinks()
                        : Column(
                            children: [
                              for (final l in links)
                                _link(
                                  _iconFor(l['icon'] as String?),
                                  '${l['label']}',
                                  '${l['url']}',
                                  external: l['external'] as bool? ?? true,
                                ),
                            ],
                          ),
                    orElse: _fallbackLinks,
                  ),
              const SizedBox(height: 10),
              const _Group('App information'),
              const ListTile(
                leading: Icon(Icons.info_outline_rounded),
                title: Text('Version'),
                trailing: Text('1.4.2'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _fallbackLinks() {
    return Column(
      children: [
        _link(Icons.help_outline_rounded, 'Help & support',
            'https://souvikpati11.github.io/BlueChipReward-/'),
        _link(Icons.description_outlined, 'Terms of Service',
            'https://souvikpati11.github.io/BlueChipReward-/terms.html'),
        _link(Icons.privacy_tip_outlined, 'Privacy Policy',
            'https://souvikpati11.github.io/BlueChipReward-/privacy.html'),
      ],
    );
  }

  Widget _link(IconData icon, String title, String url,
      {bool external = true}) {
    return ListTile(
      leading: Icon(icon, color: context.cx.textPrimary),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
      trailing: Icon(
          external ? Icons.open_in_new_rounded : Icons.chevron_right_rounded,
          size: 18),
      onTap: () {
        if (external) {
          final uri = Uri.tryParse(url);
          if (uri != null) {
            launchUrl(uri, mode: LaunchMode.externalApplication);
          }
        } else {
          context.push(url);
        }
      },
    );
  }

  /// Map an admin-provided icon name to a Material icon (safe fallback).
  IconData _iconFor(String? name) {
    switch (name) {
      case 'support_agent':
        return Icons.support_agent_rounded;
      case 'send':
        return Icons.send_rounded;
      case 'help_center':
        return Icons.help_center_rounded;
      case 'description':
        return Icons.description_outlined;
      case 'privacy_tip':
        return Icons.privacy_tip_outlined;
      case 'star':
        return Icons.star_rounded;
      case 'public':
        return Icons.public_rounded;
      default:
        return Icons.link_rounded;
    }
  }
}

class _ThemePicker extends StatelessWidget {
  final ThemeMode mode;
  final ValueChanged<ThemeMode> onChanged;
  const _ThemePicker({required this.mode, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<ThemeMode>(
      segments: const [
        ButtonSegment(
            value: ThemeMode.system,
            icon: Icon(Icons.brightness_auto_rounded),
            label: Text('System')),
        ButtonSegment(
            value: ThemeMode.light,
            icon: Icon(Icons.light_mode_rounded),
            label: Text('Light')),
        ButtonSegment(
            value: ThemeMode.dark,
            icon: Icon(Icons.dark_mode_rounded),
            label: Text('Dark')),
      ],
      selected: {mode},
      showSelectedIcon: false,
      onSelectionChanged: (s) => onChanged(s.first),
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
          style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              letterSpacing: 1,
              color: context.cx.textSecondary)),
    );
  }
}

/// Toggle for on-device daily reminders (local notifications). Turning it on
/// requests the notification permission and schedules the reminders; off
/// cancels them. Denial is handled gracefully by [ReminderService].
class _RemindersTile extends StatefulWidget {
  const _RemindersTile();

  @override
  State<_RemindersTile> createState() => _RemindersTileState();
}

class _RemindersTileState extends State<_RemindersTile> {
  bool _enabled = true;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    ReminderService.isEnabled().then((v) {
      if (mounted) setState(() {
            _enabled = v;
            _loading = false;
          });
    });
  }

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      value: _enabled,
      onChanged: _loading
          ? null
          : (v) async {
              setState(() => _enabled = v);
              await ReminderService.setEnabled(v);
              if (v && mounted) {
                final ok = await ReminderService.requestPermission();
                if (!ok && mounted) {
                  showSnack(context,
                      'Enable notifications in system settings to receive reminders.');
                }
              }
            },
      secondary: const Icon(Icons.alarm_rounded),
      title: const Text('Daily reminders'),
      subtitle: const Text(
          'On-device reminders for daily reward, mining, quiz, tasks and more'),
    );
  }
}
