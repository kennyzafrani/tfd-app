'use strict';
// Test harness: a tiny stand-in for Supabase (Auth + PostgREST RPC) backed by a real local Postgres,
// plus a stand-in for Netlify (static files + /api functions). Test use only.
//   node fake_supabase.js <psql socket dir> <db name> <port>
const http = require('node:http'); const fs = require('node:fs'); const path = require('node:path');
const { execFileSync } = require('node:child_process'); const crypto = require('node:crypto');
const [SOCK, DB, PORT] = process.argv.slice(2);
const WEB = path.resolve(__dirname, '../..');
const SERVICE = 'sb_secret_test', ANON = 'sb_publishable_test';
const passwords = new Map(); // email -> {id, password}

function sql(q, role, sub) {
  const pre = [role ? `set role ${role};` : '', sub ? `select set_config('request.jwt.claim.sub', '${sub}', false) \\g /dev/null` : ''].join('\n');
  try {
    const out = execFileSync('psql', ['-h', SOCK, '-p', '5499', '-U', 'postgres', '-d', DB, '-qAt', '-v', 'ON_ERROR_STOP=1'], { input: pre + '\n' + q + ';\n', stdio: ['pipe', 'pipe', 'pipe'] }).toString().trim();
    return { ok: true, out };
  } catch (e) { return { ok: false, err: (e.stderr.toString().match(/ERROR:\s+(.*)/) || [, 'error'])[1] }; }
}
const lit = v => v === null || v === undefined ? 'null' : `'${String(v).replace(/'/g, "''")}'`;
function json(res, status, body) { res.writeHead(status, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(body)); }
async function body(req) { let s = ''; for await (const c of req) s += c; return s ? JSON.parse(s) : {}; }
function bearer(req) { const h = req.headers.authorization || ''; return h.startsWith('Bearer ') ? h.slice(7) : (req.headers.apikey || null); }

const ARGTYPES = {}; // fn -> [[name, type]]
function argTypes(fn) {
  if (!ARGTYPES[fn]) {
    const r = sql(`select array_to_string(proargnames, ',') || '|' || pg_get_function_identity_arguments(oid) from pg_proc where proname = ${lit(fn)}`);
    const [names, sig] = r.out.split('|');
    ARGTYPES[fn] = names ? names.split(',').map((n, i) => [n, sig.split(', ')[i].split(' ').slice(1).join(' ')]) : [];
  }
  return ARGTYPES[fn];
}

async function supabase(req, res, url) {
  const p = url.pathname;
  if (p === '/auth/v1/token') {
    const b = await body(req);
    if (url.searchParams.get('grant_type') === 'password') {
      const u = passwords.get(b.email);
      if (!u || u.password !== b.password) return json(res, 400, { error_description: 'Invalid login credentials' });
      return json(res, 200, { access_token: u.id, refresh_token: 'r-' + u.id, expires_in: 3600 });
    }
    return json(res, 200, { access_token: b.refresh_token.slice(2), refresh_token: b.refresh_token, expires_in: 3600 });
  }
  if (p === '/auth/v1/logout') return json(res, 204, {});
  if (p === '/auth/v1/user') { const t = bearer(req); return [...passwords.values()].some(u => u.id === t) ? json(res, 200, { id: t }) : json(res, 401, {}); }
  if (p.startsWith('/auth/v1/admin/users')) {
    if (bearer(req) !== SERVICE) return json(res, 401, {});
    const id = p.split('/')[5];
    if (req.method === 'POST') {
      const b = await body(req);
      if (passwords.has(b.email)) return json(res, 422, { msg: 'A user with this email address has already been registered' });
      const nid = crypto.randomUUID(); passwords.set(b.email, { id: nid, password: b.password });
      sql(`insert into auth.users (id, email) values (${lit(nid)}, ${lit(b.email)})`); return json(res, 200, { id: nid });
    }
    if (req.method === 'PUT') { const b = await body(req); for (const u of passwords.values()) if (u.id === id) u.password = b.password; return json(res, 200, {}); }
    if (req.method === 'DELETE') { for (const [k, u] of passwords) if (u.id === id) passwords.delete(k); sql(`delete from auth.users where id = ${lit(id)}`); return json(res, 200, {}); }
  }
  if (p.startsWith('/rest/v1/rpc/')) {
    const fn = p.split('/').pop(); const b = await body(req); const t = bearer(req);
    const role = t === SERVICE ? 'service_role' : t === ANON ? 'anon' : 'authenticated';
    const val = (v, ty) => v === null ? 'null' : ty.endsWith('[]') ? `(select array_agg(x) from jsonb_array_elements_text(${lit(JSON.stringify(v))}::jsonb) x)::${ty}` : `${lit(typeof v === 'object' ? JSON.stringify(v) : v)}::${ty}`;
    const args = argTypes(fn).filter(([n]) => n in b).map(([n, ty]) => `${n} => ${val(b[n], ty)}`);
    const r = sql(`select to_jsonb(${fn}(${args.join(', ')}))`, role, role === 'authenticated' ? t : null);
    return r.ok ? json(res, 200, r.out ? JSON.parse(r.out) : null) : json(res, 400, { message: r.err });
  }
  if (p === '/rest/v1/profiles') {
    if (bearer(req) !== SERVICE) return json(res, 401, {});
    const where = []; for (const [k, v] of url.searchParams) if (!['select', 'limit'].includes(k)) where.push(`${k} = ${lit(v.replace(/^eq\./, ''))}`);
    const r = sql(`select coalesce(jsonb_agg(to_jsonb(p)), '[]') from (select * from profiles ${where.length ? 'where ' + where.join(' and ') : ''} limit ${Number(url.searchParams.get('limit') || 100)}) p`);
    return json(res, 200, JSON.parse(r.out));
  }
  json(res, 404, { message: 'fake supabase: no route ' + p });
}

process.env.SUPABASE_URL = `http://localhost:${PORT}/sb`; process.env.SUPABASE_ANON_KEY = ANON; process.env.SUPABASE_SERVICE_ROLE_KEY = SERVICE;
http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://x');
  try {
    if (url.pathname.startsWith('/sb/')) { url.pathname = url.pathname.slice(3); return await supabase(req, res, url); }
    if (url.pathname.startsWith('/api/')) {   // stand-in for Netlify functions
      globalThis.Netlify = { env: { get: k => process.env[k] } };
      const mod = await import(path.join(WEB, 'netlify/functions', url.pathname.slice(5) + '.mjs'));
      const b = req.method === 'GET' ? undefined : await (async () => { let s = ''; for await (const c of req) s += c; return s; })();
      const r = await mod.default(new Request('http://x' + req.url, { method: req.method, headers: req.headers, body: b }));
      res.writeHead(r.status, { 'Content-Type': 'application/json' }); return res.end(await r.text());
    }
    const f = path.join(WEB, 'public', url.pathname === '/' ? 'index.html' : url.pathname);
    res.writeHead(200, { 'Content-Type': f.endsWith('.js') ? 'text/javascript' : f.endsWith('.css') ? 'text/css' : 'text/html' });
    res.end(fs.readFileSync(f));
  } catch (e) { json(res, 500, { error: e.message }); }
}).listen(Number(PORT), () => console.log('fake stack on ' + PORT));
