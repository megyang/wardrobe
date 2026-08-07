# Wearwell hosted beta deployment

Use separate Supabase and OpenAI projects for staging and production. The iOS app receives only the Wearwell API URL, Supabase URL, and public anonymous key. `OPENAI_API_KEY`, `DATABASE_URL`, and `SUPABASE_SERVICE_ROLE_KEY` belong only in the managed API/worker secret store.

## Accounts you must create

1. **Supabase:** one staging project initially. It provides Auth, Postgres, and the private image bucket.
2. **OpenAI Platform:** one staging project and project API key. Set usage notifications in the OpenAI dashboard; Wearwell also applies per-user quotas and a database-backed global budget/kill switch.
3. **Render:** connect this repository and deploy the checked-in Blueprint. Equivalent managed Node web/worker services are acceptable.
4. **Apple Developer:** required before real-device Sign in with Apple or TestFlight distribution. Email magic links can be used during early simulator development.

Never paste a secret into Swift, an xcconfig, `Info.plist`, Git, logs, or a backup.

## Local database verification

Docker is already required. Install the Supabase CLI using its current official instructions, then run:

```sh
supabase start --workdir Backend
supabase db reset --workdir Backend
```

Copy the local URL, anonymous key, service-role key, and database URL printed by the CLI into an ignored `Backend/.env`. Add a development OpenAI project key only if exercising real AI jobs. Start `npm start` and `npm run worker` from `Backend` in separate terminals.

## Create staging

1. Create an empty Supabase staging project and note its project reference.
2. From the repository root, authenticate and preview the migrations before applying them:

```sh
supabase login
supabase link --workdir Backend --project-ref YOUR_STAGING_PROJECT_REF
supabase db push --workdir Backend --dry-run
supabase db push --workdir Backend
```

3. In Supabase Auth, allow `wearwell://auth-callback`. Configure email magic links. Configure the Apple provider and app capability before testing native Apple sign-in.
4. Deploy `render.yaml` as a Render Blueprint. Enter these values in the Render dashboard when prompted:
   - `DATABASE_URL`
   - `SUPABASE_URL`
   - `SUPABASE_ANON_KEY`
   - `SUPABASE_SERVICE_ROLE_KEY`
   - `OPENAI_API_KEY`
5. Set the three public staging values in an untracked `Config/Hosted.local.xcconfig`: the Render API URL, Supabase URL, and public anonymous key.
6. Create beta access without storing the plaintext code in the database:

```sh
cd Backend
DATABASE_URL='YOUR_STAGING_DATABASE_URL' npm run admin -- invite BETA-FRIENDS 10 30
```

7. Set the application-wide AI ceiling and confirm the kill switch:

```sh
DATABASE_URL='YOUR_STAGING_DATABASE_URL' npm run admin -- budget 50
DATABASE_URL='YOUR_STAGING_DATABASE_URL' npm run admin -- ai on
```

8. Activate two independent staging accounts, then run `npm run test:staging` with `STAGING_API_URL`, `STAGING_USER_A_TOKEN`, and `STAGING_USER_B_TOKEN`.

## Release gates

- Node tests and syntax checks pass.
- Unsigned simulator build succeeds.
- Migrations replay from an empty local database.
- Two-account isolation and private-sharing smoke test passes.
- API and worker logs are searchable by request ID/job ID.
- Database backups and account deletion are tested.
- OpenAI usage alerts, per-user quotas, the global budget, and the emergency AI-off command are verified.
- Privacy policy explains private assets, explicit sharing, retention, and deletion.

Do not run `supabase db reset --linked` against production. Use a separate production project and apply reviewed forward-only migrations after staging passes.
