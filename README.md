# Wearwell — hosted multi-user beta

This branch is the cloud-authoritative Wearwell build. The personal Mac-assisted version remains on `codex/local-device`; this branch has no local pairing, Bonjour, device-token, certificate, or Codex-login dependency.

## Architecture

- The iOS app signs users in with Supabase Auth (Sign in with Apple or passwordless email links). Tokens are stored in Keychain.
- The Node API validates every Supabase JWT and requires a redeemed beta invitation before data, assets, or AI jobs are available.
- Postgres stores owner-scoped records, sync tombstones, quotas, durable jobs, usage, and deletion requests. Row Level Security denies cross-user reads by default.
- A private Supabase Storage bucket holds immutable owner-scoped image objects. The phone uses short-lived signed upload and download URLs.
- A Render web service runs `Backend/server.mjs`; a separate durable worker runs `Backend/worker.mjs` and claims Postgres jobs with expiring leases and `FOR UPDATE SKIP LOCKED`.
- The worker uses the official OpenAI JavaScript SDK: Responses API with `gpt-5.6-luna`, medium reasoning, strict schemas, `store: false`, and a hashed user safety identifier; Image API calls use `gpt-image-2`.

SwiftData is an account-scoped offline read cache. Foreground sync pulls the cloud snapshot, validates asset checksums, merges by UUID, then writes the merged snapshot back. Signing out or deleting an account clears records and cached images so another account cannot see them.

## Repository map

- `Backend/` — API, worker, OpenAI workflows, prompt/schema/rule modules, and tests
- `Backend/supabase/migrations/` — checked-in database and RLS schema
- `Backend/supabase/seed.sql` — local invite helper
- `render.yaml` — staging API and worker Blueprint
- `Wearwell/` — iOS app and hosted client
- `Config/Hosted.example.xcconfig` — public iOS environment template

## Security boundaries

`OPENAI_API_KEY`, `DATABASE_URL`, and `SUPABASE_SERVICE_ROLE_KEY` are server secrets. Set them in Render; never put them in the app, an xcconfig, source control, logs, or a backup. The app receives only the public Supabase URL/anon key and the API base URL.

Images are never embedded in job rows. Completed, cancelled, and terminally failed jobs scrub their working request payload. Usage records include tokens, image calls, latency, model version, and an estimated cost based on environment-configured accounting rates.

## Run and verify

See [LOCAL_DEVELOPMENT.md](LOCAL_DEVELOPMENT.md) for local Supabase, API/worker, invite, iOS, and staging instructions.

```sh
cd Backend
npm ci
npm test
npm run check
```

The beta defaults are 25 garment analyses, 50 styling/purchase/inspiration actions, 10 generated-image actions, and 1 GB of private image storage per user per month. Profile columns can be changed administratively without an app release.
