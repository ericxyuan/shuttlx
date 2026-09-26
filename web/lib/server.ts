import { env } from 'cloudflare:workers';
import { getChatGPTUser } from '@/app/chatgpt-auth';
import { cookies } from 'next/headers';
import { defaultPreferences, preferencesSchema, sessionSchema, type Preferences, type Session } from './domain';
export class ApiError extends Error{constructor(public status:number,message:string){super(message);}}
export function db(){if(!env.DB)throw new ApiError(503,'Session storage is unavailable. Please try again.');return env.DB;}
type WebAccount={id:string;email:string|null;name:string|null};
function cookieValue(header:string|undefined,name:string){return header?.split(';').map(x=>x.trim()).find(x=>x.startsWith(name+'='))?.slice(name.length+1)??null;}
export async function accountFromRequest(request:Request):Promise<WebAccount|null>{
  const session=cookieValue(request.headers.get('cookie')??undefined,'shuttlx_session');
  if(session){const row=await db().prepare('SELECT a.id,a.email,a.name FROM auth_sessions s JOIN accounts a ON a.id=s.account_id WHERE s.id = ? AND s.expires_at > ?').bind(await sha(session),Date.now()).first<WebAccount>();if(row)return row;}
  const user=await getChatGPTUser();
  return user?{id:user.userId,email:user.email,name:user.fullName??user.displayName}:null;
}
export async function pageAccount():Promise<WebAccount|null>{
  const store=await cookies(); const session=store.get('shuttlx_session')?.value;
  if(session){const row=await db().prepare('SELECT a.id,a.email,a.name FROM auth_sessions s JOIN accounts a ON a.id=s.account_id WHERE s.id = ? AND s.expires_at > ?').bind(await sha(session),Date.now()).first<WebAccount>();if(row)return row;}
  const user=await getChatGPTUser(); return user?{id:user.userId,email:user.email,name:user.fullName??user.displayName}:null;
}
export async function owner(request?:Request){const user=await (request?accountFromRequest(request):pageAccount());if(!user)throw new ApiError(401,'Sign in to access your sessions.');return user.id;}
export function sameOrigin(request:Request){const origin=request.headers.get('origin');if(!origin||origin!==new URL(request.url).origin)throw new ApiError(403,'Open ShuttlX to make this change.');}
export async function body(request:Request){if(!request.headers.get('content-type')?.includes('application/json'))throw new ApiError(415,'Send JSON data.');const reader=request.body?.getReader();if(!reader)throw new ApiError(400,'Missing request body.');let size=0;const chunks:Uint8Array[]=[];while(true){const {done,value}=await reader.read();if(done)break;size+=value.byteLength;if(size>1500000){await reader.cancel();throw new ApiError(413,'This upload is too large. Import one smaller session at a time.');}chunks.push(value);}const buffer=new Uint8Array(size);let offset=0;for(const chunk of chunks){buffer.set(chunk,offset);offset+=chunk.length;}try{return JSON.parse(new TextDecoder().decode(buffer));}catch{throw new ApiError(400,'This file is not valid JSON.');}}
export async function sha(value:string){return Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(value))),b=>b.toString(16).padStart(2,'0')).join('');}
export function randomToken(){return crypto.randomUUID().replaceAll('-','')+crypto.randomUUID().replaceAll('-','');}
export function randomBytes(length=32){const bytes=new Uint8Array(length);crypto.getRandomValues(bytes);return bytes;}
export function base64url(data:Uint8Array|string){const bytes=typeof data==='string'?new TextEncoder().encode(data):data;let value='';for(const byte of bytes)value+=String.fromCharCode(byte);return btoa(value).replaceAll('+','-').replaceAll('/','_').replaceAll('=','');}
export function fromBase64url(value:string){const normalized=value.replaceAll('-','+').replaceAll('_','/')+ '='.repeat((4-value.length%4)%4);const binary=atob(normalized);return Uint8Array.from(binary,c=>c.charCodeAt(0));}
export function json(value:unknown,status=200){return Response.json(value,{status,headers:{'Cache-Control':'no-store','X-Content-Type-Options':'nosniff'}});}
export function endpoint(fn:(r:Request)=>Promise<Response>){return async(r:Request)=>{try{return await fn(r);}catch(e){if(e instanceof ApiError)return json({error:e.message},e.status);if(e&&typeof e==='object'&&'issues'in e)return json({error:'Some values are invalid. Check the session file or settings.'},400);console.error('ShuttlX request failed',e instanceof Error?e.message:'Storage error');return json({error:'Could not complete this request. Your existing data is preserved.'},503);}};}
export async function preferences(id:string):Promise<Preferences>{const row=await db().prepare('SELECT payload FROM preferences WHERE owner = ?').bind(id).first<{payload:string}>();return row?preferencesSchema.parse(JSON.parse(row.payload)):structuredClone(defaultPreferences);}
export async function saveSession(id:string,input:unknown){const parsed=sessionSchema.parse(input);parsed.shots.sort((a,b)=>a.timestamp-b.timestamp||a.id.localeCompare(b.id));const payload=JSON.stringify(parsed);if(new TextEncoder().encode(payload).length>1500000)throw new ApiError(413,'Session exceeds the upload limit.');const digest=await sha(payload);await db().prepare('INSERT INTO sessions (owner,id,started_at,payload,digest) VALUES (?,?,?,?,?) ON CONFLICT(owner,id) DO NOTHING').bind(id,parsed.id,parsed.startedAt,payload,digest).run();const stored=await db().prepare('SELECT digest FROM sessions WHERE owner = ? AND id = ?').bind(id,parsed.id).first<{digest:string}>();if(stored?.digest!==digest)throw new ApiError(409,'This session ID already belongs to different saved data.');return parsed.id;}
export async function device(request:Request){const token=request.headers.get('authorization')?.match(/^Bearer ([a-f0-9]{64})$/)?.[1];if(!token)throw new ApiError(401,'Pair this Watch again.');const row=await db().prepare('SELECT id,owner FROM devices WHERE token_hash = ?').bind(await sha(token)).first<{id:string;owner:string}>();if(!row)throw new ApiError(401,'This Watch is disconnected. Pair it again.');return row;}
export async function rateLimit(key:string,max=12){const now=Date.now(),window=Math.floor(now/600000);const row=await db().prepare('INSERT INTO rate_limits (key,attempts,expires_at) VALUES (?,1,?) ON CONFLICT(key) DO UPDATE SET attempts = attempts + 1 RETURNING attempts').bind(await sha(key+window),now+600000).first<{attempts:number}>();if((row?.attempts??max+1)>max)throw new ApiError(429,'Too many attempts. Try again in ten minutes.');await db().prepare('DELETE FROM rate_limits WHERE expires_at < ?').bind(now).run();}
export async function listSessions(id:string){const rows=await db().prepare('SELECT payload FROM sessions WHERE owner = ? ORDER BY started_at DESC LIMIT 1000').bind(id).all<{payload:string}>();return rows.results.map(x=>JSON.parse(x.payload) as Session);}
