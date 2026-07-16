import 'package:flutter/material.dart';

class MinervaLogo extends StatelessWidget {
  const MinervaLogo({super.key, this.compact = false});
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(compact ? 3 : 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(compact ? 10 : 18),
        boxShadow: const [
          BoxShadow(color: Colors.black26, blurRadius: 8, offset: Offset(0, 2)),
        ],
      ),
      child: Image.asset(
        'assets/images/minerva_nautica.png',
        height: compact ? 46 : 150,
        fit: BoxFit.contain,
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
