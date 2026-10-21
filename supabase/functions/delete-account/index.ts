import { createClient } from 'npm:@supabase/supabase-js@2';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

const reply = (body: unknown, status = 200) => new Response(
  status === 204 ? null : JSON.stringify(body),
  { status, headers: { ...cors, 'Content-Type': 'application/json' } },
);

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') return reply({}, 204);
  if (request.method !== 'POST') return reply({ error: 'Use POST.' }, 405);

  const token = request.headers.get('Authorization')?.match(/^Bearer\s+(.+)$/i)?.[1];
  if (!token) return reply({ error: 'Missing bearer token.' }, 401);

  const url = Deno.env.get('SUPABASE_URL');
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY');
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');

  if (!url || !anonKey || !serviceKey) {
    return reply({ error: 'Function secrets are incomplete.' }, 500);
  }

  // 1. Verify caller identity using their JWT Bearer token
  const authClient = createClient(url, anonKey, {
    global: { headers: { Authorization: `Bearer ${token}` } },
  });
  const { data: userData, error: userError } = await authClient.auth.getUser(token);
  if (userError || !userData.user) {
    return reply({ error: 'Invalid or expired session. Please re-authenticate.' }, 401);
  }

  const userId = userData.user.id;

  // 2. Perform backend data cleanup using admin client with service role
  const admin = createClient(url, serviceKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  try {
    // Run the cleanup RPC through the verified user's client so auth.uid()
    // remains the source of ownership. The service-role client must not be
    // used for this call because it has no user JWT and could not safely bind
    // the deletion to the verified account.
    const { data: rpcData, error: rpcError } = await authClient.rpc(
      'delete_user_account',
    );

    if (rpcError) {
      console.error('RPC delete_user_account failed:', rpcError);
      return reply({ error: `Backend data cleanup failed: ${rpcError.message}` }, 500);
    }

    // Explicitly delete user via Supabase Auth Admin API if not already deleted by RPC
    try {
      await admin.auth.admin.deleteUser(userId);
    } catch (authDeleteErr) {
      console.log('Admin deleteUser note:', authDeleteErr);
    }

    return reply({
      success: true,
      message: 'Account and associated data deleted permanently.',
      details: rpcData,
    });
  } catch (err) {
    console.error('Account deletion error:', err);
    return reply({ error: err instanceof Error ? err.message : 'Internal deletion error' }, 500);
  }
});
