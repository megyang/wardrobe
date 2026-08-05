create extension if not exists pgcrypto;

create type public.profile_status as enum ('pending', 'active', 'suspended', 'deleting');
create type public.job_state as enum ('queued', 'processing', 'complete', 'failed', 'cancelled');

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  status public.profile_status not null default 'pending',
  analysis_limit integer not null default 25 check (analysis_limit >= 0),
  style_limit integer not null default 50 check (style_limit >= 0),
  image_limit integer not null default 10 check (image_limit >= 0),
  storage_limit_bytes bigint not null default 1073741824 check (storage_limit_bytes >= 0),
  revision bigint not null default 1, created_at timestamptz not null default now(), updated_at timestamptz not null default now(), deleted_at timestamptz
);

create table public.invite_codes (
  id uuid primary key default gen_random_uuid(), code_hash bytea not null unique,
  label text not null default '', max_uses integer not null default 1 check (max_uses > 0), uses integer not null default 0,
  expires_at timestamptz, disabled_at timestamptz, created_at timestamptz not null default now()
);

create table public.invite_redemptions (
  invite_id uuid not null references public.invite_codes(id) on delete restrict,
  owner_id uuid primary key references public.profiles(id) on delete cascade,
  redeemed_at timestamptz not null default now()
);

create or replace function public.redeem_invite(p_owner uuid, p_email text, p_code text)
returns table(id uuid, status public.profile_status, email text) language plpgsql security definer set search_path=public as $$
declare selected public.invite_codes%rowtype;
begin
  select * into selected from invite_codes
  where code_hash=digest(lower(trim(p_code)),'sha256') and disabled_at is null
    and (expires_at is null or expires_at>now()) and uses<max_uses for update skip locked;
  if selected.id is null then return; end if;
  insert into profiles(id,email,status) values(p_owner,p_email,'active')
    on conflict(id) do update set email=coalesce(excluded.email,profiles.email),status='active',updated_at=now();
  insert into invite_redemptions(invite_id,owner_id) values(selected.id,p_owner) on conflict(owner_id) do nothing;
  if found then update invite_codes set uses=uses+1 where invite_codes.id=selected.id; end if;
  return query select profiles.id,profiles.status,profiles.email from profiles where profiles.id=p_owner;
end $$;

create table public.assets (
  id uuid primary key, owner_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null, storage_path text not null unique, mime_type text not null,
  byte_count bigint not null check (byte_count between 1 and 18874368), sha256 text not null check (sha256 ~ '^[0-9a-f]{64}$'),
  status text not null check (status in ('uploading','ready','failed')),
  revision bigint not null default 1, created_at timestamptz not null default now(), updated_at timestamptz not null default now(), deleted_at timestamptz
);
create index assets_owner_updated on public.assets(owner_id,updated_at);

create table public.asset_references (
  owner_id uuid not null references public.profiles(id) on delete cascade,
  asset_id uuid not null references public.assets(id) on delete cascade,
  resource text not null, record_id uuid not null, created_at timestamptz not null default now(),
  primary key(owner_id,asset_id,resource,record_id)
);
create index asset_references_asset on public.asset_references(asset_id);

do $$
declare table_name text;
begin
  foreach table_name in array array['garments','wishlist_items','outfits','visualizations','reference_photos','inspiration_looks','style_profiles','import_drafts','style_generations','outfit_feedback','outfit_ratings','outfit_edits'] loop
    execute format('create table public.%I (
      id uuid primary key, owner_id uuid not null references public.profiles(id) on delete cascade,
      revision bigint not null default 1, data jsonb not null default ''{}''::jsonb,
      created_at timestamptz not null default now(), updated_at timestamptz not null default now(), deleted_at timestamptz
    )', table_name);
    execute format('create index %I on public.%I(owner_id,updated_at)', table_name || '_owner_updated', table_name);
  end loop;
end $$;

create table public.jobs (
  id uuid primary key default gen_random_uuid(), owner_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null check (kind in ('analyze','inspiration','style','assess','recommend-item','catalog-edit','render')),
  idempotency_key text not null, state public.job_state not null default 'queued', stage text not null default 'Queued',
  request jsonb not null, result jsonb, usage jsonb, model_version text, prompt_version text not null default 'hosted-v1',
  progress_completed integer, progress_total integer, error_code text, error_message text, latency_ms integer,
  estimated_cost_usd numeric(12,6) not null default 0,
  attempt_count integer not null default 0, available_at timestamptz not null default now(),
  lease_owner text, lease_expires_at timestamptz, cancel_requested_at timestamptz,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  unique(owner_id,idempotency_key)
);
create index jobs_claim on public.jobs(state,available_at,created_at) where state='queued';
create index jobs_owner on public.jobs(owner_id,created_at desc);

