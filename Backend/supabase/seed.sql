-- Local development only. The matching auth user is created by Supabase test helpers.
insert into public.invite_codes(code_hash,label,max_uses,expires_at)
values(digest(lower('WEARWELL-LOCAL'),'sha256'),'Local development',100,now()+interval '10 years')
on conflict(code_hash) do nothing;
