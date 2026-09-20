# OneBill — Comprehensive Project Handover & Architecture Document

> **Confidential & Proprietary**: OneBill (Modern Offline-First Billing & Business Platform)  
> **Handover Date**: September 2026  
> **Application ID / Android Namespace**: `com.onebill.app`  

---

## 1. Project Overview & Mission

**OneBill** is a modern, offline-first billing, invoicing, and business management application designed for Indian small-to-medium businesses (retailers, service providers, wholesalers, and freelancers).

### Core Architectural Philosophy:
1. **Offline-First & Local-Master**:
   - Every operation (creating customer, drafting bill, recording payment, adding expense/product/supplier) commits **immediately and unconditionally** to the local SQLite database (`AppDatabase` via **Drift**).
   - The application **never** blocks user actions waiting for internet or cloud responses.
2. **Asynchronous Background Synchronization**:
   - Every local mutation generates a queued record in the `sync_operations` table.
   - When network connectivity is present, `SyncWorker` streams batched operations to **Supabase** via PostgreSQL RPCs (`apply_sync_operation`).
3. **Multi-Business Isolation**:
   - Multiple businesses can be owned and managed by the same logged-in account.
   - All data (customers, products, invoices, payments, expenses, suppliers, activity) is strictly scoped by `business_id`.
4. **Clean, Premium UX & Trilingual Localization**:
   - Exclusively supports **English (`en`)**, **Hindi (`hi`)**, and **Telugu (`te`)**.
   - Zero UI text overflows, consistent high-contrast typography, and intuitive linear action sheets.

---

## 2. Technology Stack & Key Dependencies

- **Framework**: Flutter (Dart 3.x, target SDK 37, compile SDK 37, Java 17)
- **Local Persistence**: `drift` / `drift_flutter` with SQLite
- **Cloud Backend**: Supabase (PostgreSQL 15+, Row-Level Security, Auth, RPCs)
- **State Management**: `flutter_riverpod` (v2.x)
- **Local Notifications**: `flutter_local_notifications` + `timezone`
- **PDF Generation & Printing**: `pdf` (v3.11+) and `printing` (v5.13+)
- **File Sharing**: `share_plus`
- **Local Authentication & Security**: `local_auth` and custom PIN-lock service

---

## 3. Directory & Codebase Structure

```text
lib/
├── app/
│   ├── app.dart                   <-- Main UI orchestration, tabs, sheets, dialogs
│   └── theme/app_theme.dart       <-- Colors, material typography, dark/light themes
├── core/
│   ├── config/app_environment.dart<-- Supabase URLs & publishable keys
│   ├── database/app_database.dart <-- Drift schema, tables, DAOs
│   └── localization/
│       └── app_localizations.dart <-- Central tr() translation dictionary (en, hi, te)
├── features/
│   ├── auth/                      <-- SupabaseAuthService, session management
│   ├── backup/                    <-- Local JSON export & restore
│   ├── business/ & businesses/    <-- BusinessProfileScreen, repository, multi-tenancy
│   ├── customers/                 <-- Customer repository, outstanding balance queries
│   ├── expenses/                  <-- Expense recording, category tracking
│   ├── income/                    <-- Income tracking (customer vs owner-added)
│   ├── inventory/                 <-- Product catalog, stock tracking, adjustments
│   ├── invoices/                  <-- Invoicing engine, itemized calculations, PDF service
│   ├── notifications/             <-- 5 Android channels, alarm scheduling, in-app center
│   ├── security/                  <-- PIN lock, biometric security service
│   ├── suppliers/                 <-- Supplier catalog, payments, balance tracking
│   └── sync/                      <-- SyncWorker, sync queue UI, snapshot restorer
supabase/
└── migrations/                    <-- PostgreSQL DDL & RPC sync scripts
    ├── 202608250001_onebill_sync.sql
    ├── 202608280001_onebill_entities_and_sync_rpc.sql
    ├── 202609030001_cloud_language_support.sql
    ├── 202609080001_idempotent_sync_and_fixes.sql
    ├── 202609090001_business_profile_cloud_sync.sql
    └── 202609100001_sync_ownership_and_restore_fix.sql  <-- LATEST CRITICAL MIGRATION
```

