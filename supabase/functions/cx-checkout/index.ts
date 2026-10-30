// © 2026 Bar Lvovski. All rights reserved.
// Complichess store — starts a payment for a signed-in player.
//   POST { product, method: 'grow' | 'paddle', consent: true, lang, name?, phone?, back? }
//   grow   -> creates the order and a Grow payment page (Bit, Apple Pay, Google Pay, cards) and returns { url, code }
//   paddle -> creates the order and returns what Paddle.js needs to open its checkout: { paddle: { env, token, price }, order, code, email }
// Requests without online payment (cx_request) and the admin page do not need this function.
// Deploy with "Verify JWT" OFF: the function checks the player's session itself (works with the new Supabase API keys).

import { createClient } from 'npm:@supabase/supabase-js@2';

const ORIGINS = ['https://barusik.com', 'https://www.barusik.com', 'https://complichess-app.github.io'];
const DEFAULT_BACK = 'https://barusik.com/complichess/';
const GROW_BASE = { live: 'https://secure.meshulam.co.il/api/light/server/1.0', sandbox: 'https://sandbox.meshulam.co.il/api/light/server/1.0' };
const DESC: Record<string, string> = { plus: 'Complichess Plus', coins: 'Complichess coins' };

export type Deps = {
  supabaseUrl: string;
  getUser: (token: string) => Promise<{ id: string; email?: string } | null>;
  db: any;                       // supabase-js client with the service role
  fetch: typeof fetch;
};

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });
const fail = (status: number, error: string, extra: Record<string, unknown> = {}) => json(status, { error, ...extra });

