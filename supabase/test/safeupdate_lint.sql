-- Supabase loads pg-safeupdate for app sessions: an UPDATE or DELETE with no WHERE fails. Flag any in our functions.
select p.proname, left(regexp_replace(m[1], '\s+', ' ', 'g'), 120) stmt
from pg_proc p join pg_namespace n on n.oid = p.pronamespace,
     regexp_matches(pg_get_functiondef(p.oid), '(?:^|[;\n]|then|else|loop|begin)\s*((update|delete\s+from)\s+[a-z_]+\s+([a-z_]+\s+)?set[^;]*;|delete\s+from\s+[a-z_]+[^;]*;)', 'gi') m
where n.nspname = 'public' and p.proname like 'tfd%' and m[1] !~* '\swhere\s';
