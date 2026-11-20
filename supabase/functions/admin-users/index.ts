// Supabase Edge Function: admin-users
// ------------------------------------------------------------------
// Lets HR / Admin manage LOGIN ACCOUNTS from the mobile app:
//   { action: "create", username, full_name, password, department?, role?,
//     shift_start?, shift_end?, site_employee?, email? }
//   { action: "reset_password", user_id, password }
//   { action: "set_active", user_id, active }
//
// It runs on Supabase's servers with the secret service-role key, which
// must NEVER be placed inside the mobile app.
//
// Deploy:  supabase functions deploy admin-users
// Optional secret: supabase secrets set LOGIN_EMAIL_DOMAIN=yourcompany.com
// ------------------------------------------------------------------
import { createClient } from 'npm:@supabase/supabase-js@2';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

const MIN_PASSWORD = 12;
const USERNAME_RE = /^[a-z0-9._-]{2,40}$/;
const TIME_RE = /^([01]\d|2[0-3]):[0-5]\d$/;
const ROLES = ['Employee', 'HR', 'Admin'];

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405);

  const url = Deno.env.get('SUPABASE_URL')!;
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY')!;
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  const emailDomain = (Deno.env.get('LOGIN_EMAIL_DOMAIN') || 'cvp-attendance.app').toLowerCase();

  // 1. Who is calling? (uses the caller's own login token)
  const authHeader = req.headers.get('Authorization') ?? '';
  const caller = createClient(url, anonKey, { global: { headers: { Authorization: authHeader } } });
  const { data: who, error: whoErr } = await caller.auth.getUser();
  if (whoErr || !who?.user) return json({ error: 'Not signed in' }, 401);

  const admin = createClient(url, serviceKey, { auth: { persistSession: false } });
  const { data: me } = await admin.from('profiles').select('*').eq('id', who.user.id).single();
  if (!me || !me.active || !['HR', 'Admin'].includes(me.role)) {
    return json({ error: 'Only HR / Admin can manage accounts' }, 403);
  }

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ error: 'Invalid request' }, 400);
  }

  const audit = (action: string, detail: string) =>
    admin.from('audit_log').insert({ actor_id: me.id, action, detail });

  // Loads the target account. HR may only manage employees (and their own account);
  // HR / Admin accounts can be managed by an Admin only.
  const target = async (id: unknown) => {
    if (typeof id !== 'string') throw new Error('user_id is required');
    const { data } = await admin.from('profiles').select('*').eq('id', id).single();
    if (!data) throw new Error('User not found');
    if (!['Admin', 'HR'].includes(me.role) && data.id !== me.id && data.role !== 'Employee') {
      throw new Error('Only an Admin can change HR / Admin accounts');
    }
    return data;
  };

  try {
    switch (body.action) {
      // ------------------------------------------------------------ create
      case 'create': {
        const username = String(body.username ?? '').trim().toLowerCase();
        const fullName = String(body.full_name ?? '').trim();
        const password = String(body.password ?? '');
        const role = String(body.role ?? 'Employee');
        const department = String(body.department ?? '').trim() || null;
        const shiftStart = String(body.shift_start ?? '09:00');
        const shiftEnd = String(body.shift_end ?? '18:00');
        const site = Boolean(body.site_employee);
        const email = String(body.email ?? '').trim().toLowerCase() || `${username}@${emailDomain}`;

        if (!USERNAME_RE.test(username)) return json({ error: 'Username may contain letters, numbers, dot, dash and underscore (2-40 characters).' }, 400);
        if (!fullName) return json({ error: 'Enter the full name.' }, 400);
        if (password.length < MIN_PASSWORD) return json({ error: `Password must be at least ${MIN_PASSWORD} characters.` }, 400);
        if (!ROLES.includes(role)) return json({ error: 'Invalid role' }, 400);
        if (role !== 'Employee' && !['Admin', 'HR'].includes(me.role)) return json({ error: 'Only an Admin can create HR or Admin accounts' }, 403);
        if (!TIME_RE.test(shiftStart) || !TIME_RE.test(shiftEnd) || shiftEnd <= shiftStart) {
          return json({ error: 'Shift end must be after shift start.' }, 400);
        }
        const { data: taken } = await admin.from('profiles').select('id').eq('username', username).maybeSingle();
        if (taken) return json({ error: 'Username already exists.' }, 409);

        const { data: created, error } = await admin.auth.admin.createUser({
          email,
          password,
          email_confirm: true,
          user_metadata: { username, full_name: fullName, department },
        });
        if (error || !created.user) {
          const msg = /already|registered|exists/i.test(error?.message ?? '') ? 'This e-mail is already used by another account.' : (error?.message ?? 'Could not create the login');
          return json({ error: msg }, 400);
        }

        // The database trigger has created the profile; now set role / shift / site access
        const { error: upErr } = await admin.from('profiles').update({
          username, full_name: fullName, department, role,
          shift_start: shiftStart, shift_end: shiftEnd, site_employee: site, active: true,
        }).eq('id', created.user.id);
        if (upErr) {
          await admin.auth.admin.deleteUser(created.user.id); // roll back
          return json({ error: upErr.message }, 400);
        }
        await audit('CREATE_EMPLOYEE', `${username} (${role})`);
        return json({ ok: true, user_id: created.user.id, username, email });
      }

      // ------------------------------------------------------------ reset password
      case 'reset_password': {
        const t = await target(body.user_id);
        const password = String(body.password ?? '');
        if (password.length < MIN_PASSWORD) return json({ error: `Password must be at least ${MIN_PASSWORD} characters.` }, 400);
        const { error } = await admin.auth.admin.updateUserById(t.id, { password });
        if (error) return json({ error: error.message }, 400);
        await audit('RESET_PASSWORD', t.username);
        return json({ ok: true });
      }

      // ------------------------------------------------------------ activate / deactivate
      case 'set_active': {
        const t = await target(body.user_id);
        const active = Boolean(body.active);
        if (t.id === me.id && !active) return json({ error: 'You cannot deactivate your own account.' }, 400);
        const { error: upErr } = await admin.from('profiles').update({ active }).eq('id', t.id);
        if (upErr) return json({ error: upErr.message }, 400);
        // Ban blocks new sign-ins; existing sessions are rejected by the database rules
        const { error } = await admin.auth.admin.updateUserById(t.id, { ban_duration: active ? 'none' : '876000h' });
        if (error) return json({ error: error.message }, 400);
        await audit('UPDATE_ACCESS', `${t.username} active=${active}`);
        return json({ ok: true });
      }

      default:
        return json({ error: 'Unknown action' }, 400);
    }
  } catch (e) {
    return json({ error: e instanceof Error ? e.message : String(e) }, 400);
  }
});
