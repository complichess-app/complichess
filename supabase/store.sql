-- © 2026 Bar Lvovski. All rights reserved.
-- Complichess store: Complichess Plus and coin packs, paid with Grow (Israel: Bit, Apple Pay, Google Pay, cards)
-- or Paddle (international), or as a request that Bar approves on /complichess/admin.html.
-- Runs on the same Supabase project as the game and barusik.com (same accounts, same is_admin()).
-- Additive only: it never changes or drops existing tables. Safe to run more than once.

-- ============ admins (same definition as barusik.sql, repeated so this file runs on its own) ============
create table if not exists public.barusik_admins (email text primary key);
alter table public.barusik_admins enable row level security;
insert into public.barusik_admins (email) values ('barusik.official@gmail.com') on conflict do nothing;
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public, auth as $$
  select exists (
    select 1 from auth.users u join public.barusik_admins a on lower(a.email) = lower(u.email)
    where u.id = auth.uid() and u.email_confirmed_at is not null
  );
$$;
grant execute on function public.is_admin() to anon, authenticated;

-- ============ products (prices are edited on the admin page) ============
create table if not exists public.cx_products (
  id text primary key,
  kind text not null check (kind in ('plus', 'coins')),
  coins int not null default 0 check (coins >= 0),
  price_ils numeric(10, 2) not null check (price_ils > 0),
  price_usd numeric(10, 2) not null check (price_usd > 0),
  paddle_price_id text not null default '',
  active boolean not null default true,
  sort int not null default 0
);
alter table public.cx_products enable row level security;
drop policy if exists "cx_products read" on public.cx_products;
create policy "cx_products read" on public.cx_products for select using (true);
insert into public.cx_products (id, kind, coins, price_ils, price_usd, sort) values
  ('plus',        'plus',  0,    24.90, 6.99,  1),
  ('coins_500',   'coins', 500,  9.90,  2.99,  2),
  ('coins_1500',  'coins', 1500, 19.90, 5.99,  3),
  ('coins_5000',  'coins', 5000, 49.90, 14.99, 4)
on conflict (id) do nothing;

-- ============ settings: the business (העוסק) and the payment providers. Never readable from the app. ============
create table if not exists public.cx_settings (
  id int primary key default 1 check (id = 1),
  business jsonb not null default '{}'::jsonb,   -- name, kind (patur / murshe / company), number, address, phone, email
  pay jsonb not null default '{}'::jsonb,        -- { grow: {...}, paddle: {...}, manual: {...} }
  updated_at timestamptz not null default now()
);
alter table public.cx_settings enable row level security;           -- no policies: only the functions below touch it
insert into public.cx_settings (id) values (1) on conflict do nothing;

-- ============ orders ============
create table if not exists public.cx_orders (
  id uuid primary key default gen_random_uuid(),
  code text not null unique default upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8)),
  uid uuid references auth.users on delete set null,     -- kept after account deletion: sales records must stay
  email text not null default '',
  product text not null references public.cx_products (id),
  kind text not null,
  coins int not null default 0,
  provider text not null check (provider in ('manual', 'grow', 'paddle')),
  status text not null default 'pending' check (status in ('pending', 'awaiting_payment', 'paid', 'approved', 'declined', 'cancelled', 'refunded')),
  amount numeric(10, 2) not null default 0,
  currency text not null default 'ILS',
  lang text not null default 'he',
  buyer_name text not null default '',
  buyer_phone text not null default '',
  consent_at timestamptz,                                  -- ticked "I agree to the terms and the cancellation policy"
  created_at timestamptz not null default now(),
  paid_at timestamptz,
  decided_at timestamptz,
  redeemed_at timestamptz,                                 -- coins: when the game added them to the player
  provider_ref text not null default '',                   -- Grow transaction id / Paddle txn id
  provider_process text not null default '',               -- Grow processId (server only)
  provider_secret text not null default '',                -- Grow processToken (server only, never sent to the buyer)
  note text not null default '',
  raw jsonb
);
create index if not exists cx_orders_uid on public.cx_orders (uid, created_at desc);
create index if not exists cx_orders_open on public.cx_orders (created_at) where status in ('pending', 'awaiting_payment');
alter table public.cx_orders enable row level security;              -- no policies: the app reads its orders through cx_me()

