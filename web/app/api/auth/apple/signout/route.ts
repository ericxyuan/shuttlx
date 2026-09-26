import { db, endpoint, sha } from '@/lib/server';
function cookieValue(header: string | null) { return header?.split(';').map(x => x.trim()).find(x => x.startsWith('shuttlx_session='))?.slice('shuttlx_session='.length) ?? null; }
export const GET = endpoint(async request => {
  const token = cookieValue(request.headers.get('cookie'));
  if (token) await db().prepare('DELETE FROM auth_sessions WHERE id = ?').bind(await sha(token)).run();
  const returnTo = new URL(request.url).searchParams.get('return_to')?.startsWith('/') ? new URL(request.url).searchParams.get('return_to')! : '/';
  return new Response(null, { status: 302, headers: { Location: returnTo, 'Set-Cookie': 'shuttlx_session=; Max-Age=0; Path=/; HttpOnly; Secure; SameSite=Lax' } });
});
