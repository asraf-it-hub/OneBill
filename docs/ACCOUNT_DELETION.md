# OneBill Account Deletion Policy & Implementation

## 1. Google Play Console Compliance
- **Requirement**: Google Play Data Safety section mandates an accessible account and data deletion path both within the app and via a public web link.
- **In-App Location**: Settings > Account > Delete Account (located below *Data & Sync*).
- **Public Deletion URL**: `https://asraf-it-hub.github.io/OneBill/docs/account_deletion.html` (or root distribution domain).

---

## 2. Deletion Scope & Architecture

### A. Backend Supabase Cleanup
1. **Edge Function**: `supabase/functions/delete-account/index.ts`
   - Verified via `Authorization: Bearer <user_jwt>`.
   - Derives verified `user.id` from `auth.getUser(token)` (never trusts client-supplied user IDs).
   - Executes atomic database cleanup via `admin_delete_user_account(p_user_id)`.
   - Purges user from Supabase Auth (`admin.auth.admin.deleteUser(userId)`).
2. **PostgreSQL RPC**: `supabase/migrations/202610180001_delete_user_account.sql`
   - Atomically deletes all dependent records respecting foreign-key constraints:
     1. `public.payments`
     2. `public.invoice_items`
     3. `public.invoices`
     4. `public.paper_receipts`
     5. `public.customers`
     6. `public.expenses`
     7. `public.income_entries`
     8. `public.sync_operations`
     9. `public.businesses`
     10. `storage.objects` (if any)
     11. `auth.users`

### B. Local Device SQLite/Drift Cleanup
- Scoped to deleting user: `db.deleteAccountData(accountId)` cleans up all businesses, invoices, customers, payments, income, expenses, paper receipts, sync operations, and local sessions owned by that account.
- Security PIN wiped via `SecurityService.clearPin()`.
- Local notification alarms cancelled via `NotificationService.cancelAll()`.
- Android Credential Manager / Secure Storage tokens expunged.
- Local Supabase session signed out; user routed to `_AuthScreen`.

---

## 3. Trilingual Localization
Every label, warning, dialog, input hint, button, error message, and web form is fully localized in:
1. **English (`en`)**
2. **Hindi (`hi`)**
3. **Telugu (`te`)**

---

## 4. Deployment Instructions
To deploy the backend Edge Function:
```bash
supabase functions deploy delete-account
```
To apply the database migration:
```bash
supabase db push
# or run the SQL in 202610180001_delete_user_account.sql via Supabase Dashboard SQL Editor
```