-- ============ the player's side ============
-- what the store needs: prices, which payment methods are switched on, and the seller's details for the legal page
create or replace function public.cx_public_config() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'products', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'kind', p.kind, 'coins', p.coins, 'ils', p.price_ils, 'usd', p.price_usd,
                 'paddle', p.paddle_price_id) order by p.sort) from public.cx_products p where p.active), '[]'::jsonb),
    'business', jsonb_build_object(
      'name', coalesce(s.business->>'name', ''), 'kind', coalesce(s.business->>'kind', ''), 'number', coalesce(s.business->>'number', ''),
      'address', coalesce(s.business->>'address', ''), 'phone', coalesce(s.business->>'phone', ''), 'email', coalesce(s.business->>'email', '')),
    'grow', (coalesce((s.pay->'grow'->>'on')::boolean, false) and coalesce(s.pay->'grow'->>'user_id', '') <> '' and coalesce(s.pay->'grow'->>'page_code', '') <> ''),
    'paddle', case when coalesce((s.pay->'paddle'->>'on')::boolean, false) and coalesce(s.pay->'paddle'->>'client_token', '') <> ''
      then jsonb_build_object('env', coalesce(s.pay->'paddle'->>'env', 'sandbox'), 'token', s.pay->'paddle'->>'client_token') else null end,
    'manual', jsonb_build_object('on', coalesce((s.pay->'manual'->>'on')::boolean, true),
      'link', coalesce(s.pay->'manual'->>'link', ''), 'note', coalesce(s.pay->'manual'->>'note', ''))
  ) from public.cx_settings s where s.id = 1;
$$;

-- what this player owns: Plus, coins waiting to be added, and the last orders
create or replace function public.cx_me() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare u uuid := auth.uid();
begin
  if u is null then return jsonb_build_object('plus', false, 'coins', 0, 'orders', '[]'::jsonb); end if;
  return jsonb_build_object(
    'plus', exists (select 1 from public.cx_orders where uid = u and kind = 'plus' and status in ('paid', 'approved')),
    'coins', coalesce((select sum(coins) from public.cx_orders where uid = u and kind = 'coins' and status in ('paid', 'approved') and redeemed_at is null), 0),
    'orders', coalesce((select jsonb_agg(x order by x->>'created_at' desc) from (
      select jsonb_build_object('id', id, 'code', code, 'product', product, 'status', status, 'provider', provider, 'amount', amount,
                                'currency', currency, 'created_at', created_at, 'paid_at', paid_at) x
        from public.cx_orders where uid = u order by created_at desc limit 20) t), '[]'::jsonb));
end $$;

-- the game takes the coins that were paid for (once): they move into the player's coin balance on this device
create or replace function public.cx_claim_coins() returns int
language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); n int;
begin
  if u is null then return 0; end if;
  with c as (
    update public.cx_orders set redeemed_at = now()
     where uid = u and kind = 'coins' and status in ('paid', 'approved') and redeemed_at is null
     returning coins)
  select coalesce(sum(coins), 0)::int into n from c;
  return n;
end $$;

-- a purchase request without online payment: it waits for Bar on the admin page
create or replace function public.cx_request(p_product text, p_consent boolean, p_lang text) returns jsonb
language plpgsql security definer set search_path = public, auth as $$
declare u uuid := auth.uid(); p public.cx_products; o public.cx_orders; mail text;
begin
  if u is null then raise exception 'sign in first' using errcode = '42501'; end if;
  if not coalesce(p_consent, false) then raise exception 'consent needed' using errcode = 'P0001'; end if;
  if not coalesce((select (pay->'manual'->>'on')::boolean from public.cx_settings where id = 1), true) then
    raise exception 'requests are closed' using errcode = 'P0001';
  end if;
  select * into p from public.cx_products where id = p_product and active;
  if p.id is null then raise exception 'no such product' using errcode = 'P0001'; end if;
  if p.kind = 'plus' and exists (select 1 from public.cx_orders where uid = u and kind = 'plus' and status in ('paid', 'approved')) then
    raise exception 'already plus' using errcode = 'P0001';
  end if;
  if (select count(*) from public.cx_orders where uid = u and status in ('pending', 'awaiting_payment')) >= 3 then
    raise exception 'too many waiting' using errcode = 'P0001';
  end if;
  select email into mail from auth.users where id = u;
  insert into public.cx_orders (uid, email, product, kind, coins, provider, status, amount, currency, lang, consent_at)
  values (u, coalesce(mail, ''), p.id, p.kind, p.coins, 'manual', 'pending', p.price_ils, 'ILS',
          case when p_lang in ('he', 'en', 'ar', 'ru', 'es', 'fr') then p_lang else 'he' end, now())
  returning * into o;
  return jsonb_build_object('id', o.id, 'code', o.code, 'status', o.status);
