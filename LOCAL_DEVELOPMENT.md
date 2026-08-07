# Hosted Wearwell development

## Prerequisites

- Xcode with an iOS 18+ simulator
- Node.js 22+
- Supabase CLI and Docker for the local stack
- An OpenAI project API key

You create the Supabase and OpenAI accounts only when you are ready to run the hosted service. Code review, unit tests, and the unsigned iOS build do not require real credentials. The OpenAI key is a worker secret and must never be added to the iOS configuration.

## Start the local services

```sh
supabase start --workdir Backend
cp Backend/.env.example Backend/.env
```

Copy the local database URL, API URL, anon key, and service-role key printed by Supabase into `Backend/.env`; add `OPENAI_API_KEY`. Never commit that file.

Apply the checked-in schema and seed helper:

```sh
supabase db reset --workdir Backend
```

In two terminals:

```sh
cd Backend
npm ci
npm start
```

```sh
cd Backend
npm run worker
```

The health endpoint is `http://127.0.0.1:8791/healthz`.

## Configure the iOS app

Debug defaults point the API at `http://127.0.0.1:8791`. Set `WEARWELL_SUPABASE_URL` and `WEARWELL_SUPABASE_ANON_KEY` in the Debug build settings or copy `Config/Hosted.example.xcconfig` to ignored `Config/Hosted.local.xcconfig` and attach it to the desired Xcode configuration.

For email links, configure the Supabase redirect URL as `wearwell://auth-callback`. For Apple sign-in, enable the capability for `com.wearwell.app` in the Apple Developer portal and configure Apple as a Supabase provider.

Create a one-use local invite directly in SQL:

```sql
insert into public.invite_codes(code_hash,label,max_uses,expires_at)
values(digest(lower('BETA-LOCAL'),'sha256'),'Local development',1,now()+interval '30 days');
```

Sign in, then redeem `BETA-LOCAL` in Settings. Authentication succeeds before redemption, but all application API access remains blocked until redemption.

## Tests

```sh
cd Backend
npm test
npm run check
node --check worker.mjs
```

```sh
xcodebuild -project Wearwell.xcodeproj -scheme Wearwell \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/WearwellHostedDerived CODE_SIGNING_ALLOWED=NO build
```

Database integration tests require a running local Supabase stack. Use two users and verify that record reads, jobs, and signed asset URLs cannot cross owner boundaries; exhaust each quota; terminate the worker during a job and confirm lease recovery; and validate backup import plus deletion purge.

After activating two staging beta users, run the checked-in isolation probe:

```sh
STAGING_API_URL=https://wearwell-api-staging.onrender.com \
STAGING_USER_A_TOKEN=... STAGING_USER_B_TOKEN=... npm run test:staging
```

The probe now verifies record and asset isolation plus private friend invitation, sharing, signed preview access, and reactions. See `DEPLOYMENT.md` for the full remote setup sequence and admin commands.

## Staging first

1. Create a staging Supabase project and apply `Backend/supabase/migrations`.
2. Create the private bucket through the migration and configure Apple/email auth redirects.
3. Deploy `render.yaml`; enter server secrets only in Render.
4. Set the three public Release iOS values: API URL, Supabase URL, and anon key.
5. Run two-account isolation, worker restart, quota exhaustion, backup migration, and deletion scenarios before creating production infrastructure.

Cost accounting rates are intentionally environment-controlled because pricing changes. Set `OPENAI_INPUT_COST_PER_MILLION`, `OPENAI_OUTPUT_COST_PER_MILLION`, and `OPENAI_IMAGE_COST_PER_CALL` in Render after checking current pricing.
