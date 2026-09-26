import { db,endpoint,json,owner,sameOrigin,body } from '@/lib/server';
import { preferencesSchema } from '@/lib/domain';
export const PUT=endpoint(async r=>{sameOrigin(r);const id=await owner(r);const value=preferencesSchema.parse(await body(r));await db().prepare('INSERT INTO preferences(owner,payload) VALUES (?,?) ON CONFLICT(owner) DO UPDATE SET payload=excluded.payload').bind(id,JSON.stringify(value)).run();return json(value);});
