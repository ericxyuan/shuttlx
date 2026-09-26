import { env } from 'cloudflare:workers';
import { base64url, fromBase64url } from './server';

type AppleConfig = { clientID: string; teamID: string; keyID: string; privateKey: string; redirectURI: string };
function config(): AppleConfig | null {
  const values = env as unknown as Record<string, string | undefined>;
  const clientID = values.APPLE_CLIENT_ID, teamID = values.APPLE_TEAM_ID, keyID = values.APPLE_KEY_ID, privateKey = values.APPLE_PRIVATE_KEY;
  if (!clientID || !teamID || !keyID || !privateKey) return null;
  return { clientID, teamID, keyID, privateKey, redirectURI: values.APPLE_REDIRECT_URI ?? `${values.PUBLIC_BASE_URL ?? ''}/api/auth/apple/callback` };
}
function pemBytes(pem: string) { return fromBase64url(pem.replace(/-----[^-]+-----/g, '').replaceAll(/\s/g, '').replaceAll('+', '-').replaceAll('/', '_')); }
function jsonPart(value: unknown) { return base64url(JSON.stringify(value)); }
function derToRaw(signature: Uint8Array): Uint8Array {
  if (signature.length === 64) return signature;
  let offset = 2; if (signature[1] & 0x80) offset += signature[1] - 0x80;
  if (signature[offset++] !== 0x02) return signature;
  const rLength = signature[offset++]; const r = signature.slice(offset, offset + rLength); offset += rLength;
  if (signature[offset++] !== 0x02) return signature;
  const sLength = signature[offset++]; const s = signature.slice(offset, offset + sLength);
  const out = new Uint8Array(64); out.set(r.slice(Math.max(0, r.length - 32)), 32 - Math.min(32, r.length)); out.set(s.slice(Math.max(0, s.length - 32)), 64 - Math.min(32, s.length)); return out;
}
export function appleAuthorizationURL(state: string) {
  const value = config(); if (!value) return null;
  const params = new URLSearchParams({ client_id: value.clientID, redirect_uri: value.redirectURI, response_type: 'code', response_mode: 'form_post', scope: 'name email', state });
  return `https://appleid.apple.com/auth/authorize?${params}`;
}
export function appleConfigured() { return !!config(); }
export async function appleClientSecret() {
  const value = config(); if (!value) throw new Error('Sign in with Apple is not configured.');
  const header = jsonPart({ alg: 'ES256', kid: value.keyID, typ: 'JWT' });
  const now = Math.floor(Date.now() / 1000);
  const payload = jsonPart({ iss: value.teamID, iat: now, exp: now + 300, aud: 'https://appleid.apple.com', sub: value.clientID });
  const input = new TextEncoder().encode(`${header}.${payload}`);
  const key = await crypto.subtle.importKey('pkcs8', pemBytes(value.privateKey), { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign']);
  const signature = derToRaw(new Uint8Array(await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, key, input)));
  return `${header}.${payload}.${base64url(signature)}`;
}
export function appleClientID() { return config()?.clientID ?? null; }
export async function exchangeAppleCode(code: string) {
  const value = config(); if (!value) throw new Error('Sign in with Apple is not configured.');
  const response = await fetch('https://appleid.apple.com/auth/token', { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body: new URLSearchParams({ client_id: value.clientID, client_secret: await appleClientSecret(), code, grant_type: 'authorization_code', redirect_uri: value.redirectURI }) });
  if (!response.ok) throw new Error('Apple did not accept the sign-in response.');
  return await response.json() as { id_token?: string };
}
export async function verifyAppleIDToken(token: string) {
  const parts = token.split('.'); if (parts.length !== 3) throw new Error('Apple returned an invalid identity token.');
  const header = JSON.parse(new TextDecoder().decode(fromBase64url(parts[0]))) as { kid?: string; alg?: string };
  const payload = JSON.parse(new TextDecoder().decode(fromBase64url(parts[1]))) as { iss?: string; aud?: string; sub?: string; email?: string; exp?: number };
  if (header.alg !== 'RS256' || !header.kid || payload.iss !== 'https://appleid.apple.com' || payload.aud !== appleClientID() || !payload.sub || !payload.exp || payload.exp < Math.floor(Date.now() / 1000)) throw new Error('Apple identity verification failed.');
  const keys = await (await fetch('https://appleid.apple.com/auth/keys')).json() as { keys?: JsonWebKey[] };
  const jwk = keys.keys?.find(k => (k as JsonWebKey & { kid?: string }).kid === header.kid); if (!jwk) throw new Error('Apple signing key is unavailable.');
  const key = await crypto.subtle.importKey('jwk', jwk, { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['verify']);
  const valid = await crypto.subtle.verify({ name: 'RSASSA-PKCS1-v1_5' }, key, fromBase64url(parts[2]), new TextEncoder().encode(`${parts[0]}.${parts[1]}`));
  if (!valid) throw new Error('Apple identity verification failed.');
  return payload;
}
