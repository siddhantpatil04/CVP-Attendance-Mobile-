// Supabase Edge Function: translate-report
// ------------------------------------------------------------------
// Translates Daily Report text written in Marathi / Hindi into English (Google Cloud Translation v2).
//   { mode: "preview", texts: { work_description: "...", ... } }  -> { lang, en: { work_description: "..." } }   (live preview while typing)
//   { mode: "report",  report_id: 123 }                           -> translates every field of the report and stores it
//                                                                    in daily_report_sites.translations (employee: own report; Admin / HR: any)
//
// The API key exists ONLY as a Supabase secret:  supabase secrets set GOOGLE_TRANSLATE_API_KEY=...
// It is never in the app, the APK, the web build or the repository.
// Only signed-in users can call it; at most 30 calls per user per minute.
//
// Deploy:  supabase functions deploy translate-report
// ------------------------------------------------------------------
import { createClient } from 'npm:@supabase/supabase-js@2';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

const FIELDS = ['sub_work', 'work_going_on', 'work_description', 'comment_1', 'comment_2', 'comment_3', 'remarks'];
const MAX_CHARS = 2000;
const PER_MINUTE = 30;
const DEVANAGARI = /[ऀ-ॿ]/;

// Engineering words that must come out right (Devanagari spelling -> English). Latin words (RCC, ESR, MBR, WTP, STP, RMC) are kept as they are.
const GLOSSARY: Record<string, string> = {
  'शटरिंग': 'shuttering', 'सेंटरिंग': 'centering', 'आरसीसी': 'RCC', 'आर सी सी': 'RCC', 'रीइन्फोर्समेंट': 'reinforcement', 'रिइन्फोर्समेंट': 'reinforcement',
  'सळई': 'reinforcement bars', 'क्युरिंग': 'curing', 'क्यूरिंग': 'curing', 'क्यूब टेस्ट': 'cube test', 'क्युब टेस्ट': 'cube test', 'क्यूब': 'cube',
  'आरएमसी': 'RMC', 'बे': 'bay', 'लिफ्ट': 'lift', 'ईएसआर': 'ESR', 'एमबीआर': 'MBR', 'डब्ल्यूटीपी': 'WTP', 'एसटीपी': 'STP',
  'पंप हाऊस': 'pump house', 'पंप हाउस': 'pump house', 'पम्प हाऊस': 'pump house', 'काँक्रीट': 'concrete', 'कॉंक्रीट': 'concrete', 'कॉंक्रिट': 'concrete',
};
const KEYS = Object.keys(GLOSSARY).sort((a, b) => b.length - a.length);
const protect = (s: string) => KEYS.reduce((t, k) => t.split(k).join(`<span translate="no">${GLOSSARY[k]}</span>`), s);
const clean = (s: string) => s.replace(/<\/?span[^>]*>/g, '').replace(/&#39;/g, "'").replace(/&quot;/g, '"').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&amp;/g, '&');

async function translate(texts: string[], key: string): Promise<{ en: string; lang: string }[]> {
  const res = await fetch(`https://translation.googleapis.com/language/translate/v2?key=${encodeURIComponent(key)}`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ q: texts.map(protect), target: 'en', format: 'html' }),
  });
  if (!res.ok) throw new Error(`Translation service error (${res.status})`);
  const data = await res.json();
  return (data.data?.translations ?? []).map((x: any) => ({ en: clean(String(x.translatedText ?? '')), lang: String(x.detectedSourceLanguage ?? '') }));
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405);

  const url = Deno.env.get('SUPABASE_URL')!;
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY')!;
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  const apiKey = Deno.env.get('GOOGLE_TRANSLATE_API_KEY');
  if (!apiKey) return json({ error: 'Translation is not set up on the server yet' }, 503);

  const authHeader = req.headers.get('Authorization') ?? '';
  const userClient = createClient(url, anonKey, { global: { headers: { Authorization: authHeader } } });
  const { data: u } = await userClient.auth.getUser();
  if (!u?.user) return json({ error: 'Sign in first' }, 401);
  const admin = createClient(url, serviceKey);

  const { data: me } = await admin.from('profiles').select('id, role, active').eq('id', u.user.id).single();
  if (!me?.active) return json({ error: 'Account is not active' }, 403);

  // rate limit
  const since = new Date(Date.now() - 60_000).toISOString();
  const { count } = await admin.from('translate_usage').select('id', { count: 'exact', head: true }).eq('user_id', me.id).gte('at', since);
  if ((count ?? 0) >= PER_MINUTE) return json({ error: 'Too many translations. Wait a minute and try again' }, 429);
  await admin.from('translate_usage').insert({ user_id: me.id });

  let body: any;
  try { body = await req.json(); } catch { return json({ error: 'Bad request' }, 400); }

  try {
    // ---- live preview while typing: nothing is stored
    if (body.mode === 'preview') {
      const entries = Object.entries(body.texts ?? {})
        .filter(([k, v]) => FIELDS.includes(k) && typeof v === 'string' && (v as string).trim() && DEVANAGARI.test(v as string))
        .slice(0, 8) as [string, string][];
      if (!entries.length) return json({ lang: 'en', en: {} });
      const out = await translate(entries.map(([, v]) => v.slice(0, MAX_CHARS)), apiKey);
      const en: Record<string, string> = {};
      entries.forEach(([k], i) => { en[k] = out[i]?.en ?? ''; });
      return json({ lang: out[0]?.lang || 'mr', en });
    }

    // ---- translate a whole report and store the English next to the original
    if (body.mode === 'report') {
      const reportId = Number(body.report_id);
      if (!reportId) return json({ error: 'report_id is needed' }, 400);
      const { data: rep } = await admin.from('daily_reports').select('id, user_id, status').eq('id', reportId).single();
      if (!rep) return json({ error: 'Report not found' }, 404);
      const isAdminUser = me.role === 'Admin' || me.role === 'HR';
      if (rep.user_id !== me.id && !isAdminUser) return json({ error: 'Not allowed' }, 403);

      const { data: rows } = await admin.from('daily_report_sites').select('*').eq('report_id', reportId);
      let changed = 0;
      for (const row of rows ?? []) {
        const tr: Record<string, any> = { ...(row.translations ?? {}) };
        const todo: [string, string][] = [];
        for (const f of FIELDS) {
          const txt = String(row[f] ?? '').trim();
          if (!txt) { delete tr[f]; continue; }
          if (!DEVANAGARI.test(txt)) { delete tr[f]; continue; }                 // already English: nothing to translate
          if (tr[f]?.src === txt && tr[f]?.en) continue;                          // already translated (and unchanged)
          todo.push([f, txt]);
        }
        if (todo.length) {
          const out = await translate(todo.map(([, t]) => t.slice(0, MAX_CHARS)), apiKey);
          todo.forEach(([f, txt], i) => { tr[f] = { lang: out[i]?.lang || 'mr', en: out[i]?.en ?? '', src: txt }; });
          changed += todo.length;
        }
        if (JSON.stringify(tr) !== JSON.stringify(row.translations ?? {})) {
          await admin.from('daily_report_sites').update({ translations: tr }).eq('id', row.id);
        }
      }
      return json({ ok: true, translated: changed });
    }
    return json({ error: 'Unknown mode' }, 400);
  } catch (e) {
    return json({ error: e instanceof Error ? e.message : 'Translation failed' }, 502);
  }
});
