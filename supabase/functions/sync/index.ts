import { createClient } from 'npm:@supabase/supabase-js@2';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
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
  if (!url || !anonKey || !serviceKey) return reply({ error: 'Function secrets are incomplete.' }, 500);
  const auth = createClient(url, anonKey, { global: { headers: { Authorization: `Bearer ${token}` } } });
  const { data: userData, error: userError } = await auth.auth.getUser(token);
  if (userError || !userData.user) return reply({ error: 'Invalid or expired session.' }, 401);
  let body: { deviceId?: unknown; operations?: unknown };
  try { body = await request.json(); } catch (_) { return reply({ error: 'Body must be valid JSON.' }, 400); }
  if (typeof body.deviceId !== 'string' || !uuid.test(body.deviceId)) return reply({ error: 'deviceId must be a UUID.' }, 400);
  if (!Array.isArray(body.operations) || body.operations.length === 0 || body.operations.length > 100) return reply({ error: 'operations must contain 1 to 100 entries.' }, 400);
  const admin = createClient(url, serviceKey, { auth: { autoRefreshToken: false, persistSession: false } });
  const acknowledgedOperationIds: string[] = [];
  const conflicts: Array<{ operationId: string | null; reason: string }> = [];
  const failed: Array<{ operationId: string | null; reason: string }> = [];
  for (const value of body.operations) {
    const operation = value as Record<string, unknown>;
    const operationId = typeof operation?.operationId === 'string' ? operation.operationId : null;
    if (!operation || !operationId || !uuid.test(operationId) || typeof operation.businessId !== 'string' || !uuid.test(operation.businessId) || typeof operation.entityType !== 'string' || typeof operation.entityId !== 'string' || !uuid.test(operation.entityId) || typeof operation.operationType !== 'string' || typeof operation.occurredAt !== 'string' || !operation.payload || typeof operation.payload !== 'object') {
      failed.push({ operationId, reason: 'Invalid operation envelope.' }); continue;
    }
    const { data, error } = await admin.rpc('apply_sync_operation', { p_owner_id: userData.user.id, p_device_id: body.deviceId, p_operation: operation });
    if (!error && data?.acknowledged === true) acknowledgedOperationIds.push(operationId);
    else if (error?.code === '40001') conflicts.push({ operationId, reason: error.message });
    else failed.push({ operationId, reason: (data && typeof data === 'object' && typeof (data as any).reason === 'string') ? (data as any).reason : (error?.message ? `${error.code ? `[${error.code}] ` : ''}${error.message}` : 'Operation was not applied.') });
  }
  return reply({ acknowledgedOperationIds, conflicts, failed });
});
