import 'package:flutter/material.dart';
import '../../core/theme/app_colors.dart';

/// Single source of truth for the earning methods shown on Home and Earn.
class EarnMethod {
  final String title;
  final String subtitle;
  final IconData icon;
  final Color color;
  final String route;
  const EarnMethod(
      this.title, this.subtitle, this.icon, this.color, this.route);
}

const earnMethods = <EarnMethod>[
  EarnMethod('Daily Reward', 'Claim every day', Icons.calendar_today_rounded,
      AppColors.primary, '/earn/daily'),
  EarnMethod('Mining', 'Earn while you\'re away', Icons.bolt_rounded,
      AppColors.gold, '/earn/mining'),
  EarnMethod('Scratch Card', 'Reveal a prize', Icons.card_giftcard_rounded,
      Color(0xFFEC4899), '/earn/scratch'),
  EarnMethod('Watch Ads', 'Quick rewards', Icons.play_circle_fill_rounded,
      AppColors.success, '/earn/ads'),
  EarnMethod('Daily Quiz', 'Test your brain', Icons.psychology_rounded,
      Color(0xFF8B5CF6), '/earn/quiz'),
  EarnMethod('Tasks', 'Complete & earn', Icons.checklist_rounded,
      AppColors.info, '/earn/tasks'),
  EarnMethod('Search Card', 'Search & win BCP', Icons.travel_explore_rounded,
      Color(0xFF0EA5E9), '/earn/search'),
  EarnMethod('Contests', 'Hit targets, win BCP', Icons.emoji_events_rounded,
      Color(0xFFF59E0B), '/contests'),
];