---

## 4. Completed & Stable Features ("DO NOT DISTURB" List)

The following features have been completely built, hardened, verified with tests, and tested on a physical Android device. **Future agents must preserve these implementations without regression:**

### A. Strict 3-Language System (English, Hindi, Telugu)
- **CRITICAL INVARIANT**: Tamil (`ta`) and Kannada (`kn`) were **intentionally removed** by user request. Do not re-add them.
- All 13 core areas dynamically translate with `tr(context, key)`:
  1. Settings page (branding, notifications, app security, sync queue, offline-first tagline)
  2. Dashboard (Billed, Received, Collection rate, Outstanding, Invoices, Overdue, Active customers)
  3. Customers page (Search bar, empty states, `#INV... • Total ₹X • Due ₹Y`)
  4. Floating Action Buttons everywhere (`Add customer`, `Add income`, `Add expense`, `Add product`, `Add supplier`)
  5. Income page (tabs: `All`, `Customer`, `Owner Added`, metrics, search)
  6. Expense page (`This month`, `Total`, search, context menus, delete confirmation)
  7. Notifications page (Master control, quiet hours, category switches, in-app center)
  8. Business Profile screen (Basic info, Contact/Address, Tax & Payment, Branding & Media, Policies, Danger zone)
  9. Inventory page (Low stock alert, product editor, stock adjustment, delete confirmation)
  10. Recycle bin (Empty states, restore button, snackbars)
  11. Recent activity page (Timeline, synced/pending statuses)
  12. Reports page (`Collections`, `₹X collected of ₹Y billed` progress string, `Invoices issued`, `Overdue invoices`)
  13. Sign-out flow (Warning dialog with offline data preservation assurance)

### B. Invoicing Engine & Bill Sheet UI
- **Linear Action Button Stack**: Replaced cramped horizontal action rows with full-width, clean vertical buttons:
  - `Record Payment` (if balance > 0)
  - `PDF / Preview`
  - `Share Invoice`
  - `Edit Invoice` (unpaid only)
  - `Void Invoice` (unpaid only, distinct red accent)
- **Detailed Financial Breakdown**: Shows `Subtotal`, `Discount`, `Interest`, `Total`, `Grand Total`, `Paid`, and `Balance`.
- **Items & Payment History**: Fully itemized with quantities and rates, along with timestamped payment history records.

### C. PDF Invoice Generation & Sharing
- Located in `lib/features/invoices/services/pdf_invoice_service.dart`.
- **Branding**: Top-right corner displays the official **OneBill Logo** (`OneBillLogo.png`) and **"Powered by OneBill"** in bold typography.
- **Footer**: Bottom footer cleanly features centered **"Thank you for your business."**.
- **Sharing**: Integrates with `SharePlus` to output professionally named PDF files (`BusinessName_CustomerName_InvoiceNumber.pdf`).

### D. Offline-First Sync & Idempotency
- Located in `lib/features/sync/data/sync_worker.dart`.
- Appends mutations to `sync_operations`.
- Uses deterministic operation IDs (`receipts` in Supabase) to prevent duplicate transactions on retries.
- Newly created invoices auto-trigger immediate sync in the background.

### E. Mandatory Validation in Add Expense
- Located in `_ExpenseEditor` in `lib/app/app.dart`.
- Both **Amount (₹)** and **Category** are strictly mandatory.
- Omitting them triggers:
  1. Red inline `errorText` under the input fields.
  2. An external, floating high-contrast red SnackBar alert:
     - *EN*: `"Please fill all mandatory fields (Amount and Category)."`
     - *HI*: `"कृपया सभी अनिवार्य फ़ील्ड (राशि और श्रेणी) भरें।"`
     - *TE*: `"దయచేసి అన్ని తప్పనిసరి ఫీల్డ్‌లను (మొత్తం మరియు వర్గం) పూరించండి."`

