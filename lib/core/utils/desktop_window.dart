import 'dart:io' show Platform;
import 'dart:ui' show Size;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:window_manager/window_manager.dart';

bool get isDesktop => !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

/// Window size + title on desktop.
///
/// Windows (the counter PC) gets the 1100×700 minimum from CLAUDE.md. On
/// macOS / Linux (development only) the window may shrink further so the
/// rail and compact layouts can be checked by resizing.
void setUpDesktopWindow() {
  if (!isDesktop) return;
  final window = WindowManager.instance.getCurrent();
  if (window == null) return;
  final minSize = Platform.isWindows ? const Size(1100, 700) : const Size(420, 600);
  window
    ..title = 'RxDesk'
    ..minimumSize = minSize.toNative()
    ..setSize(const Size(1280, 800).toNative(), false)
    ..center()
    ..show();
}
