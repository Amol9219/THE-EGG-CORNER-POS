# TEC Masala Business — Owner Setup & Current Scope

## Database and deployment

- Supabase project: `isypmwpmqqcopgcmenqz` (“Amol9219’s Project”).
- GitHub branch: `tec-masala-business-rebuild`.
- Production URL currently configured: https://tec-masala-business.vercel.app/
- The feature branch produces Vercel Preview deployments. Test the latest Preview before promoting the changes to production.
- The browser contains only the Supabase publishable key. Never add a `service_role` key or password to `index.html`, GitHub, or this file.

## Owner account setup

The app has no default password and no public sign-up form.

1. Create the user in Supabase Authentication → Users using the owner's email and a strong password.
2. Copy that Auth user's exact UUID.
3. If the owner profile is not already present, run this in SQL Editor after replacing the placeholders:

```sql
insert into public.profiles (id, full_name, role, is_active)
values (
  'REPLACE_WITH_AUTH_USER_UUID'::uuid,
  'REPLACE_WITH_OWNER_DISPLAY_NAME',
  'owner',
  true
);
```

The Auth user must exist before the profile because `profiles.id` references `auth.users.id`. Do not create a profile for an unrelated UUID.

## Recommended first-time setup

1. Sign in as Owner and open **Settings**. Save the business name, address, mobile number and (if applicable) GSTIN. These fields are printed on newly issued bills; editing the profile does not rewrite old bills.
2. Add active raw materials and finished products in **Raw Materials** and **Products & Prices**. Set the correct unit consistently (for example, kg, g or packet).
3. Add each outlet's selling price for each relevant product under **Products & Prices → Outlet-wise Selling Prices**. Outlet order creation is blocked if there is not exactly one active price for a product/outlet pair.
4. Add suppliers and their latest rates in **Suppliers & Purchases**.
5. Enter actual stock through a tracked workflow rather than typing an opening quantity into the product/material form. New catalogue items start at zero stock. To register purchased stock, create a Purchase Order, submit it, approve it, record a Goods Receipt and then inspect/accept it. Accepted receipts create batches and stock movements.
6. For manufactured products, create a Recipe/BOM in **Production**. Completing a production batch consumes accepted, non-expired raw-material batches in FIFO order and creates a finished-goods batch.
7. Create an Outlet Order, submit and confirm it, then dispatch it. Dispatch is rejected if available product stock or accepted, non-expired batches are insufficient. Mark it delivered before issuing the bill.
8. Record payments in **Bills & Payments**. They remain pending until Owner approval. Approving an outlet receipt updates the bill's paid balance; excess payment is rejected. Bills can be printed from the bill register.
9. Outlet users can request a return against a bill. The Owner inspects each line. Stock is increased only after receiving a return and only for items marked good and approved for restocking.

## Current workflow coverage

- Owner sign-in, profile/role enforcement and row-level database policies.
- Product and raw-material catalogue; per-outlet selling prices; supplier contacts and rate history.
- Purchase-order creation, submit/approve/cancel transitions, receipt recording and accept/reject inspection.
- Recipe/BOM create/edit; production batch completion and ingredient consumption.
- Outlet-order submit/confirm/dispatch/deliver/cancel; FIFO batch deduction during dispatch.
- Bill issuance from delivered orders, printable invoice, payment ledger and Owner approval.
- Bill-linked returns with per-line inspection and controlled restocking.
- Business profile settings, notification read status, read-only user directory, Reports and an audit-log viewer.

## Known limitations — do not treat this as fully production-ready

- GST/tax calculation, tax invoice compliance and statutory validation are not implemented. GSTIN is currently stored/displayed as business information only.
- Supplier payments/advances/refunds are recorded in the payment ledger, but full supplier-invoice matching and accounts-payable reconciliation are not implemented.
- Return inspection currently supports whole-request approval/rejection; line-wise partial acceptance is not implemented.
- Reports use the latest up to 100 bills and up to 100 orders, without complete accounting-period filters or export.
- Audit logging is not yet wired into every action. The Activity Log is not a complete, immutable system-wide audit record.
- Automated backup/restore, retention procedures, monitoring/alerting, independent two-person approvals and comprehensive end-to-end tests still need to be finished.
- The current operational pages have not all been tested against representative real business data. Test with a small, correct dataset before using these workflows for real transactions.

## Security follow-up

- Supabase's Security Advisor reported that **Leaked Password Protection is disabled**. Enable it in Authentication → Settings → Password Security.
- Keep the publishable key in client code only; never use a `service_role` or secret key in the browser.
- SQL workflow functions use `SECURITY INVOKER`, check the authenticated user/Owner role where required, and restrict anonymous execution. Row-level security remains enabled on the application tables.

## Database migration files

The feature branch tracks the applied workflow migrations in `supabase/migrations/`, including:

- `tec_masala_business_foundation`
- `tec_procurement_receipt_workflows`
- `tec_purchase_order_transitions`
- `tec_order_billing_payment_workflows`
- `tec_production_recipes_and_completion`
- `tec_returns_review_and_restock`
- Production costing, return-input and receipt/product-status guard migrations
- `tec_business_settings`

Keep the migration files in version control alongside the app. Changes to database functions should be reviewed and tested before the Production release.
