// Public connection details for the browser. The anon key is safe to share: the database itself
// checks every request against the signed-in person's role.
module.exports = (req, res) => {
  res.setHeader('Cache-Control', 'no-store');
  res.status(200).json({ url: process.env.SUPABASE_URL || null, anonKey: process.env.SUPABASE_ANON_KEY || null });
};
