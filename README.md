# Bhat Network

Bhat Network is a vehicle-owner and workshop service-history app. The static frontend is [index.html](index.html), hosted at [GitHub Pages](https://aathir-hussain-bhat.github.io/Bhat-network.cue/).

## Backend

The app connects to the fresh Supabase project `hmbpikrgbgtgdmciwmpz` in `ap-south-1` using a browser-safe publishable key. Never put a service-role or secret key in frontend code.

The [initial migration](supabase/migrations/20261118100000_initial_schema.sql) defines the tables, policies, functions, triggers and storage configuration. It has already been applied to the project; use new timestamped migrations for future changes. No legacy records were imported.

## First admin

No initial admin was assigned. After creating and confirming the owner's app account, replace the placeholder in [bootstrap-admin.sql](supabase/bootstrap-admin.sql) with that account's email and run it once in the project's SQL editor. It should update exactly one profile.

## Authentication

Configure Supabase Auth's Site URL and redirect allowlist for the GitHub Pages URL, and test the confirmation-email redirect before relying on sign-up.
