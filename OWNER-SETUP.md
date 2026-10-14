# TEC Masala Business — Owner Setup

## Database target
The rebuild branch is connected to the Supabase project named Amol9219's Project (project ref: isypmwpmqqcopgcmenqz). The older Supabase project named TEC-MASALA was not changed. The legacy Egg Corner Firebase database was not changed.

## First Owner account (required before app login)
The app intentionally has no default PIN/password and no public sign-up form.

1. Open the Supabase dashboard for project isypmwpmqqcopgcmenqz.
2. Go to Authentication → Users → Add user and create the Owner account using the Owner's email and a strong password. Do not put passwords in GitHub or this file.
3. Copy the new Auth user's UUID.
4. Open SQL Editor and run the following after replacing the two clearly marked placeholders:

```sql
insert into public.profiles (id, full_name, role, is_active)
values (
  'REPLACE_WITH_AUTH_USER_UUID'::uuid,
  'REPLACE_WITH_OWNER_DISPLAY_NAME',
  'owner',
  true
);
```

5. Sign in at the deployed app using that email/password. If the app has not yet been deployed, use a local/static preview of index.html.

The Auth user must exist before inserting the profile because profiles.id references auth.users.id. Keep the UUID as the exact Auth user ID. Never create an Owner profile for an unrelated UUID.

## Create Co-Owner and Outlet users
Create each user in Supabase Authentication first, then add a matching public.profiles row. Use role co_owner for the Co-Owner. Use role outlet and set outlet_id to that outlet's UUID for an Outlet login. Do not grant Owner role to operational users.

## Security and scope
- Browser code contains only the Supabase publishable key. Never place the service_role or secret key in browser code.
- RLS is enabled on application tables. Raw material and supplier cost-sensitive tables are Owner-only at the database policy layer.
- Enable Supabase Auth's leaked-password protection in Authentication → Settings → Password Security.
- The app login currently uses email/password. Username-only sign-in can be added later with a secure server-side username-to-account lookup; do not implement it by storing passwords or a password mapping table.
- The foundation does not yet implement all business workflows. Stock, production, approvals, finalized bills, payment reconciliation, immutable audit events, backups and report calculations need their planned follow-up stages and tests before production use.
