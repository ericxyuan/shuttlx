import { endpoint,json,device,body,saveSession,rateLimit,db } from '@/lib/server';
export const POST=endpoint(async r=>{const d=await device(r);await rateLimit('upload:'+d.id,60);const sessionID=await saveSession(d.owner,await body(r));await db().prepare('UPDATE devices SET last_seen = ? WHERE id = ?').bind(Date.now(),d.id).run();return json({accepted:true,sessionID});});
