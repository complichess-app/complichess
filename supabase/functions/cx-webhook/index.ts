// © 2026 Bar Lvovski. All rights reserved.
// Complichess store — payment notifications.
//   ?provider=grow    Grow (Meshulam) server-to-server callback. Trusted only when it carries the secret processToken that
//                     Grow gave us for this order; then we tell Grow we got it (approveTransaction).
//   ?provider=paddle  Paddle webhook, signed with the notification secret (Paddle-Signature: ts=...;h1=...).
// A trusted, paid notification marks the order paid (cx_mark_paid), and the game gives the item on the player's next visit.
// Deploy with "Verify JWT" OFF: Grow and Paddle cannot send a Supabase session.

import { createClient } from 'npm:@supabase/supabase-js@2';

const GROW_BASE = { live: 'https://secure.meshulam.co.il/api/light/server/1.0', sandbox: 'https://sandbox.meshulam.co.il/api/light/server/1.0' };

export type Deps = { db: any; fetch: typeof fetch; now?: () => number };
const text = (status: number, body: string) => new Response(body, { status, headers: { 'Content-Type': 'text/plain' } });

// ---- helpers ----
const hex = (buf: ArrayBuffer) => Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, '0')).join('');
export async function hmacHex(secret: string, msg: string): Promise<string> {
  const k = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return hex(await crypto.subtle.sign('HMAC', k, new TextEncoder().encode(msg)));
}
function sameText(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let x = 0; for (let i = 0; i < a.length; i++) x |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return x === 0;
}
export async function paddleSigned(header: string, raw: string, secret: string, nowSec: number): Promise<boolean> {
  if (!header || !secret) return false;
  let ts = ''; const h1: string[] = [];
  header.split(';').forEach((part) => { const [k, v] = part.split('='); if (k === 'ts') ts = v; else if (k === 'h1' && v) h1.push(v); });
  if (!ts || !h1.length || Math.abs(nowSec - Number(ts)) > 300) return false;
  const want = await hmacHex(secret, ts + ':' + raw);
  return h1.some((h) => sameText(h, want));
}
// Grow posts form fields (sometimes nested like data[transactionId]); the docs also show JSON. Flatten both to one level.
export async function readGrow(req: Request, raw: string): Promise<Record<string, string>> {
  const ct = (req.headers.get('content-type') || '').toLowerCase();
  const out: Record<string, string> = {};
  const put = (k: string, v: unknown) => {
    if (v === null || v === undefined) return;
    if (typeof v === 'object') { for (const [kk, vv] of Object.entries(v as any)) put(kk, vv); return; }
    const key = k.replace(/^.*\[([^\]]+)\]$/, '$1');   // data[transactionId] -> transactionId, customFields[cField1] -> cField1
    if (!(key in out) || out[key] === '') out[key] = String(v);
  };
  if (ct.includes('json') || /^\s*\{/.test(raw)) {
    try { put('', JSON.parse(raw)); return out; } catch (_) { /* not json after all */ }
  }
  try {
    const fd = await new Request('http://local/', { method: 'POST', headers: { 'content-type': ct || 'application/x-www-form-urlencoded' }, body: raw }).formData();
    for (const [k, v] of fd.entries()) put(k, typeof v === 'string' ? v : '');
  } catch (_) {
    for (const [k, v] of new URLSearchParams(raw)) put(k, v);
  }
  return out;
}

async function markPaid(d: Deps, id: string, provider: string, ref: string, amount: number, currency: string, raw: unknown) {
  const { data, error } = await d.db.rpc('cx_mark_paid', { p_id: id, p_provider: provider, p_ref: ref, p_amount: amount, p_currency: currency, p_raw: raw });
  if (error) throw new Error(error.message);
  return data as string;
}
async function settings(d: Deps) {
  const { data } = await d.db.from('cx_settings').select('pay').eq('id', 1).maybeSingle();
  return (data && data.pay) || {};
}

