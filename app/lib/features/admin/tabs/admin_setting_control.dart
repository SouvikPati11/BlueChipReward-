import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/common.dart';

/// Control type for an admin setting.
enum SettingKind { toggle, number, percent, text, json, choice }

/// A single admin setting: which app_settings key it edits, its label, the
/// control to render, and (for [SettingKind.choice]) the allowed values.
class Spec {
  final String key;
  final String label;
  final String? help;
  final SettingKind kind;
  final List<String>? options;
  const Spec(this.key, this.label, this.kind, [this.help, this.options]);
}

/// The selectable ad networks (stored value → display label).
const List<String> kAdNetworks = ['admob', 'applovin', 'unity'];
const Map<String, String> kAdNetworkLabels = {
  'admob': 'AdMob',
  'applovin': 'AppLovin MAX',
  'unity': 'Unity Ads',
};

/// True for every app_settings key that belongs to the Admin → Ads panel.
/// Config uses this to EXCLUDE ad keys from its "Other" fallback, so ad
/// settings live in exactly one place (the Ads panel) with no duplication.
bool isAdSettingKey(String key) {
  const exact = {
    'ads_system_enabled',
    'rewarded_ads_enabled',
    'banner_ads_enabled',
    'ads_test_mode',
    'ads_reward',
    'rewarded_daily_cap',
    'ads_daily_cap',
    'ads_min_gap_seconds',
    'admob_rewarded_id',
    'admob_banner_id',
    'applovin_rewarded_id',
    'applovin_banner_id',
    'unity_rewarded_id',
    'unity_banner_id',
  };
  if (exact.contains(key)) return true;
  return key.startsWith('ad_gate_') ||
      key.startsWith('banner_') ||
      key.startsWith('ad_network_') ||
      key.startsWith('banner_network_');
}

/// A titled card grouping related settings.
class CategoryCard extends StatelessWidget {
  final String title;
  final List<Widget> children;
  const CategoryCard({super.key, required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: SectionCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title.toUpperCase(),
                style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    letterSpacing: .8,
                    color: AppColors.primary)),
            const SizedBox(height: 8),
            ...children,
          ],
        ),
      ),
    );
  }
}

/// Renders one setting (toggle / choice-dropdown / number / text / json) and
/// saves via [onSave]. Identical behaviour for the Config and Ads panels.
class SettingControl extends StatefulWidget {
  final Spec spec;
  final dynamic value;
  final ValueChanged<dynamic> onSave;
  const SettingControl(
      {super.key,
      required this.spec,
      required this.value,
      required this.onSave});

  @override
  State<SettingControl> createState() => _SettingControlState();
}

class _SettingControlState extends State<SettingControl> {
  late TextEditingController _ctrl;
  late bool _bool;

  @override
  void initState() {
    super.initState();
    _bool = widget.value == true;
    _ctrl = TextEditingController(text: _initialText());
  }

  String _initialText() {
    switch (widget.spec.kind) {
      case SettingKind.json:
        return const JsonEncoder.withIndent('  ').convert(widget.value);
      case SettingKind.text:
        return '${widget.value ?? ''}';
      default:
        return '${widget.value ?? ''}';
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sp = widget.spec;
    if (sp.kind == SettingKind.toggle) {
      return SwitchListTile(
        value: _bool,
        contentPadding: EdgeInsets.zero,
        title: Text(sp.label),
        subtitle: sp.help != null ? Text(sp.help!) : null,
        onChanged: (v) {
          setState(() => _bool = v);
          widget.onSave(v);
        },
      );
    }

    if (sp.kind == SettingKind.choice) {
      final opts = sp.options ?? const <String>[];
      final cur = '${widget.value ?? ''}';
      final selected =
          opts.contains(cur) ? cur : (opts.isNotEmpty ? opts.first : null);
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(sp.label),
                  if (sp.help != null)
                    Text(sp.help!,
                        style:
                            const TextStyle(fontSize: 11, color: Colors.grey)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            DropdownButton<String>(
              value: selected,
              onChanged: (v) {
                if (v != null) widget.onSave(v);
              },
              items: [
                for (final o in opts)
                  DropdownMenuItem(
                      value: o, child: Text(kAdNetworkLabels[o] ?? o)),
              ],
            ),
          ],
        ),
      );
    }

    final isNum =
        sp.kind == SettingKind.number || sp.kind == SettingKind.percent;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: TextField(
              controller: _ctrl,
              keyboardType: isNum
                  ? const TextInputType.numberWithOptions(decimal: true)
                  : (sp.kind == SettingKind.json
                      ? TextInputType.multiline
                      : TextInputType.text),
              maxLines: sp.kind == SettingKind.json ? null : 1,
              decoration: InputDecoration(
                labelText: sp.label,
                helperText: sp.help,
                helperMaxLines: 2,
                isDense: true,
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.save_rounded),
            color: AppColors.primary,
            onPressed: () {
              final text = _ctrl.text.trim();
              dynamic value;
              try {
                switch (sp.kind) {
                  case SettingKind.number:
                  case SettingKind.percent:
                    value = num.parse(text);
                    break;
                  case SettingKind.json:
                    value = jsonDecode(text);
                    break;
                  case SettingKind.text:
                    value = text;
                    break;
                  case SettingKind.toggle:
                    value = _bool;
                    break;
                  case SettingKind.choice:
                    value = text; // choice saves via its dropdown, not here
                    break;
                }
              } catch (_) {
                showSnack(context, 'Invalid value for ${sp.label}',
                    error: true);
                return;
              }
              widget.onSave(value);
            },
          ),
        ],
      ),
    );
  }
}
