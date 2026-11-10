// Creating logins and changing passwords needs Supabase's secret service key, so it happens here
// on the server, never in the browser.
//   GET   /api/users            -> { setupNeeded }
//   POST  /api/users            -> create a person (first one becomes the admin; after that, admins only)
//   PATCH /api/users            -> set a new password for a person (admins only)
const STAFF_DOMAIN = 'staff.theframedrop.local';
const URL_ = process.env.SUPABASE_URL;
const SERVICE = process.env.SUPABASE_SERVICE_ROLE_KEY;

// Works with both Supabase key styles: new "sb_secret_..." keys go only in the apikey header;
// older JWT-style service_role keys also go in Authorization.
const svcHeaders = () => ({ apikey: SERVICE, ...(SERVICE && SERVICE.startsWith('eyJ') ? { Authorization: 'Bearer ' + SERVICE } : {}), 'Content-Type': 'application/json' });
const svc = (path, method = 'GET', body) => fetch(URL_ + path, {
  method, headers: svcHeaders(),
  body: body ? JSON.stringify(body) : undefined,
});
const toLogin = u => (u || '').includes('@') ? u.trim().toLowerCase() : (u || '').trim().toLowerCase() + '@' + STAFF_DOMAIN;

async function caller(req) {
  const h = req.headers.authorization || '';
  if (!h.startsWith('Bearer ')) return null;
  const r = await fetch(URL_ + '/auth/v1/user', { headers: { apikey: SERVICE, Authorization: h } });
  if (!r.ok) return null;
  const u = await r.json();
  const p = await (await svc(`/rest/v1/profiles?auth_id=eq.${encodeURIComponent(u.id)}&active=eq.true&select=id,name,role`)).json();
  return p[0] ? { authId: u.id, ...p[0] } : null;
}
async function setupNeeded() {
  const r = await (await svc('/rest/v1/profiles?role=eq.admin&select=id&limit=1')).json();
  return !Array.isArray(r) || r.length === 0;
}
const fail = (res, status, error) => res.status(status).json({ error });

module.exports = async (req, res) => {
  res.setHeader('Cache-Control', 'no-store');
  if (!URL_ || !SERVICE) return fail(res, 500, 'The website is missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY in Vercel.');
  try {
    if (req.method === 'GET') return res.status(200).json({ setupNeeded: await setupNeeded() });

    const b = req.body || {};
    if (req.method === 'POST') {
      const first = await setupNeeded();
      const me = first ? null : await caller(req);
      if (!first && (!me || me.role !== 'admin')) return fail(res, 403, 'Admins only');
      if (first && b.role !== 'admin') return fail(res, 400, 'The first person must be an admin');
      const login = (b.login || '').trim();
      if (!login) return fail(res, 400, 'Username or email is required');
      if (!login.includes('@') && !/^[a-z0-9._-]{3,30}$/i.test(login)) return fail(res, 400, 'Usernames are 3–30 letters, numbers, dots, dashes or underscores');
      if (!b.password || String(b.password).length < 8) return fail(res, 400, 'Password must be at least 8 characters');
      // 1) the login
      const cr = await svc('/auth/v1/admin/users', 'POST', { email: toLogin(login), password: String(b.password), email_confirm: true });
      const created = await cr.json();
      if (!cr.ok) return fail(res, 400, /already|registered|exists/i.test(created.msg || created.message || '') ? 'That username or email is already taken' : (created.msg || created.message || 'Could not create the login'));
      // 2) the profile (checks role, duplicate names, and logs it)
      const pr = await svc('/rest/v1/rpc/tfd_create_profile', 'POST', {
        p_actor_auth: me ? me.authId : null, p_auth_id: created.id, p_name: b.name, p_username: login.includes('@') ? null : login, p_role: b.role });
      if (!pr.ok) {
        const e = await pr.json().catch(() => ({}));
        await svc('/auth/v1/admin/users/' + created.id, 'DELETE');   // don't leave an orphan login behind
        return fail(res, 400, e.message || 'Could not add this person');
      }
      return res.status(200).json({ ok: true, id: await pr.json() });
    }

    if (req.method === 'PATCH') {
      const me = await caller(req);
      if (!me || me.role !== 'admin') return fail(res, 403, 'Admins only');
      if (!b.password || String(b.password).length < 8) return fail(res, 400, 'Password must be at least 8 characters');
      const p = await (await svc(`/rest/v1/profiles?id=eq.${Number(b.id)}&select=auth_id,name,role`)).json();
      if (!p[0] || !p[0].auth_id) return fail(res, 400, 'Unknown person');
      const r = await svc('/auth/v1/admin/users/' + p[0].auth_id, 'PUT', { password: String(b.password) });
      if (!r.ok) return fail(res, 400, 'Could not change the password');
      await svc('/rest/v1/rpc/tfd_log_from_server', 'POST', { p_actor_auth: me.authId, p_action: 'password_change', p_summary: 'Password changed for ' + p[0].name });
      return res.status(200).json({ ok: true });
    }
    return fail(res, 405, 'Method not allowed');
  } catch (e) {
    return fail(res, 500, 'Something went wrong: ' + e.message);
  }
};
