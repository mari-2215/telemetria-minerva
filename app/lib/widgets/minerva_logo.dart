import 'package:flutter/material.dart';

class MinervaLogo extends StatelessWidget {
  const MinervaLogo({super.key, this.compact = false});
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: compact ? 34 : 54,
          height: compact ? 34 : 54,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: const Color(0xFF020617),
            border: Border.all(color: const Color(0xFF38BDF8), width: 2),
          ),
          child: Icon(Icons.sailing, size: compact ? 22 : 34, color: const Color(0xFF7DD3FC)),
        ),
        const SizedBox(width: 10),
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('MINERVA', style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: compact ? 1.2 : 2.2, fontSize: compact ? 15 : 22)),
            Text('NAUTICA', style: TextStyle(color: const Color(0xFF7DD3FC), letterSpacing: compact ? 2.0 : 3.2, fontSize: compact ? 8 : 11)),
          ],
        ),
      ],
    );
  }
}