create table public.usage_ledger (
  id bigint generated always as identity primary key, owner_id uuid not null references public.profiles(id) on delete cascade,
  job_id uuid not null unique references public.jobs(id) on delete cascade, kind text not null,
  input_tokens bigint not null default 0, output_tokens bigint not null default 0, image_calls integer not null default 0,
  latency_ms integer, model_version text, estimated_cost_usd numeric(12,6) not null default 0,
  created_at timestamptz not null default now()
);
create index usage_owner_month on public.usage_ledger(owner_id,created_at);

create table public.sync_changes (
  sequence bigint generated always as identity primary key, owner_id uuid not null references public.profiles(id) on delete cascade,
  resource text not null, record_id uuid not null, operation text not null check(operation in ('upsert','delete')),
  revision bigint not null, changed_at timestamptz not null default now()
);
create index sync_owner_sequence on public.sync_changes(owner_id,sequence);

create table public.deletion_requests (
  owner_id uuid primary key references public.profiles(id) on delete cascade,
  requested_at timestamptz not null default now(), purge_after timestamptz not null,
  completed_at timestamptz
);

create or replace function public.record_sync_change() returns trigger language plpgsql security definer set search_path=public as $$
begin
  insert into sync_changes(owner_id,resource,record_id,operation,revision)
  values(new.owner_id,tg_argv[0],new.id,case when new.deleted_at is null then 'upsert' else 'delete' end,new.revision);
  return new;
end $$;

do $$
declare item record;
begin
  for item in select * from (values
    ('garments','garments'),('wishlist_items','wishlist'),('outfits','outfits'),('visualizations','visualizations'),
    ('reference_photos','references'),('inspiration_looks','inspiration'),('style_profiles','style-profiles'),
    ('import_drafts','imports'),('style_generations','style-generations'),('outfit_feedback','outfit-feedback'),('outfit_ratings','outfit-ratings'),('outfit_edits','outfit-edits')
  ) as values_table(table_name,resource_name) loop
    execute format('create trigger %I after insert or update on public.%I for each row execute function public.record_sync_change(%L)', 'sync_'||item.table_name,item.table_name,item.resource_name);
  end loop;
end $$;

create or replace function public.create_job_with_quota(p_owner uuid,p_kind text,p_key text,p_request jsonb)
returns table(id uuid,kind text,state public.job_state,stage text,created_at timestamptz,updated_at timestamptz) language plpgsql security definer set search_path=public as $$
declare profile profiles%rowtype; used integer; existing jobs%rowtype;
begin
  select * into existing from jobs where owner_id=p_owner and idempotency_key=p_key;
  if existing.id is not null then return query select existing.id,existing.kind,existing.state,existing.stage,existing.created_at,existing.updated_at; return; end if;
  select * into profile from profiles where profiles.id=p_owner and status='active' for update;
  if profile.id is null then return; end if;
  if p_kind='analyze' then
    select count(*) into used from jobs where owner_id=p_owner and kind='analyze' and created_at>=date_trunc('month',now());
    if used>=profile.analysis_limit then return; end if;
  elsif p_kind in ('style','assess','inspiration','recommend-item') then
    select count(*) into used from jobs where owner_id=p_owner and kind in ('style','assess','inspiration','recommend-item') and created_at>=date_trunc('month',now());
    if used>=profile.style_limit then return; end if;
  else
    select count(*) into used from jobs where owner_id=p_owner and kind in ('catalog-edit','render') and created_at>=date_trunc('month',now());
    if used>=profile.image_limit then return; end if;
  end if;
  insert into jobs(owner_id,kind,idempotency_key,request) values(p_owner,p_kind,p_key,p_request) returning jobs.* into existing;
  return query select existing.id,existing.kind,existing.state,existing.stage,existing.created_at,existing.updated_at;
end $$;