end $$;

-- the player cancels a request that has not been paid or approved yet
create or replace function public.cx_cancel(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  update public.cx_orders set status = 'cancelled', decided_at = now()
   where id = p_id and uid = auth.uid() and status in ('pending', 'awaiting_payment');
end $$;

-- ============ server side (edge functions, service role only) ============
create or replace function public.cx_mark_paid(p_id uuid, p_provider text, p_ref text, p_amount numeric, p_currency text, p_raw jsonb)
returns text language plpgsql security definer set search_path = public as $$
declare o public.cx_orders;
begin
  select * into o from public.cx_orders where id = p_id for update;
  if o.id is null then return 'missing'; end if;
  if o.status in ('paid', 'approved') then return 'already'; end if;
  if o.status = 'refunded' then return 'refunded'; end if;
  update public.cx_orders set status = 'paid', paid_at = now(), provider = p_provider, provider_ref = coalesce(p_ref, ''),
         amount = coalesce(p_amount, amount), currency = coalesce(nullif(p_currency, ''), currency), raw = p_raw
   where id = p_id;
  return 'paid';
end $$;

-- ============ admin ============
create or replace function public.cx_admin_orders() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'not allowed' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(x order by (x->>'open')::boolean desc, x->>'created_at' desc) from (
    select jsonb_build_object('id', o.id, 'code', o.code, 'email', o.email, 'product', o.product, 'kind', o.kind, 'coins', o.coins,
      'provider', o.provider, 'status', o.status, 'amount', o.amount, 'currency', o.currency, 'lang', o.lang, 'buyer_name', o.buyer_name,
      'buyer_phone', o.buyer_phone, 'created_at', o.created_at, 'paid_at', o.paid_at, 'decided_at', o.decided_at, 'redeemed_at', o.redeemed_at,
      'provider_ref', o.provider_ref, 'note', o.note, 'open', o.status in ('pending', 'awaiting_payment')) x
      from public.cx_orders o
     where o.status in ('pending', 'awaiting_payment') or o.created_at > now() - interval '400 days'
     order by o.created_at desc limit 500) t), '[]'::jsonb);
end $$;

-- approve (the item is given; with a manual payment Bar checked the money arrived), gift (given free, amount 0), decline,
-- mark refunded, or only add a note
create or replace function public.cx_admin_decide(p_id uuid, p_action text, p_note text default null) returns text
language plpgsql security definer set search_path = public as $$
declare o public.cx_orders;
begin
  if not public.is_admin() then raise exception 'not allowed' using errcode = '42501'; end if;
  select * into o from public.cx_orders where id = p_id for update;
  if o.id is null then raise exception 'no such order' using errcode = 'P0001'; end if;
  if p_action = 'approve' and o.status in ('pending', 'awaiting_payment', 'declined', 'cancelled') then
    update public.cx_orders set status = 'approved', decided_at = now() where id = p_id;
  elsif p_action = 'gift' and o.status in ('pending', 'awaiting_payment', 'declined', 'cancelled') then
    update public.cx_orders set status = 'approved', decided_at = now(), amount = 0 where id = p_id;   -- given for free: not counted as income
  elsif p_action = 'decline' and o.status in ('pending', 'awaiting_payment') then
    update public.cx_orders set status = 'declined', decided_at = now() where id = p_id;
  elsif p_action = 'refund' and o.status in ('paid', 'approved') then
    update public.cx_orders set status = 'refunded', decided_at = now() where id = p_id;
  elsif p_action = 'note' then
    null;
  else
    raise exception 'cannot % an order that is %', p_action, o.status using errcode = 'P0001';
  end if;
  if p_note is not null then update public.cx_orders set note = left(p_note, 500) where id = p_id; end if;
  return (select status from public.cx_orders where id = p_id);
