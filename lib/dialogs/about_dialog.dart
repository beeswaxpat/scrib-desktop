import 'package:flutter/material.dart';
import '../constants.dart';

void showScribAbout(BuildContext context) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  final colorScheme = Theme.of(context).colorScheme;
  final heading = isDark ? const Color(0xFFE0E0E0) : const Color(0xFF1A1A1A);
  final body = isDark ? const Color(0xFF909090) : const Color(0xFF666666);
  final muted = isDark ? const Color(0xFF585858) : const Color(0xFFAAAAAA);
  final dividerColor = isDark ? const Color(0xFF2A2A2A) : const Color(0xFFE0E0E0);
  final cardColor = isDark ? const Color(0xFF161616) : const Color(0xFFF5F5F5);

  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      titlePadding: EdgeInsets.zero,
      contentPadding: const EdgeInsets.fromLTRB(28, 24, 28, 12),
      actionsPadding: const EdgeInsets.fromLTRB(28, 0, 28, 16),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Image.asset('assets/scrib_icon.png', width: 40, height: 40),
                const SizedBox(width: 14),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Scrib Desktop',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.3,
                        color: heading,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Text('v$appVersion',
                            style: TextStyle(fontSize: 11, color: muted)),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: colorScheme.primary.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            'GPL-3.0',
                            style: TextStyle(
                              fontSize: 9.5,
                              fontWeight: FontWeight.w600,
                              color: colorScheme.primary,
                              letterSpacing: 0.3,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 18),
            Divider(height: 1, thickness: 0.5, color: dividerColor),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'The encrypted editor.',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: colorScheme.primary,
                  letterSpacing: 0.2,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                appTagline,
                style: TextStyle(fontSize: 12, color: body),
              ),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: cardColor,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                children: [
                  _aboutRow(
                    Icons.shield_outlined,
                    'AES-256 encryption + tamper protection',
                    body,
                    colorScheme.primary,
                  ),
                  const SizedBox(height: 8),
                  _aboutRow(
                    Icons.description_outlined,
                    'Plain text, rich text, and .scrb',
                    body,
                    colorScheme.primary,
                  ),
                  const SizedBox(height: 8),
                  _aboutRow(
                    Icons.lock_outlined,
                    'Your files. Your keys. Always.',
                    body,
                    colorScheme.primary,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Divider(height: 1, thickness: 0.5, color: dividerColor),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: isDark
                    ? const Color(0xFF0A0A0A)
                    : const Color(0xFF1A1A1A),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                ' ___  ___ ___ ___ ___\n'
                r'/ __|/ __| _ \_ _| _ )' '\n'
                r'\__ \ (__|   /| || _ \' '\n'
                r'|___/\___|_|_\___|___/' '\n'
                '     BEESWAX  PAT',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: 'Consolas',
                  fontSize: 10,
                  height: 1.2,
                  color: colorScheme.primary,
                  letterSpacing: 0.5,
                ),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Built with Claude Code',
              style: TextStyle(
                fontSize: 10.5,
                color: muted,
                letterSpacing: 0.1,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}

Widget _aboutRow(IconData icon, String text, Color textColor, Color iconColor) {
  return Row(
    children: [
      Icon(icon, size: 14, color: iconColor.withValues(alpha: 0.7)),
      const SizedBox(width: 10),
      Expanded(
        child: Text(
          text,
          style: TextStyle(fontSize: 12, color: textColor, letterSpacing: 0.1),
        ),
      ),
    ],
  );
}
