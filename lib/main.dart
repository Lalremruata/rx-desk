import 'package:flutter/widgets.dart';

import 'bootstrap.dart';
import 'core/utils/desktop_window.dart';
import 'core/utils/format.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initFormatting();
  setUpDesktopWindow();
  runApp(const Bootstrap());
}
