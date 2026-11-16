import 'package:flutter/widgets.dart';

import '../theme/tokens.dart';
import 'page_enter.dart';

/// Standard scrolling page body: page padding (28 px sides, 16 on compact),
/// [gap] between sections, and each child entering with a 50 ms stagger.
class PageScroll extends StatelessWidget {
  const PageScroll({super.key, required this.children, this.gap = AppSpace.xl, this.controller});

  final List<Widget> children;
  final double gap;
  final ScrollController? controller;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < AppSizes.breakpointRail;
    final x = compact ? AppSpace.lg : AppSpace.pageX;
    return SingleChildScrollView(
      controller: controller,
      padding: EdgeInsets.fromLTRB(x, compact ? AppSpace.lg : 0, x, 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, c) in children.indexed) ...[
            if (i > 0) SizedBox(height: gap),
            PageEnter(index: i, child: c),
          ],
        ],
      ),
    );
  }
}