end $$;

-- settings for the admin page: secrets come back masked, and a masked value sent back keeps the stored secret
create or replace function public.cx_mask(v text) returns text language sql immutable as $$
  select case when coalesce(v, '') = '' then '' else '••••' || right(v, 4) end;
$$;
create or replace function public.cx_admin_settings() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare s public.cx_settings;
begin
  if not public.is_admin() then raise exception 'not allowed' using errcode = '42501'; end if;
  select * into s from public.cx_settings where id = 1;
  return jsonb_build_object(
    'business', s.business,
    'grow', jsonb_build_object('on', coalesce((s.pay->'grow'->>'on')::boolean, false), 'env', coalesce(s.pay->'grow'->>'env', 'sandbox'),
      'user_id', coalesce(s.pay->'grow'->>'user_id', ''), 'page_code', coalesce(s.pay->'grow'->>'page_code', ''),
      'api_key', public.cx_mask(s.pay->'grow'->>'api_key')),
    'paddle', jsonb_build_object('on', coalesce((s.pay->'paddle'->>'on')::boolean, false), 'env', coalesce(s.pay->'paddle'->>'env', 'sandbox'),
      'client_token', coalesce(s.pay->'paddle'->>'client_token', ''), 'webhook_secret', public.cx_mask(s.pay->'paddle'->>'webhook_secret')),
    'manual', jsonb_build_object('on', coalesce((s.pay->'manual'->>'on')::boolean, true), 'link', coalesce(s.pay->'manual'->>'link', ''),
      'note', coalesce(s.pay->'manual'->>'note', '')),
    'products', coalesce((select jsonb_agg(to_jsonb(p) order by p.sort) from public.cx_products p), '[]'::jsonb),
    'updated_at', s.updated_at);
end $$;

