// Netlify function. Public connection details for the browser. The anon/publishable key is safe to share:
// the database itself checks every request against the signed-in person's role.
export default async () => new Response(JSON.stringify({
  url: Netlify.env.get('SUPABASE_URL') || null, anonKey: Netlify.env.get('SUPABASE_ANON_KEY') || null,
}), { headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' } });
export const config = { path: '/api/config' };
