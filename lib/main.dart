import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app/app.dart';
import 'core/config/app_environment.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (AppEnvironment.cloudConfigured) {
    await Supabase.initialize(
      url: AppEnvironment.supabaseUrl,
      publishableKey: AppEnvironment.supabasePublishableKey,
    );
  }
  runApp(const ProviderScope(child: OneBillApp()));
}
