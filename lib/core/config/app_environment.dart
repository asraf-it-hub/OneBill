abstract final class AppEnvironment {
  static const supabaseUrl = String.fromEnvironment(
    'ONEBILL_SUPABASE_URL',
    defaultValue: 'https://xohoflgjopudlhkdzwos.supabase.co',
  );
  static const supabasePublishableKey = String.fromEnvironment(
    'ONEBILL_SUPABASE_PUBLISHABLE_KEY',
    defaultValue: 'sb_publishable_99Osm7an2ciABUjI5WxiOQ_qk5CfMAZ',
  );
  static const googleWebClientId = String.fromEnvironment(
    'ONEBILL_GOOGLE_WEB_CLIENT_ID',
    defaultValue: '1005411352233-v4ppg6cvefh308h791lbu6u70qrqpnud.apps.googleusercontent.com',
  );

  static bool get cloudConfigured =>
      supabaseUrl.startsWith('https://') &&
      supabasePublishableKey.startsWith('sb_publishable_');
}