### F. Notification Subsystem
- Located in `lib/features/notifications/data/notification_service.dart`.
- 5 native Android channels (`reminders`, `payments`, `summaries`, `sync`, `alerts`).
- Offline pre-due reminders (7 days before, 1 day before, day of due date at 9:00 AM).
- Post-due overdue reminders (1 day, 3 days, 7 days overdue).
- Automatic cancellation of reminders when invoice balance reaches ₹0.
- Native "Remind me later" action snooze to 9:00 AM next day.
- Quiet hours protection (delays notifications until quiet hours conclude).

---

## 5. Critical Database Invariant & Pending SQL Migration

### The Issue Identified & Resolved:
- In Supabase, the initial `businesses` table only had basic columns (`name`, `owner_name`, `phone`, `email`, `address`, `upi_id`).
- Extended profile fields (`website`, `tagline`, `gstin`, `upi_name`, `invoice_notes`, `terms_and_conditions`, `logo_image`, `payment_qr_image`) were added to the client code, but PostgreSQL would throw `undefined_column` on cloud sync and fall back to saving only `address` and `upi_id`.
- Additionally, `invoice_items` was missing the `business_id` column in cloud Supabase, which caused invoice syncs to fail with `"Operation was not applied"`.

### The Master Fix Migration:
The comprehensive fix is located in:
[`supabase/migrations/202609100001_sync_ownership_and_restore_fix.sql`](file:///c:/Projects/OneBill/supabase/migrations/202609100001_sync_ownership_and_restore_fix.sql).

> [!IMPORTANT]
> **Action For Supabase**:
> If not already run in the Supabase Dashboard, open **Supabase Dashboard -> SQL Editor** and execute `202609100001_sync_ownership_and_restore_fix.sql`. It adds the 8 missing columns, relaxes restrictive foreign keys safely, and installs the resilient `apply_sync_operation` and `get_sync_snapshot` RPCs.

---

## 6. Build, Testing, and Deployment Instructions

### Automated Tests:
Run all project unit and widget tests:
```powershell
flutter test
```
*(All 22 core tests must always pass).*

### Local Development Run:
```powershell
flutter run --dart-define-from-file=tool/supabase.dev.json
```

### Production Release Build:
To build split-per-ABI release APKs (smaller file sizes, fast install):
```powershell
flutter build apk --release --split-per-abi
```
Generated APK outputs:
- **ARM 64-bit (Modern phones)**: `build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`
- **ARM 32-bit (Older phones)**: `build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk`
- **x86_64 (Emulators/Tablets)**: `build/app/outputs/flutter-apk/app-x86_64-release.apk`

### Installing onto Connected Phone:
Using the Android SDK platform-tools on this machine:
```powershell
& "C:\Users\asraf\AppData\Local\Android\Sdk\platform-tools\adb.exe" install -r build\app\outputs\flutter-apk\app-arm64-v8a-release.apk
```
Launch command:
```powershell
& "C:\Users\asraf\AppData\Local\Android\Sdk\platform-tools\adb.exe" shell am start -n com.onebill.app/com.onebill.app.MainActivity
```

---

## 7. Next Prospective Roadmap & Recommended Enhancements

For future development phases, the following items are natural next extensions:
1. **Bluetooth Thermal Receipt Printing**:
   - Add support for 58mm / 80mm ESC/POS thermal printers via Bluetooth for fast POS counter receipts.
2. **Bulk Inventory Import / Export (Excel / CSV)**:
   - Allow shop owners to import product lists from CSV or Excel spreadsheets.
3. **SMS / WhatsApp Direct Message Templates**:
   - Provide pre-formatted WhatsApp payment reminder messages with deep UPI payment links.
4. **Enhanced Analytics**:
   - Monthly profit/loss breakdown (Revenue minus Expenses and Cost of Goods Sold).
