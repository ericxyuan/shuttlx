import { ApiError, base64url, endpoint, json, randomToken } from '@/lib/server';
import { appleAuthorizationURL } from '@/lib/apple';

function safeReturn(value: string | null) {
  if (!value || value.startsWith('//')) return '/';
  if (value.startsWith('/')) return value;
  if (value.startsWith('shuttlx://website-paired')) return value;
  return '/';
}
export const GET = endpoint(async request => {
  const returnTo = safeReturn(new URL(request.url).searchParams.get('return_to'));
  const state = base64url(JSON.stringify({ nonce: randomToken(), returnTo }));
  const target = appleAuthorizationURL(state);
  if (!target) throw new ApiError(503, 'Sign in with Apple is not configured for this website yet.');
  return new Response(null, { status: 302, headers: { Location: target, 'Set-Cookie': `shuttlx_oauth_state=${state}; Max-Age=600; Path=/; HttpOnly; Secure; SameSite=Lax` } });
});
