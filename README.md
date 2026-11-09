# Adi web app

Adi as a normal website people can open on their phone, sign up with email, and add to the home screen like an app. It costs ₹0 on the free plans of Supabase (accounts, data, photos) and Cloudflare Pages (hosting).

## 1. Supabase (database and sign-in)
1. At supabase.com, create a free project. Pick the Mumbai region.
2. Open **SQL Editor > New query**, paste all of `supabase/core.sql`, and press **Run**. It creates the tables, the privacy rules and the photo storage. Run `supabase/demo.sql` too if you want the 6 demo accounts. (`schema.sql` is both in one file.) Safe to run again later.
3. Open **Authentication > Sign In / Providers > Email** and turn **Confirm email** off. (Supabase's free email sending allows only a few emails an hour, so new people would get stuck waiting.)
4. Open **Authentication > URL Configuration** and set **Site URL** to your Cloudflare address once you have it (step 2).
5. Open **Project Settings > API Keys > Legacy API Keys** and copy the **Project URL** and the **anon public** key into `public/config.js`. Never use the service_role key anywhere.

## 2. Cloudflare (hosting)
At dash.cloudflare.com: **Workers & Pages > Create > Import a repository**, pick this repository, keep the defaults and deploy. `wrangler.jsonc` tells Cloudflare to serve the `public` folder. Every push to `main` updates the live site.

## Who is admin
The first account that signs in becomes the admin (can post brand gigs and read tester feedback). Sign up yourself first.

## What works differently from the claude.ai prototype
- Accounts are email + password. Name and profile photo are set inside Adi.
- Chats are private: only the people in a chat can read it (enforced by the database rules).
- "Write a caption for me" and Translate are hidden for now, because they used Claude inside claude.ai.
- Money is still a preview. No real payments.

## Files (in `public/`)
- `index.html` the app
- `adi-shim.js` connects the app to Supabase and shows the sign-in screen
- `config.js` your Supabase project details
- `supabase.js` the Supabase library (v2.45.4)
- `manifest.webmanifest`, `sw.js`, `icons/` make it installable
- `demo-media/`, `demo-media.js` photos for the demo accounts

- `supabase/` (repo root) database setup scripts
