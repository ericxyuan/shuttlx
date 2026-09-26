import { z } from 'zod';
import { endpoint,json,owner,sameOrigin,body,db } from '@/lib/server';
export const DELETE=endpoint(async r=>{sameOrigin(r);const who=await owner(r);const {id}=z.object({id:z.string().uuid()}).parse(await body(r));await db().prepare('DELETE FROM devices WHERE id = ? AND owner = ?').bind(id,who).run();return json({disconnected:true});});