create or replace function public.cx_admin_save_settings(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s public.cx_settings; v_pay jsonb; g jsonb; pd jsonb; pr jsonb;
begin
  if not public.is_admin() then raise exception 'not allowed' using errcode = '42501'; end if;
  select * into s from public.cx_settings where id = 1 for update;
  v_pay := coalesce(s.pay, '{}'::jsonb);
  if p ? 'business' then
    update public.cx_settings set business = jsonb_strip_nulls(jsonb_build_object(
      'name', left(p->'business'->>'name', 120), 'kind', left(p->'business'->>'kind', 20), 'number', left(p->'business'->>'number', 20),
      'address', left(p->'business'->>'address', 200), 'phone', left(p->'business'->>'phone', 30), 'email', left(p->'business'->>'email', 120)))
     where id = 1;
  end if;
  if p ? 'grow' then
    g := p->'grow';
    if coalesce(g->>'api_key', '') like '••••%' then g := g - 'api_key' || jsonb_build_object('api_key', coalesce(v_pay->'grow'->>'api_key', '')); end if;
    v_pay := v_pay || jsonb_build_object('grow', jsonb_build_object('on', coalesce((g->>'on')::boolean, false),
      'env', case when g->>'env' = 'live' then 'live' else 'sandbox' end, 'user_id', trim(coalesce(g->>'user_id', '')),
      'page_code', trim(coalesce(g->>'page_code', '')), 'api_key', trim(coalesce(g->>'api_key', ''))));
  end if;
  if p ? 'paddle' then
    pd := p->'paddle';
    if coalesce(pd->>'webhook_secret', '') like '••••%' then pd := pd - 'webhook_secret' || jsonb_build_object('webhook_secret', coalesce(v_pay->'paddle'->>'webhook_secret', '')); end if;
    v_pay := v_pay || jsonb_build_object('paddle', jsonb_build_object('on', coalesce((pd->>'on')::boolean, false),
      'env', case when pd->>'env' = 'live' then 'live' else 'sandbox' end, 'client_token', trim(coalesce(pd->>'client_token', '')),
      'webhook_secret', trim(coalesce(pd->>'webhook_secret', ''))));
  end if;
  if p ? 'manual' then
    v_pay := v_pay || jsonb_build_object('manual', jsonb_build_object('on', coalesce((p->'manual'->>'on')::boolean, true),
      'link', left(trim(coalesce(p->'manual'->>'link', '')), 300), 'note', left(coalesce(p->'manual'->>'note', ''), 500)));
  end if;
  update public.cx_settings set pay = v_pay, updated_at = now() where id = 1;
  if p ? 'products' then
    for pr in select * from jsonb_array_elements(p->'products') loop
      update public.cx_products set
        price_ils = greatest(1, coalesce((pr->>'price_ils')::numeric, price_ils)),
        price_usd = greatest(0.5, coalesce((pr->>'price_usd')::numeric, price_usd)),
        coins = case when kind = 'coins' then greatest(1, coalesce((pr->>'coins')::int, coins)) else 0 end,
        paddle_price_id = left(trim(coalesce(pr->>'paddle_price_id', paddle_price_id)), 60),
        active = coalesce((pr->>'active')::boolean, active)
       where id = pr->>'id';
    end loop;
  end if;
  return public.cx_admin_settings();
end $$;

-- sales totals: this year (an עוסק פטור has a yearly turnover ceiling) and by month
create or replace function public.cx_admin_stats() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'not allowed' using errcode = '42501'; end if;
  return jsonb_build_object(
    'year_ils', coalesce((select sum(amount) from public.cx_orders where status in ('paid', 'approved') and currency = 'ILS'
                           and coalesce(paid_at, decided_at) >= date_trunc('year', now())), 0),
    'year_usd', coalesce((select sum(amount) from public.cx_orders where status in ('paid', 'approved') and currency = 'USD'
                           and coalesce(paid_at, decided_at) >= date_trunc('year', now())), 0),
    'plus', (select count(*) from public.cx_orders where kind = 'plus' and status in ('paid', 'approved')),
    'waiting', (select count(*) from public.cx_orders where status = 'pending'),
    'months', coalesce((select jsonb_agg(m order by m->>'month' desc) from (
      select jsonb_build_object('month', to_char(date_trunc('month', coalesce(paid_at, decided_at)), 'YYYY-MM'), 'orders', count(*),
        'ils', sum(amount) filter (where currency = 'ILS'), 'usd', sum(amount) filter (where currency = 'USD')) m
        from public.cx_orders where status in ('paid', 'approved') group by date_trunc('month', coalesce(paid_at, decided_at))
        order by date_trunc('month', coalesce(paid_at, decided_at)) desc limit 24) t), '[]'::jsonb));
end $$;

-- ============ delete my account (same as hardening.sql: one shared account for every Barusik platform) ============
create or replace function public.delete_my_account() returns void
language plpgsql security definer set search_path = public, auth as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'not signed in' using errcode = '42501'; end if;
  if public.is_admin() then raise exception 'the admin account cannot be deleted from the app'; end if;
  if to_regclass('public.profiles') is not null then execute 'delete from public.profiles where id = $1' using uid; end if;
  delete from auth.users where id = uid;
end $$;

-- ============ permissions ============
revoke all on function public.cx_public_config(), public.cx_me(), public.cx_claim_coins(), public.cx_request(text, boolean, text),
  public.cx_cancel(uuid), public.cx_mark_paid(uuid, text, text, numeric, text, jsonb), public.cx_admin_orders(),
  public.cx_admin_decide(uuid, text, text), public.cx_admin_settings(), public.cx_admin_save_settings(jsonb), public.cx_admin_stats(),
  public.cx_mask(text), public.delete_my_account() from public, anon, authenticated;
grant execute on function public.cx_public_config() to anon, authenticated;
grant execute on function public.cx_me(), public.cx_claim_coins(), public.cx_request(text, boolean, text), public.cx_cancel(uuid),
  public.cx_admin_orders(), public.cx_admin_decide(uuid, text, text), public.cx_admin_settings(), public.cx_admin_save_settings(jsonb),
  public.cx_admin_stats(), public.delete_my_account() to authenticated;
grant execute on function public.cx_mark_paid(uuid, text, text, numeric, text, jsonb) to service_role;
grant select, insert, update on public.cx_orders, public.cx_settings to service_role;
grant select on public.cx_products to service_role;