export function safeBack(back: unknown): string {
  try {
    const u = new URL(String(back || ''));
    if (ORIGINS.includes(u.origin)) { u.search = ''; u.hash = ''; return u.toString(); }
  } catch (_) { /* fall through */ }
  return DEFAULT_BACK;
}
// Grow needs an Israeli mobile number: 05XXXXXXXX
export function normPhone(p: unknown): string {
  let d = String(p || '').replace(/[^\d+]/g, '');
  if (d.startsWith('+972')) d = '0' + d.slice(4);
  else if (d.startsWith('972')) d = '0' + d.slice(3);
  return /^05\d{8}$/.test(d) ? d : '';
}
export function normName(n: unknown): string {
  const s = String(n || '').replace(/[<>"'`;{}\\]/g, '').replace(/\s+/g, ' ').trim().slice(0, 60);
  return s.split(' ').filter((w) => w.length >= 2).length >= 2 ? s : '';
}
export function businessReady(b: any): boolean {
  return !!(b && String(b.name || '').trim() && String(b.number || '').trim() && String(b.address || '').trim() && (String(b.phone || '').trim() || String(b.email || '').trim()));
}

export async function handle(req: Request, d: Deps): Promise<Response> {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return fail(405, 'POST only');
  const token = (req.headers.get('authorization') || '').replace(/^Bearer\s+/i, '');
  const user = token ? await d.getUser(token).catch(() => null) : null;
  if (!user) return fail(401, 'sign in first');
  let body: any;
  try { body = await req.json(); } catch (_) { return fail(400, 'bad json'); }
  if (body.consent !== true) return fail(400, 'consent needed');
  const method = body.method === 'paddle' ? 'paddle' : body.method === 'grow' ? 'grow' : '';
  if (!method) return fail(400, 'unknown method');
  const lang = ['he', 'en', 'ar', 'ru', 'es', 'fr'].includes(body.lang) ? body.lang : 'he';

  const { data: s } = await d.db.from('cx_settings').select('*').eq('id', 1).maybeSingle();
  const { data: p } = await d.db.from('cx_products').select('*').eq('id', String(body.product || '')).eq('active', true).maybeSingle();
  if (!s || !p) return fail(400, 'no such product');
  if (!businessReady(s.business)) return fail(409, 'store not ready', { why: 'business' });

  const { data: mine } = await d.db.from('cx_orders').select('kind,status,created_at').eq('uid', user.id).order('created_at', { ascending: false }).limit(50);
  const list = mine || [];
  if (p.kind === 'plus' && list.some((o: any) => o.kind === 'plus' && (o.status === 'paid' || o.status === 'approved'))) return fail(409, 'already plus');
  const hourAgo = Date.now() - 3600e3;
  if (list.filter((o: any) => o.status === 'awaiting_payment' && Date.parse(o.created_at) > hourAgo).length >= 6) return fail(429, 'too many tries');

  const back = safeBack(body.back);
  const base = { uid: user.id, email: user.email || '', product: p.id, kind: p.kind, coins: p.kind === 'coins' ? p.coins : 0, lang, consent_at: new Date().toISOString() };

  if (method === 'paddle') {
    const pd = (s.pay && s.pay.paddle) || {};
    if (!pd.on || !pd.client_token || !p.paddle_price_id) return fail(409, 'store not ready', { why: 'paddle' });
    const { data: o, error } = await d.db.from('cx_orders').insert({ ...base, provider: 'paddle', status: 'awaiting_payment', amount: p.price_usd, currency: 'USD' }).select('id,code').single();
    if (error || !o) return fail(500, 'could not save the order');
    return json(200, { order: o.id, code: o.code, email: user.email || '', back: back + '?cxpaid=' + o.code,
      paddle: { env: pd.env === 'live' ? 'live' : 'sandbox', token: pd.client_token, price: p.paddle_price_id } });
  }

  // Grow
  const g = (s.pay && s.pay.grow) || {};
  if (!g.on || !g.user_id || !g.page_code) return fail(409, 'store not ready', { why: 'grow' });
  const name = normName(body.name), phone = normPhone(body.phone);
  if (!name) return fail(400, 'full name needed');
  if (!phone) return fail(400, 'israeli mobile needed');
  const sum = Number(p.price_ils).toFixed(2);
  const { data: o, error } = await d.db.from('cx_orders').insert({ ...base, provider: 'grow', status: 'awaiting_payment', amount: p.price_ils, currency: 'ILS', buyer_name: name, buyer_phone: phone }).select('id,code').single();
  if (error || !o) return fail(500, 'could not save the order');
  const description = p.kind === 'plus' ? DESC.plus : DESC.coins + ' ' + p.coins;
  const f = new FormData();
  f.set('pageCode', g.page_code);
  f.set('userId', g.user_id);
  if (g.api_key) f.set('apiKey', g.api_key);
  f.set('chargeType', '1');
  f.set('sum', sum);
  f.set('paymentNum', '1');
  f.set('description', description);
  f.set('successUrl', back + '?cxpaid=' + o.code);
  f.set('cancelUrl', back + '?cxcancel=' + o.code);
  f.set('notifyUrl', d.supabaseUrl.replace(/\/$/, '') + '/functions/v1/cx-webhook?provider=grow');
  f.set('pageField[fullName]', name);
  f.set('pageField[phone]', phone);
  if (user.email) f.set('pageField[email]', user.email);
  f.set('cField1', o.id);
  f.set('cField2', o.code);
  f.set('productData[0][quantity]', '1');
  f.set('productData[0][price]', sum);
  f.set('productData[0][itemDescription]', description);
  let res: any = null;
  try {
    const r = await d.fetch((g.env === 'live' ? GROW_BASE.live : GROW_BASE.sandbox) + '/createPaymentProcess', { method: 'POST', body: f });
    res = await r.json();
  } catch (e) { res = { status: 0, err: { message: String(e) } }; }
  if (!res || Number(res.status) !== 1 || !res.data || !res.data.url) {
    const msg = res && res.err ? (res.err.message || JSON.stringify(res.err)) : 'no answer';
    await d.db.from('cx_orders').update({ status: 'cancelled', note: ('Grow: ' + msg).slice(0, 500) }).eq('id', o.id);
    return fail(502, 'payment page failed', { detail: String(msg).slice(0, 200) });
  }
  await d.db.from('cx_orders').update({ provider_process: String(res.data.processId || ''), provider_secret: String(res.data.processToken || '') }).eq('id', o.id);
  return json(200, { url: res.data.url, code: o.code });
}

// ---- Supabase runtime ----
declare const Deno: any;
if (typeof Deno !== 'undefined') {
  const url = Deno.env.get('SUPABASE_URL');
  let key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || '';
  if (!key) { try { const k = JSON.parse(Deno.env.get('SUPABASE_SECRET_KEYS') || '{}'); key = k.default || Object.values(k)[0] || ''; } catch (_) { /* none */ } }
  const db = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });
  const deps: Deps = {
    supabaseUrl: url, db, fetch,
    getUser: async (t) => { const { data } = await db.auth.getUser(t); return data && data.user ? { id: data.user.id, email: data.user.email } : null; },
  };
  Deno.serve((req: Request) => handle(req, deps).catch((e) => fail(500, 'server error', { detail: String(e).slice(0, 200) })));
}
