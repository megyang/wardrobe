alter table public.jobs drop constraint jobs_kind_check;
alter table public.jobs add constraint jobs_kind_check
  check (kind in ('analyze','inspiration','style','assess','recommend-item','catalog-edit','render'));

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

revoke all on function public.create_job_with_quota(uuid,text,text,jsonb) from public,anon,authenticated;
grant execute on function public.create_job_with_quota(uuid,text,text,jsonb) to service_role;
