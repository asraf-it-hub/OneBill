abstract final class AppEnvironment {
  static const supabaseUrl = String.fromEnvironment('ONEBILL_SUPABASE_URL');
  static const supabasePublishableKey = String.fromEnvironment(
    'ONEBILL_SUPABASE_PUBLISHABLE_KEY',
  );

  static bool get cloudConfigured =>
      supabaseUrl.startsWith('https://') &&
      supabasePublishableKey.startsWith('sb_publishable_');
}