// ---- Paddle ----
async function paddle(req: Request, raw: string, d: Deps): Promise<Response> {
  const pay = await settings(d);
  const secret = (pay.paddle && pay.paddle.webhook_secret) || '';
  const ok = await paddleSigned(req.headers.get('paddle-signature') || '', raw, secret, Math.floor((d.now ? d.now() : Date.now()) / 1000));
  if (!ok) return text(401, 'bad signature');
  let ev: any; try { ev = JSON.parse(raw); } catch (_) { return text(400, 'bad json'); }
  if (ev.event_type !== 'transaction.completed' && ev.event_type !== 'transaction.paid') return text(200, 'ignored');
  const t = ev.data || {};
  const id = t.custom_data && t.custom_data.order_id;
  if (!id) return text(200, 'no order');
  const { data: o } = await d.db.from('cx_orders').select('id,product,provider,status').eq('id', id).maybeSingle();
  if (!o) return text(200, 'unknown order');
  const { data: p } = await d.db.from('cx_products').select('paddle_price_id').eq('id', o.product).maybeSingle();
  const prices = (t.items || []).map((it: any) => (it.price && it.price.id) || it.price_id);
  if (!p || !prices.includes(p.paddle_price_id)) {
    await d.db.from('cx_orders').update({ note: 'Paddle: paid for a different price ' + prices.join(',') }).eq('id', id);
    return text(200, 'price mismatch');
  }
  const totals = (t.details && t.details.totals) || {};
  const amount = totals.total ? Number(totals.total) / 100 : 0;
  await markPaid(d, id, 'paddle', String(t.id || ''), amount, String(t.currency_code || 'USD'), ev);
  return text(200, 'ok');
}

// ---- Grow ----
async function grow(req: Request, raw: string, d: Deps): Promise<Response> {
  const f = await readGrow(req, raw);
  const id = f.cField1 || '';
  if (!/^[0-9a-f-]{36}$/i.test(id)) return text(200, 'no order');
  const { data: o } = await d.db.from('cx_orders').select('*').eq('id', id).maybeSingle();
  if (!o || o.provider !== 'grow') return text(200, 'unknown order');
  // the processToken is a secret between Grow and this server: the buyer never sees it
  if (!o.provider_secret || !sameText(String(f.processToken || ''), o.provider_secret) || String(f.processId || '') !== String(o.provider_process)) {
    return text(403, 'not trusted');
  }
  const sum = Number(f.sum || f.paymentSum || 0);
  const pay = await settings(d);
  const g = pay.grow || {};
  if (!f.transactionId || sum + 0.009 < Number(o.amount)) {
    await d.db.from('cx_orders').update({ note: ('Grow: notification without a full payment (sum ' + (f.sum || '?') + ', status ' + (f.statusCode || f.status || '?') + ')').slice(0, 500), raw: f }).eq('id', id);
  } else {
    await markPaid(d, id, 'grow', String(f.transactionId), sum, 'ILS', f);
  }
  // acknowledge: send back the page code and everything Grow sent
  try {
    const ack = new FormData();
    ack.set('pageCode', g.page_code || '');
    for (const [k, v] of Object.entries(f)) if (k !== 'pageCode') ack.set(k, v);
    await d.fetch((g.env === 'live' ? GROW_BASE.live : GROW_BASE.sandbox) + '/approveTransaction', { method: 'POST', body: ack });
  } catch (_) { /* Grow keeps the payment either way and retries the notification */ }
  return text(200, 'ok');
}

export async function handle(req: Request, d: Deps): Promise<Response> {
  if (req.method !== 'POST') return text(405, 'POST only');
  const provider = new URL(req.url).searchParams.get('provider');
  const raw = await req.text();
  if (raw.length > 200000) return text(413, 'too big');
  if (provider === 'paddle') return paddle(req, raw, d);
  if (provider === 'grow') return grow(req, raw, d);
  return text(400, 'unknown provider');
}

// ---- Supabase runtime ----
declare const Deno: any;
if (typeof Deno !== 'undefined') {
  let key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || '';
  if (!key) { try { const k = JSON.parse(Deno.env.get('SUPABASE_SECRET_KEYS') || '{}'); key = k.default || Object.values(k)[0] || ''; } catch (_) { /* none */ } }
  const db = createClient(Deno.env.get('SUPABASE_URL'), key, { auth: { persistSession: false, autoRefreshToken: false } });
  Deno.serve((req: Request) => handle(req, { db, fetch }).catch((e) => text(500, 'server error: ' + String(e).slice(0, 200))));
}
