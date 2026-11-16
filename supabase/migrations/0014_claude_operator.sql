-- TFD app — Claude as operator (Kenny, Nov 15 2026): Kenny texts Claude, Claude runs the app's own functions through
-- direct database access. The built-in "Claude" user gets an internal ID with no login behind it (no auth user exists for it,
-- so nobody can sign in as Claude on the website) and acts with admin rights. Its actions log as "Claude".
update profiles set auth_id = '00000000-0000-4000-8000-00000000c1de' where role = 'claude' and auth_id is null;

create or replace function tfd_require(p_need text) returns profiles language plpgsql stable security definer set search_path = public as $$
declare me profiles;
begin
  select * into me from profiles where auth_id = auth.uid() and active;
  if me.id is null then raise exception 'Sign in required' using errcode = '28000'; end if;
  if me.role = 'claude' then me.role := 'admin'; end if;   -- the operator account acts as an admin; name stays "Claude" in every log line
  if p_need = 'admin' and me.role <> 'admin' then raise exception 'Admins only' using errcode = '42501'; end if;
  return me;
end $$;
