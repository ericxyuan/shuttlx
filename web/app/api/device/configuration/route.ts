import { endpoint,json,device,preferences,db } from '@/lib/server';
import { watchConfiguration } from '@/lib/domain';
export const GET=endpoint(async r=>{const d=await device(r);await db().prepare('UPDATE devices SET last_seen = ? WHERE id = ?').bind(Date.now(),d.id).run();return json(watchConfiguration(await preferences(d.owner)));});
