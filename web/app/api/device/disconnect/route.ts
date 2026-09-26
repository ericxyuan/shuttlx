import { endpoint,json,device,db } from '@/lib/server';
export const POST=endpoint(async r=>{const d=await device(r);await db().prepare('DELETE FROM devices WHERE id = ?').bind(d.id).run();return json({disconnected:true});});
