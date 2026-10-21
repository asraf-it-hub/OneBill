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
    // Remove private receipt objects owned by this account before deleting
    // database rows. The prefix is derived from the verified JWT subject and
    // can never be supplied by the client.
    const { data: receiptObjects, error: listError } = await admin.storage
      .from('paper-receipts')
      .list(userId, { limit: 1000 });
    if (listError) {
      console.error('Receipt cleanup listing failed:', listError);
      return reply({ error: 'Could not prepare account data for deletion.' }, 500);
    }
    const objectPaths: string[] = [];
    for (const entry of receiptObjects ?? []) {
      if (!entry.name) continue;
      if (entry.id) {
        objectPaths.push(`${userId}/${entry.name}`);
        continue;
      }
      const { data: children, error: childError } = await admin.storage
        .from('paper-receipts')
        .list(`${userId}/${entry.name}`, { limit: 1000 });
      if (childError) {
        console.error('Receipt folder listing failed:', childError);
        return reply({ error: 'Could not prepare account files for deletion.' }, 500);
      }
      for (const child of children ?? []) {
        if (child.name) objectPaths.push(`${userId}/${entry.name}/${child.name}`);
      }
    }
    if (objectPaths.length > 0) {
      const { error: removeError } = await admin.storage
        .from('paper-receipts')
        .remove(objectPaths);
      if (removeError) {
        console.error('Receipt cleanup failed:', removeError);
        return reply({ error: 'Could not remove account files.' }, 500);
      }
    }

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
    const { error: authDeleteError } = await admin.auth.admin.deleteUser(userId);
    // The deployed SQL RPC may already remove auth.users. A not-found result
    // therefore confirms completion rather than indicating a partial failure.
    if (authDeleteError && authDeleteError.status !== 404 && authDeleteError.code !== 'user_not_found') {
      console.error('Admin deleteUser failed:', authDeleteError);
      return reply({ error: 'Account data was cleaned up, but the login account could not be deleted. Please contact support.' }, 500);
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
