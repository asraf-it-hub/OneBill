# OneBill cloud synchronization contract

## Purpose

The cloud service supports authentication, recovery, backup, and background synchronization. It must never be required for a local business action to succeed. SQLite/Drift commits every operation first; cloud work is queued in `SyncOperations`.

## Target service

Supabase Auth plus PostgreSQL with Row Level Security. The eventual Flutter configuration is supplied only at build time or through secure app configuration:

```text
ONEBILL_SUPABASE_URL
ONEBILL_SUPABASE_PUBLISHABLE_KEY
```

No service-role key belongs in the Android application.

For local development, run the app with:

```text
flutter run --dart-define-from-file=tool/supabase.dev.json
```

## Operation endpoint behavior

The server accepts one or more operations from the local sync queue. For each operation it must:

1. Authenticate the account.
2. Verify that the account owns `businessId`.
3. Validate the event payload by type.
4. Apply the full entity snapshot through the transactional `apply_sync_operation` RPC.
5. Insert a receipt using the stable operation ID in the same PostgreSQL transaction.
6. Treat an existing identical receipt as an acknowledged retry, not a second mutation.
7. Reject payload conflicts and stale `expectedVersion` updates.
8. Return acknowledgements and per-operation failure/conflict information without deleting local data.

Financial events are append-only: `InvoiceCreated`, `PaymentRecorded`, `IncomeRecorded`, and `ExpenseRecorded` must not be silently overwritten.

Mutation payloads contain full snapshots. Mutable updates and archive operations include `expectedVersion`; the server increments the row version only after a compare-and-swap succeeds. `InvoiceCreated` includes the invoice and its item array. `PaymentRecorded` inserts the payment and increments `paid_paise` while holding the invoice row lock.

## Deployment prerequisites

1. Create or connect a Supabase project owned by the OneBill team.
2. Apply `supabase/migrations/202608250001_onebill_sync.sql`.
3. Deploy an authenticated sync endpoint/RPC that enforces the contract above.
4. Provide only the project URL and anon key to the Android build configuration.
