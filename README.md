# The Frame Drop — operations app

Website for running TFD: inventory, shows, packing, payroll. What it does is defined in the
**TFD Build Spec**; how Claude operates it is in the **TFD Claude Operator Manual**.

## How it's put together

| Part | Where | What it holds |
| --- | --- | --- |
| Website (`public/`) | Netlify | The screens everyone uses |
| Server functions (`netlify/functions/`) | Netlify | Creating logins and changing passwords (needs the secret key) |
| Database (`supabase/migrations/`) | Supabase | All data, plus every rule and permission check |

Every table is locked. The website can only call the `tfd_*` database functions, and each one checks
who is signed in and logs the change, so a role's limits hold even if someone pokes at the website.

## One-time setup

1. **Supabase → SQL Editor → New query**: paste all of `supabase/migrations/0001_phase1.sql` and click **Run**.
2. **Supabase → Authentication → Sign In / Providers → Email**: turn **off** "Allow new users to sign up".
   Only admins add people, from Settings → People.
3. **Netlify → Add new project → Import an existing project → GitHub**: pick this repository (build
   settings come from `netlify.toml`), then add three **Environment variables** (values from
   Supabase → Project Settings → API Keys):
   - `SUPABASE_URL` — the project URL
   - `SUPABASE_ANON_KEY` — the publishable (or anon) key
   - `SUPABASE_SERVICE_ROLE_KEY` — the secret (or service_role) key. Never share this one.
4. Deploy, open the site, and create the first admin.

Staff sign in with a **username**; admins can use an email.

## Tests (run by Claude before every change)

- Database: `supabase/test/test_phase1.sql` on a throwaway Postgres (with `supabase/test/supabase_stub.sql`).
- End to end: `supabase/test/fake_supabase.js` runs the website against a local stand-in for Supabase.
