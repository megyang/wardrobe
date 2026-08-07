alter table public.profiles
  add column if not exists display_name text,
  add column if not exists avatar_asset_id uuid references public.assets(id) on delete set null;

create table public.friend_invites (
  id uuid primary key default gen_random_uuid(),
  inviter_id uuid not null references public.profiles(id) on delete cascade,
  token_hash bytea not null unique,
  expires_at timestamptz not null,
  redeemed_by uuid references public.profiles(id) on delete set null,
  redeemed_at timestamptz,
  revoked_at timestamptz,
  created_at timestamptz not null default now()
);
create index friend_invites_inviter on public.friend_invites(inviter_id, created_at desc);

create table public.friendships (
  user_low uuid not null references public.profiles(id) on delete cascade,
  user_high uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key(user_low, user_high),
  check(user_low < user_high)
);
create index friendships_high on public.friendships(user_high, created_at desc);

create table public.blocks (
  blocker_id uuid not null references public.profiles(id) on delete cascade,
  blocked_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key(blocker_id, blocked_id),
  check(blocker_id <> blocked_id)
);
create index blocks_blocked on public.blocks(blocked_id);

create table public.outfit_shares (
  id uuid primary key default gen_random_uuid(),
  sender_id uuid not null references public.profiles(id) on delete cascade,
  recipient_id uuid not null references public.profiles(id) on delete cascade,
  idempotency_key text not null,
  source_outfit_id uuid,
  preview_asset_id uuid not null references public.assets(id) on delete restrict,
  snapshot jsonb not null,
  created_at timestamptz not null default now(),
  revoked_at timestamptz,
  check(sender_id <> recipient_id),
  unique(sender_id,idempotency_key)
);
create index outfit_shares_recipient on public.outfit_shares(recipient_id, created_at desc) where revoked_at is null;
create index outfit_shares_sender on public.outfit_shares(sender_id, created_at desc);

create table public.share_reactions (
  share_id uuid not null references public.outfit_shares(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null default 'heart' check(kind = 'heart'),
  created_at timestamptz not null default now(),
  primary key(share_id, user_id)
);

create table public.share_copies (
  share_id uuid not null references public.outfit_shares(id) on delete cascade,
  recipient_id uuid not null references public.profiles(id) on delete cascade,
  inspiration_id uuid not null,
  asset_id uuid not null references public.assets(id) on delete restrict,
  created_at timestamptz not null default now(),
  primary key(share_id, recipient_id),
  unique(recipient_id, inspiration_id)
);

create table public.activity_events (
  id bigint generated always as identity primary key,
  recipient_id uuid not null references public.profiles(id) on delete cascade,
  actor_id uuid references public.profiles(id) on delete set null,
  kind text not null check(kind in ('friend_accepted','share_received','reaction_received')),
  object_id uuid,
  created_at timestamptz not null default now(),
  read_at timestamptz
);
create index activity_recipient on public.activity_events(recipient_id, id desc);

create table public.service_controls (
  singleton boolean primary key default true check(singleton),
  ai_enabled boolean not null default true,
  monthly_ai_budget_usd numeric(12,2) not null default 100 check(monthly_ai_budget_usd >= 0),
  updated_at timestamptz not null default now()
);
insert into public.service_controls(singleton) values(true) on conflict(singleton) do nothing;

create table public.rate_limit_windows (
  owner_id uuid not null references public.profiles(id) on delete cascade,
  scope text not null,
  window_started_at timestamptz not null,
  request_count integer not null default 0,
  primary key(owner_id, scope)
);

create or replace function public.consume_rate_limit(p_owner uuid, p_scope text, p_limit integer, p_window_seconds integer)
returns boolean language plpgsql security definer set search_path=public as $$
declare current_window public.rate_limit_windows%rowtype;
begin
  insert into rate_limit_windows(owner_id,scope,window_started_at,request_count)
    values(p_owner,p_scope,now(),0) on conflict(owner_id,scope) do nothing;
  select * into current_window from rate_limit_windows where owner_id=p_owner and scope=p_scope for update;
  if current_window.window_started_at + make_interval(secs=>p_window_seconds) <= now() then
    update rate_limit_windows set window_started_at=now(),request_count=1 where owner_id=p_owner and scope=p_scope;
    return true;
  end if;
  if current_window.request_count >= p_limit then return false; end if;
  update rate_limit_windows set request_count=request_count+1 where owner_id=p_owner and scope=p_scope;
  return true;
end $$;

create or replace function public.create_job_with_quota(p_owner uuid,p_kind text,p_key text,p_request jsonb)
returns table(id uuid,kind text,state public.job_state,stage text,created_at timestamptz,updated_at timestamptz) language plpgsql security definer set search_path=public as $$
declare profile profiles%rowtype; used integer; existing jobs%rowtype; controls service_controls%rowtype; global_cost numeric(12,6);
begin
  select * into existing from jobs where owner_id=p_owner and idempotency_key=p_key;
  if existing.id is not null then return query select existing.id,existing.kind,existing.state,existing.stage,existing.created_at,existing.updated_at; return; end if;
  select * into controls from service_controls where singleton=true for update;
  select coalesce(sum(estimated_cost_usd),0) into global_cost from usage_ledger where created_at>=date_trunc('month',now());
  if controls.ai_enabled is not true or global_cost >= controls.monthly_ai_budget_usd then return; end if;
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

do $$ declare table_name text; begin
  foreach table_name in array array['friend_invites','friendships','blocks','outfit_shares','share_reactions','share_copies','activity_events','service_controls','rate_limit_windows'] loop
    execute format('alter table public.%I enable row level security',table_name);
  end loop;
end $$;

create policy friend_invites_participant_select on public.friend_invites for select using(inviter_id=auth.uid() or redeemed_by=auth.uid());
create policy friendships_participant_select on public.friendships for select using(user_low=auth.uid() or user_high=auth.uid());
create policy blocks_participant_select on public.blocks for select using(blocker_id=auth.uid());
create policy shares_participant_select on public.outfit_shares for select using(sender_id=auth.uid() or recipient_id=auth.uid());
create policy reactions_participant_select on public.share_reactions for select using(user_id=auth.uid());
create policy copies_recipient_select on public.share_copies for select using(recipient_id=auth.uid());
create policy activity_recipient_select on public.activity_events for select using(recipient_id=auth.uid());

revoke all on function public.consume_rate_limit(uuid,text,integer,integer) from public,anon,authenticated;
grant execute on function public.consume_rate_limit(uuid,text,integer,integer) to service_role;
