# OneBill `/sync` Edge Function

First run `supabase/migrations/202608280001_onebill_entities_and_sync_rpc.sql` in the Supabase SQL Editor. It is additive and creates the entity tables, RLS, version columns, and the transactional `apply_sync_operation` RPC. Then deploy this function from the Supabase Dashboard under **Edge Functions → Create a new function**. Paste the contents of `index.ts` into the function editor and deploy it as `sync`.

The function expects an authenticated `POST` request:

```json
{
  "deviceId": "<uuid>",
  "operations": [
    {
      "operationId": "<uuid>",
      "businessId": "<uuid>",
      "entityType": "customer",
      "entityId": "<uuid>",
      "operationType": "CustomerUpdated",
      "payload": {
        "id": "<uuid>",
        "name": "Ravi Stores",
        "phone": "9876543210",
        "email": null,
        "notes": null,
        "createdAt": "2026-08-28T10:00:00.000Z",
        "updatedAt": "2026-08-28T10:00:00.000Z",
        "deletedAt": null
      },
      "occurredAt": "2026-08-28T10:00:00.000Z"
    }
  ]
}
```

The response contains `acknowledgedOperationIds`, `conflicts`, and per-operation `failed` entries. Each ACK is returned only after `apply_sync_operation` has applied the entity mutation and inserted the immutable receipt in the same PostgreSQL transaction.

The Dashboard automatically supplies `SUPABASE_URL`, `SUPABASE_ANON_KEY`, and `SUPABASE_SERVICE_ROLE_KEY` to Edge Functions. Keep the service-role key in Supabase secrets only.
