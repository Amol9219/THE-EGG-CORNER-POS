# TEC Masala Business — Rebuild Blueprint

This branch is the safe rebuild workspace for converting THE-EGG-CORNER-POS into TEC Masala Business.

## Safety rules
- Keep the existing `main` branch and current Firebase-backed Egg Corner POS unchanged while the rebuild is in progress.
- Do not delete, overwrite, or migrate any existing Firebase/Supabase data as part of setup.
- Use a separately confirmed database target for TEC Masala Business before applying schema changes.
- Never put service-role keys or other server secrets in browser code.
- Enforce role permissions in the backend with database policies, not only by hiding UI.

## Product identity and experience
- Product name: TEC Masala Business
- Responsive web app/PWA for phone and desktop
- Theme: dark red, orange, white
- Marathi and English-friendly labels
- Role-aware navigation and in-app notifications

## Roles
- Owner: full access, user management, business settings, stock adjustments, approvals, reports, backup/restore.
- Co-Owner: only explicitly allowed operational pages and monthly partnership P/L summary; no confidential sales, invoices, supplier costs, raw-material costs, cost prices, or detailed margins.
- Outlet: only its own products/prices, orders, bills, delivery status, payment status, and return/complaint requests.

## Main modules
1. Dashboard and notifications
2. Raw-material and finished-goods stock, batches/FIFO, low-stock alerts, stock history
3. Production recipes/BOM and actual consumption
4. Products, photos, packaging, outlet-specific prices
5. Outlet orders and delivery confirmation
6. Suppliers, purchase orders, goods receipt, quality inspection
7. Bills, payments, outstanding balances, payment-proof review
8. Returns, damage, supplier credit notes
9. Owner and Co-Owner reports with strict data separation
10. User activity/audit log
11. Settings, cloud backup and guarded restore
12. Safe offline viewing and conflict-safe online sync

## Business rules
- Keep immutable histories for bills, price changes, stock adjustments, transfers, supplier rates, approvals and audit events.
- Corrections use reversals/adjustment records; do not silently rewrite finalized financial records.
- Stock increases only after accepted receipt/approved adjustment; production consumes raw materials and increases finished goods.
- Partial receipt and partial payments are supported.
- Outlet complaints do not change stock or bills until Owner approval.
- Invoice numbers: `TMB/YYYY/0001`; purchase orders: `TPO/YYYY/0001`; serials must not be reused.
- Use batch/lot tracking and expiry handling where applicable.
- Avoid destructive restore or database operations without a preview and explicit final confirmation.

## Implementation sequence
1. Confirm separate database target and configuration; design auth, roles, RLS and audit foundations.
2. Build app shell, responsive dashboard, navigation, login and role enforcement.
3. Implement stock, products, production and outlet pricing.
4. Implement outlet orders, suppliers, purchase orders, receipts and quality checks.
5. Implement bills, payments, returns, reports, notifications and audit history.
6. Add backup/restore safeguards, offline-read support and conflict-safe sync.
7. Test role isolation, stock/financial invariants, mobile layout and deployment.

## Current starting point
The original repository is a single `index.html` application using Firebase Realtime Database SDK v8. The TEC Masala rebuild must replace the restaurant/table/waiter/kitchen workflow rather than merely rename its title. Existing Firebase configuration/data must remain untouched until a deliberate migration plan is approved.
