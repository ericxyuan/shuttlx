import { endpoint,json,owner,sameOrigin,body,saveSession,listSessions,rateLimit,ApiError } from '@/lib/server';
export const GET=endpoint(async r=>json(await listSessions(await owner(r))));
export const POST=endpoint(async r=>{sameOrigin(r);const id=await owner(r);await rateLimit('import:'+id,30);const input=await body(r);const values=Array.isArray(input)?input:[input];if(values.length>10)throw new ApiError(400,'Import up to ten sessions at a time.');const results=[];for(const value of values)results.push(await saveSession(id,value));return json({saved:results});});
