// Edge Function send-push: called by a Database Webhook on INSERT into public.notifications.
// Reads the push tokens of THAT user, sends the message through Expo's push service and writes sent_at / push_error on the row.
// Secrets (supabase secrets set ...): PUSH_WEBHOOK_SECRET (required), EXPO_ACCESS_TOKEN (optional). SUPABASE_URL and
// SUPABASE_SERVICE_ROLE_KEY are provided by Supabase. A failure here never affects an approval (the notification row already exists).
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const EXPO_URL = 'https://exp.host/--/api/v2/push/send';

Deno.serve(async (req) => {
  const secret = Deno.env.get('PUSH_WEBHOOK_SECRET');
  if (!secret || req.headers.get('x-webhook-secret') !== secret) return new Response('Unauthorized', { status: 401 });

  let rec: any;
  try { rec = (await req.json())?.record; } catch { return new Response('Bad request', { status: 400 }); }
  if (!rec?.id || !rec?.user_id) return new Response('No record', { status: 400 });

  const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
  const fail = async (msg: string) => {
    await db.from('notifications').update({ push_error: msg.slice(0, 500) }).eq('id', rec.id);
    return new Response(msg, { status: 200 });
  };

  try {
    const { data: tokens, error } = await db.from('push_tokens').select('id, token').eq('user_id', rec.user_id);
    if (error) return await fail(`Could not read tokens: ${error.message}`);
    if (!tokens || tokens.length === 0) return await fail('No phone registered');

    const messages = tokens.map((t: any) => ({
      to: t.token, title: rec.title, body: rec.body, sound: 'default', channelId: 'approvals',
      data: { link: rec.link ?? null, id: rec.id },
    }));
    const headers: Record<string, string> = { 'Content-Type': 'application/json', Accept: 'application/json' };
    const access = Deno.env.get('EXPO_ACCESS_TOKEN');
    if (access) headers.Authorization = `Bearer ${access}`;

    const res = await fetch(EXPO_URL, { method: 'POST', headers, body: JSON.stringify(messages) });
    const json = await res.json().catch(() => ({}));
    if (!res.ok) return await fail(`Expo error ${res.status}`);

    const tickets: any[] = Array.isArray(json?.data) ? json.data : [];
    const errors: string[] = [];
    for (let i = 0; i < tickets.length; i++) {
      const t = tickets[i];
      if (t?.status === 'error') {
        errors.push(t?.details?.error ?? t?.message ?? 'error');
        // the app was uninstalled / the token is dead: forget it
        if (t?.details?.error === 'DeviceNotRegistered') await db.from('push_tokens').delete().eq('id', tokens[i].id);
      }
    }
    if (errors.length === tokens.length) return await fail(errors.join(', '));
    await db.from('notifications').update({ sent_at: new Date().toISOString(), push_error: errors.length ? errors.join(', ') : null }).eq('id', rec.id);
    return new Response('ok');
  } catch (e) {
    return await fail(String((e as Error)?.message ?? e));
  }
});
