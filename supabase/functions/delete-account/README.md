# OneBill Account Deletion Edge Function

Permanently deletes the authenticated user's account and all associated cloud data from Supabase.

## Security
- Requires `Authorization: Bearer <user_jwt>`.
- Caller identity is verified against `auth.getUser(token)` (never trusts client-supplied user IDs).
- Data cleanup and auth deletion are executed with server-side service role privileges in an atomic database transaction.

## Deployment
```bash
supabase functions deploy delete-account
```
