import { ApiError, db, endpoint, fromBase64url, randomToken, sha } from '@/lib/server';
import { exchangeAppleCode, verifyAppleIDToken } from '@/lib/apple';

function cookieValue(header: string | null, name: string) { return header?.split(';').map(x => x.trim()).find(x => x.startsWith(name + '='))?.slice(name.length + 1) ?? null; }
function safeReturn(value: unknown) { if (typeof value === 'string' && (value.startsWith('/') && !value.startsWith('//'))) return value; return '/'; }
async function callback(request: Request) {
  const values = new URLSearchParams(request.method === 'POST' ? await request.text() : new URL(request.url).search);
  const code = values.get('code'), state = values.get('state'); if (!code || !state) throw new ApiError(400, 'Apple sign-in was incomplete.');
  const saved = cookieValue(request.headers.get('cookie'), 'shuttlx_oauth_state'); if (!saved || saved !== state) throw new ApiError(400, 'Apple sign-in expired. Start again.');
  let returnTo = '/'; try { returnTo = safeReturn(JSON.parse(new TextDecoder().decode(fromBase64url(state))).returnTo); } catch { throw new ApiError(400, 'Apple sign-in state is invalid.'); }
  const token = await exchangeAppleCode(code); if (!token.id_token) throw new ApiError(400, 'Apple did not return an identity token.');
  const identity = await verifyAppleIDToken(token.id_token);
  let name: string | null = null;
  const userValue = values.get('user'); if (userValue) { try { const user = JSON.parse(userValue) as { name?: { firstName?: string; lastName?: string } }; name = [user.name?.firstName, user.name?.lastName].filter(Boolean).join(' ') || null; } catch {} }
  const now = Date.now();
  await db().prepare('INSERT INTO accounts(id,provider,provider_subject,email,name,created_at,updated_at) VALUES (?,?,?,?,?,?,?) ON CONFLICT(provider_subject) DO UPDATE SET email = COALESCE(excluded.email,accounts.email), name = COALESCE(excluded.name,accounts.name), updated_at = excluded.updated_at').bind(`apple:${identity.sub}`, 'apple', identity.sub, identity.email ?? null, name, now, now).run();
  const account = await db().prepare('SELECT id FROM accounts WHERE provider_subject = ?').bind(identity.sub).first<{ id: string }>(); if (!account) throw new ApiError(503, 'Your account could not be created.');
  const session = randomToken(); await db().prepare('INSERT INTO auth_sessions(id,account_id,expires_at,created_at,user_agent) VALUES (?,?,?,?,?)').bind(await sha(session), account.id, now + 30 * 86_400_000, now, request.headers.get('user-agent')).run();
  const headers = new Headers({ Location: returnTo }); headers.append('Set-Cookie', `shuttlx_session=${session}; Max-Age=2592000; Path=/; HttpOnly; Secure; SameSite=Lax; Priority=High`); headers.append('Set-Cookie', 'shuttlx_oauth_state=; Max-Age=0; Path=/; HttpOnly; Secure; SameSite=Lax');
  return new Response(null, { status: 303, headers });
}
export const POST = endpoint(callback);
export const GET = endpoint(callback);
