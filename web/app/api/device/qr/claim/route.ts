import { z } from 'zod';
import { ApiError, body, db, endpoint, json, owner, randomToken, rateLimit, sameOrigin, sha } from '@/lib/server';

const inputSchema = z.object({ deviceID: z.string().uuid(), nonce: z.string().regex(/^[A-Za-z0-9_-]{24,64}$/), name: z.string().trim().min(1).max(60) });

export const POST = endpoint(async request => {
  sameOrigin(request);
  const account = await owner(request);
  await rateLimit('qr-claim:' + (request.headers.get('cf-connecting-ip') ?? 'local'), 8);
  const { deviceID, nonce, name } = inputSchema.parse(await body(request));
  const now = Date.now();
  const existing = await db().prepare('SELECT owner FROM devices WHERE id = ?').bind(deviceID).first<{ owner: string }>();
  if (existing && existing.owner !== account) throw new ApiError(409, 'This Watch is already connected to another account.');
  try {
    await db().prepare('INSERT INTO qr_claims(nonce_hash,device_id,account_id,claimed_at) VALUES (?,?,?,?)').bind(await sha(nonce), deviceID, account, now).run();
  } catch {
    throw new ApiError(409, 'This pairing QR code has already been used. Show a new QR code on the Watch.');
  }
  const token = randomToken();
  if (existing) {
    await db().prepare('UPDATE devices SET name = ?, token_hash = ?, last_seen = ? WHERE id = ? AND owner = ?').bind(name, await sha(token), now, deviceID, account).run();
  } else {
    await db().prepare('INSERT INTO devices(id,owner,name,token_hash,last_seen,created_at) VALUES (?,?,?,?,?,?)').bind(deviceID, account, name, await sha(token), now, now).run();
  }
  const base = new URL(request.url).origin;
  return json({ baseURL: base, deviceID, token, redirect: `shuttlx://website-paired?base=${encodeURIComponent(btoa(base).replaceAll('+','-').replaceAll('/','_').replaceAll('=',''))}&device=${encodeURIComponent(deviceID)}&token=${encodeURIComponent(token)}` });
});