create or replace function public.claim_job(p_worker text,p_lease_seconds integer)
returns setof public.jobs language plpgsql security definer set search_path=public as $$
declare selected uuid;
begin
  update jobs set state='queued',lease_owner=null,lease_expires_at=null,stage='Recovered after worker restart',updated_at=now()
    where state='processing' and lease_expires_at<now() and cancel_requested_at is null;
  update jobs set state='cancelled',stage='Cancelled',lease_owner=null,lease_expires_at=null,updated_at=now()
    where state in ('queued','processing') and cancel_requested_at is not null;
  select id into selected from jobs where state='queued' and available_at<=now() order by created_at for update skip locked limit 1;
  if selected is null then return; end if;
  return query update jobs set state='processing',stage='Processing',attempt_count=attempt_count+1,lease_owner=p_worker,
    lease_expires_at=now()+make_interval(secs=>p_lease_seconds),updated_at=now() where id=selected returning *;
end $$;

create or replace function public.current_usage(p_owner uuid)
returns table(month_start timestamptz,analysis_used bigint,analysis_limit integer,style_used bigint,style_limit integer,image_used bigint,image_limit integer,storage_used bigint,storage_limit bigint)
language sql stable security definer set search_path=public as $$
  select date_trunc('month',now()),
    count(*) filter(where j.kind='analyze'),p.analysis_limit,
    count(*) filter(where j.kind in ('style','assess','inspiration','recommend-item')),p.style_limit,
    count(*) filter(where j.kind in ('catalog-edit','render')),p.image_limit,
    (select coalesce(sum(byte_count),0) from assets where owner_id=p_owner and deleted_at is null),p.storage_limit_bytes
  from profiles p left join jobs j on j.owner_id=p.id and j.created_at>=date_trunc('month',now()) where p.id=p_owner group by p.id;
$$;

create or replace function public.purge_account(p_owner uuid) returns void language plpgsql security definer set search_path=public as $$
begin
  if not exists(select 1 from deletion_requests where owner_id=p_owner and purge_after<=now()) then raise exception 'Account is not ready for purge'; end if;
  delete from auth.users where id=p_owner;
end $$;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('wearwell-assets','wearwell-assets',false,18874368,array['image/jpeg','image/png','image/webp','image/heic'])
on conflict(id) do update set public=false,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;

do $$ declare table_name text; begin
  foreach table_name in array array['profiles','assets','asset_references','garments','wishlist_items','outfits','visualizations','reference_photos','inspiration_looks','style_profiles','import_drafts','style_generations','outfit_feedback','outfit_ratings','outfit_edits','jobs','usage_ledger','sync_changes','deletion_requests'] loop
    execute format('alter table public.%I enable row level security',table_name);
  end loop;
end $$;

create policy profiles_owner_select on public.profiles for select using(id=auth.uid());
create policy assets_owner_all on public.assets for all using(owner_id=auth.uid()) with check(owner_id=auth.uid());
create policy asset_references_owner_select on public.asset_references for select using(owner_id=auth.uid());
do $$ declare table_name text; begin
  foreach table_name in array array['garments','wishlist_items','outfits','visualizations','reference_photos','inspiration_looks','style_profiles','import_drafts','style_generations','outfit_feedback','outfit_ratings','outfit_edits','jobs','usage_ledger','sync_changes','deletion_requests'] loop
    execute format('create policy %I on public.%I for select using(owner_id=auth.uid())','owner_select_'||table_name,table_name);
  end loop;
end $$;

revoke all on function public.redeem_invite(uuid,text,text) from public,anon,authenticated;
revoke all on function public.create_job_with_quota(uuid,text,text,jsonb) from public,anon,authenticated;
revoke all on function public.claim_job(text,integer) from public,anon,authenticated;
revoke all on function public.current_usage(uuid) from public,anon,authenticated;
revoke all on function public.purge_account(uuid) from public,anon,authenticated;
grant execute on function public.redeem_invite(uuid,text,text) to service_role;
grant execute on function public.create_job_with_quota(uuid,text,text,jsonb) to service_role;
grant execute on function public.claim_job(text,integer) to service_role;
grant execute on function public.current_usage(uuid) to service_role;
grant execute on function public.purge_account(uuid) to service_role;

-- Generate invite hashes without storing plaintext, for example:
-- insert into invite_codes(code_hash,label,max_uses,expires_at)
-- values(digest(lower('BETA-EXAMPLE'),'sha256'),'Initial beta',1,now()+interval '30 days');
