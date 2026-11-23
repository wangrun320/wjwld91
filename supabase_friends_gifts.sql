-- 王金武乱斗 V13.7 好友、礼物与羁绊系统
-- 在 Supabase SQL Editor 执行。所有货币扣除和亲密值增加均由数据库事务完成。
create table if not exists public.friend_requests (
  request_id uuid primary key default gen_random_uuid(),
  sender_id uuid not null references auth.users(id) on delete cascade,
  receiver_id uuid not null references auth.users(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending','accepted','declined')),
  created_at timestamptz not null default now(),
  responded_at timestamptz,
  constraint friend_requests_no_self check (sender_id <> receiver_id)
);
create unique index if not exists friend_requests_pending_pair
  on public.friend_requests(sender_id, receiver_id) where status='pending';

create table if not exists public.friend_links (
  user_low uuid not null references auth.users(id) on delete cascade,
  user_high uuid not null references auth.users(id) on delete cascade,
  intimacy integer not null default 0 check (intimacy >= 0),
  bond_requested_by uuid[] not null default '{}',
  bonded_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key(user_low,user_high),
  constraint friend_links_order check (user_low < user_high)
);

create table if not exists public.friend_gift_log (
  gift_id uuid primary key default gen_random_uuid(),
  sender_id uuid not null references auth.users(id) on delete cascade,
  receiver_id uuid not null references auth.users(id) on delete cascade,
  gift_code text not null,
  cost_type text not null check (cost_type in ('coins','gems')),
  cost integer not null check (cost > 0),
  intimacy_gain integer not null check (intimacy_gain > 0),
  created_at timestamptz not null default now(),
  constraint friend_gift_no_self check (sender_id <> receiver_id)
);

alter table public.friend_requests enable row level security;
alter table public.friend_links enable row level security;
alter table public.friend_gift_log enable row level security;
-- 客户端不允许直接写表；仅允许下方受控 RPC（SECURITY DEFINER）操作。
revoke all on public.friend_requests, public.friend_links, public.friend_gift_log from anon, authenticated;

create or replace function public.send_friend_request(p_username text)
returns jsonb language plpgsql security definer set search_path=public,auth as $$
declare v_me uuid:=auth.uid(); v_target uuid; v_low uuid; v_high uuid;
begin
 if v_me is null then raise exception '请先登录'; end if;
 select id into v_target from auth.users
 where lower(coalesce(raw_user_meta_data->>'username',raw_user_meta_data->>'user_name',''))=lower(trim(p_username))
 limit 1;
 if v_target is null then raise exception '没有找到这个用户名'; end if;
 if v_target=v_me then raise exception '不能添加自己为好友'; end if;
 v_low:=least(v_me,v_target); v_high:=greatest(v_me,v_target);
 if exists(select 1 from public.friend_links where user_low=v_low and user_high=v_high) then raise exception '你们已经是好友了'; end if;
 if exists(select 1 from public.friend_requests where sender_id=v_me and receiver_id=v_target and status='pending') then return jsonb_build_object('ok',true,'message','好友申请已经发送，请等待对方处理'); end if;
 if exists(select 1 from public.friend_requests where sender_id=v_target and receiver_id=v_me and status='pending') then
   update public.friend_requests set status='accepted',responded_at=now() where sender_id=v_target and receiver_id=v_me and status='pending';
   insert into public.friend_links(user_low,user_high) values(v_low,v_high) on conflict do nothing;
   return jsonb_build_object('ok',true,'message','对方也向你发送了申请，已自动成为好友');
 end if;
 insert into public.friend_requests(sender_id,receiver_id) values(v_me,v_target);
 return jsonb_build_object('ok',true,'message','好友申请已发送');
end $$;

create or replace function public.respond_friend_request(p_request_id uuid,p_accept boolean)
returns jsonb language plpgsql security definer set search_path=public,auth as $$
declare v_me uuid:=auth.uid(); v_sender uuid; v_receiver uuid;
begin
 if v_me is null then raise exception '请先登录'; end if;
 select sender_id,receiver_id into v_sender,v_receiver from public.friend_requests
 where request_id=p_request_id and receiver_id=v_me and status='pending' for update;
 if v_sender is null then raise exception '好友申请不存在或已处理'; end if;
 update public.friend_requests set status=case when p_accept then 'accepted' else 'declined' end,responded_at=now() where request_id=p_request_id;
 if p_accept then insert into public.friend_links(user_low,user_high) values(least(v_sender,v_receiver),greatest(v_sender,v_receiver)) on conflict do nothing; end if;
 return jsonb_build_object('ok',true,'message',case when p_accept then '已添加好友' else '已拒绝申请' end);
end $$;

create or replace function public.get_friend_overview()
returns jsonb language plpgsql security definer set search_path=public,auth as $$
declare v_me uuid:=auth.uid(); v_friends jsonb; v_requests jsonb;
begin
 if v_me is null then raise exception '请先登录'; end if;
 select coalesce(jsonb_agg(jsonb_build_object(
   'user_id',u.id,'username',coalesce(u.raw_user_meta_data->>'username',u.raw_user_meta_data->>'user_name','player'),
   'nickname',coalesce(u.raw_user_meta_data->>'nickname',u.raw_user_meta_data->>'username','玩家'),
   'intimacy',f.intimacy,'bonded',f.bonded_at is not null,
   'bond_requested_by_me',v_me=any(f.bond_requested_by)
 ) order by f.intimacy desc),'[]'::jsonb) into v_friends
 from public.friend_links f join auth.users u on u.id=case when f.user_low=v_me then f.user_high else f.user_low end
 where f.user_low=v_me or f.user_high=v_me;
 select coalesce(jsonb_agg(jsonb_build_object(
   'request_id',r.request_id,'user_id',u.id,
   'username',coalesce(u.raw_user_meta_data->>'username',u.raw_user_meta_data->>'user_name','player'),
   'nickname',coalesce(u.raw_user_meta_data->>'nickname',u.raw_user_meta_data->>'username','玩家')
 ) order by r.created_at desc),'[]'::jsonb) into v_requests
 from public.friend_requests r join auth.users u on u.id=r.sender_id
 where r.receiver_id=v_me and r.status='pending';
 return jsonb_build_object('friends',v_friends,'requests',v_requests);
end $$;

create or replace function public.send_friend_gift(p_friend_id uuid,p_gift_code text)
returns jsonb language plpgsql security definer set search_path=public,auth as $$
declare
 v_me uuid:=auth.uid(); v_low uuid; v_high uuid; v_cost_type text; v_cost integer; v_gain integer; v_name text;
 v_save jsonb; v_balance numeric;
begin
 if v_me is null then raise exception '请先登录'; end if;
 if p_friend_id=v_me then raise exception '不能给自己送礼物'; end if;
 if not exists(select 1 from public.friend_links where user_low=least(v_me,p_friend_id) and user_high=greatest(v_me,p_friend_id)) then raise exception '请先添加对方为好友'; end if;
 select cost_type,cost,intimacy_gain,name into v_cost_type,v_cost,v_gain,v_name from (values
  ('candy','coins',50,2,'糖果'),('flower','coins',200,10,'鲜花'),('cake','coins',500,30,'蛋糕'),
  ('stardust','gems',50,80,'星钻'),('bouquet','gems',200,250,'梦幻花束'),('crown','gems',500,700,'王者皇冠')
 ) as gifts(code,cost_type,cost,intimacy_gain,name) where code=p_gift_code;
 if v_cost is null then raise exception '礼物不存在'; end if;
 select save_data into v_save from public.game_saves where user_id=v_me for update;
 if v_save is null then raise exception '请先创建游戏云存档'; end if;
 v_balance:=coalesce((v_save->>v_cost_type)::numeric,0);
 if v_balance<v_cost then raise exception '你的%不足',case when v_cost_type='coins' then '金币' else '钻石' end; end if;
 update public.game_saves set save_data=jsonb_set(v_save,array[v_cost_type],to_jsonb(v_balance-v_cost),true),updated_at=now() where user_id=v_me;
 v_low:=least(v_me,p_friend_id); v_high:=greatest(v_me,p_friend_id);
 insert into public.friend_links(user_low,user_high,intimacy) values(v_low,v_high,v_gain)
 on conflict(user_low,user_high) do update set intimacy=public.friend_links.intimacy+excluded.intimacy,updated_at=now();
 insert into public.friend_gift_log(sender_id,receiver_id,gift_code,cost_type,cost,intimacy_gain) values(v_me,p_friend_id,p_gift_code,v_cost_type,v_cost,v_gain);
 return jsonb_build_object('ok',true,'message','已赠送'||v_name||'，亲密值 +'||v_gain,'intimacy_gain',v_gain);
end $$;

create or replace function public.request_friend_bond(p_friend_id uuid)
returns jsonb language plpgsql security definer set search_path=public,auth as $$
declare v_me uuid:=auth.uid(); v_low uuid; v_high uuid; v_score integer; v_requests uuid[]; v_bonded timestamptz;
begin
 if v_me is null then raise exception '请先登录'; end if;
 v_low:=least(v_me,p_friend_id); v_high:=greatest(v_me,p_friend_id);
 select intimacy,bond_requested_by,bonded_at into v_score,v_requests,v_bonded from public.friend_links where user_low=v_low and user_high=v_high for update;
 if v_score is null then raise exception '好友关系不存在'; end if;
 if v_bonded is not null then return jsonb_build_object('ok',true,'message','你们已经绑定羁绊搭档'); end if;
 if v_score<1000 then raise exception '亲密值还不够，需要达到 1000'; end if;
 if not (v_me=any(v_requests)) then v_requests:=array_append(v_requests,v_me); end if;
 if array_length(v_requests,1)>=2 then
   update public.friend_links set bond_requested_by=v_requests,bonded_at=now(),updated_at=now() where user_low=v_low and user_high=v_high;
   return jsonb_build_object('ok',true,'message','绑定成功！你们成为羁绊搭档');
 else
   update public.friend_links set bond_requested_by=v_requests,updated_at=now() where user_low=v_low and user_high=v_high;
   return jsonb_build_object('ok',true,'message','羁绊申请已发送，等待好友同意');
 end if;
end $$;

revoke all on function public.send_friend_request(text) from public, anon;
revoke all on function public.respond_friend_request(uuid,boolean) from public, anon;
revoke all on function public.get_friend_overview() from public, anon;
revoke all on function public.send_friend_gift(uuid,text) from public, anon;
revoke all on function public.request_friend_bond(uuid) from public, anon;
grant execute on function public.send_friend_request(text) to authenticated;
grant execute on function public.respond_friend_request(uuid,boolean) to authenticated;
grant execute on function public.get_friend_overview() to authenticated;
grant execute on function public.send_friend_gift(uuid,text) to authenticated;
grant execute on function public.request_friend_bond(uuid) to authenticated;
