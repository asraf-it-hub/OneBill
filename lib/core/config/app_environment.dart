abstract final class AppEnvironment {
  static const supabaseUrl = String.fromEnvironment(
    'ONEBILL_SUPABASE_URL',
    defaultValue: 'https://xohoflgjopudlhkdzwos.supabase.co',
  );
  static const supabasePublishableKey = String.fromEnvironment(
    'ONEBILL_SUPABASE_PUBLISHABLE_KEY',
    defaultValue: 'sb_publishable_99Osm7an2ciABUjI5WxiOQ_qk5CfMAZ',
  );

  static bool get cloudConfigured =>
      supabaseUrl.startsWith('https://') &&
      supabasePublishableKey.startsWith('sb_publishable_');
}
