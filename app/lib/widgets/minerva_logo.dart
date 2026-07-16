import 'package:flutter/material.dart';

class MinervaLogo extends StatelessWidget {
  const MinervaLogo({super.key, this.compact = false});
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(compact ? 10 : 18),
      child: Image.asset(
        'assets/images/minerva_nautica.png',
        width: compact ? 46 : 150,
        height: compact ? 46 : 150,
        fit: BoxFit.cover,
        filterQuality: FilterQuality.high,
        semanticLabel: 'Minerva Náutica',
      ),
    );
  }
}

class MinervaAppBarTitle extends StatelessWidget {
  const MinervaAppBarTitle({super.key, required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const MinervaLogo(compact: true),
        const SizedBox(width: 12),
        Flexible(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
      ],
    );
  }
}
