import { z } from 'zod';
const positive = z.number().finite().min(0);
export const shotTypes = ['smash','clear','drop','drive','lift','net','serve','unknown'] as const;
export const shotSchema = z.object({id:z.string().uuid().transform(x=>x.toLowerCase()), timestamp:positive.max(172800), type:z.enum(shotTypes), hand:z.enum(['forehand','backhand','unknown']),position:z.enum(['overhead','sidearm','underarm','unknown']),tactical:z.enum(['attack','defence','neutral','unknown']),confidence:positive.max(1),handConfidence:positive.max(1),positionConfidence:positive.max(1),estimatedSwingSpeed:positive.max(1000).nullish(),peakRotation:positive.max(10000),peakAcceleration:positive.max(10000),duration:positive.max(30)});
export const sessionSchema = z.object({id:z.string().uuid().transform(x=>x.toLowerCase()),startedAt:z.string().datetime({offset:true}),endedAt:z.string().datetime({offset:true}),activeDuration:positive.max(172800),name:z.string().trim().min(1).max(100),shots:z.array(shotSchema).max(10000),sampleRateHz:positive.max(1000).nullish(),equipmentIDs:z.array(z.string().uuid()).max(30).default([]),isDemo:z.literal(false).default(false)}).superRefine((s,ctx)=>{
  const duration=(Date.parse(s.endedAt)-Date.parse(s.startedAt))/1000;
  if(duration<0||s.activeDuration>duration+2||Date.parse(s.startedAt)>Date.now()+300000)ctx.addIssue({code:'custom',message:'Session dates or duration are invalid.'});
  if(new Set(s.shots.map(x=>x.id)).size!==s.shots.length||s.shots.some(x=>x.timestamp>duration+2))ctx.addIssue({code:'custom',message:'Shot identities or times are invalid.'});
});
export type Session = z.infer<typeof sessionSchema>;
export type Shot = Session['shots'][number];
export const metrics = ['shotCount','sessionTime','currentRally','lastSwingSpeed','maxSwingSpeed','lastShot','smashes','averageSwingSpeed'] as const;
export const metricNames:Record<string,string>={shotCount:'Shots',sessionTime:'Session time',currentRally:'Current rally',lastSwingSpeed:'Last swing',maxSwingSpeed:'Max swing',lastShot:'Last shot',smashes:'Smashes',averageSwingSpeed:'Average swing'};
export const preferencesSchema = z.object({name:z.string().trim().max(80).default(''),playingHand:z.enum(['right','left']).default('right'),watchWrist:z.enum(['right','left']).default('right'),speedUnit:z.enum(['km/h','mph']).default('km/h'),appearance:z.enum(['system','light','dark']).default('system'),showUnknown:z.boolean().default(true),rallyGap:z.number().min(2).max(20).default(6),sampleRateHz:z.union([z.literal(25),z.literal(50)]).default(50),hapticFeedback:z.boolean().default(false),autoPause:z.boolean().default(false),layout:z.object({preset:z.enum(['minimal','performance','rally','speed','custom']),primary:z.enum(metrics),secondary:z.enum(metrics),tertiary:z.enum(metrics).nullable()}).default({preset:'performance',primary:'shotCount',secondary:'lastSwingSpeed',tertiary:'lastShot'}),equipment:z.array(z.object({id:z.string().uuid(),name:z.string().trim().min(1).max(100),kind:z.enum(['Racket','Strings','Shoes']),startedAt:z.string().date(),retiredAt:z.string().date().nullable()})).max(100).default([])});
export type Preferences = z.infer<typeof preferencesSchema>;
export const defaultPreferences = preferencesSchema.parse({});
export function watchConfiguration(p:Preferences){return {settings:{playingHand:p.playingHand,watchWrist:p.watchWrist,sampleRateHz:p.sampleRateHz,accelerationThreshold:2.2,rotationThreshold:10,refractoryPeriod:.65,preWindow:.2,postWindow:.4,confidenceThreshold:.8,rallyGap:p.rallyGap,retainRawSamples:true,hapticFeedback:p.hapticFeedback,autoPause:p.autoPause,enableExperimentalClassification:false},layout:p.layout,speedUnit:p.speedUnit};}
export const periods=['Latest Session','Today','7 Days','30 Days','3 Months','All Time'];
export function selectSessions(sessions:Session[],period:string,now=new Date()){
  const valid=sessions.filter(s=>!s.isDemo&&Date.parse(s.startedAt)<=+now).sort((a,b)=>Date.parse(b.startedAt)-Date.parse(a.startedAt));
  if(period==='Latest Session')return valid.slice(0,1);
  let since=0;if(period==='Today')since=+new Date(now.getFullYear(),now.getMonth(),now.getDate());
  if(period==='7 Days'||period==='30 Days')since=+now-(period==='7 Days'?7:30)*86400000;
  if(period==='3 Months'){const d=new Date(now);d.setMonth(d.getMonth()-3);since=+d;}
  return valid.filter(s=>Date.parse(s.startedAt)>=since);
}
export function analyze(sessions:Session[],gap=6){
  const shots=sessions.flatMap(s=>s.shots);const counts=Object.fromEntries(shotTypes.map(t=>[t,shots.filter(s=>s.type===t).length]));
  const rallies:Shot[][]=[];for(const s of sessions){let group:Shot[]=[];for(const shot of [...s.shots].sort((a,b)=>a.timestamp-b.timestamp)){if(group.length&&shot.timestamp-group[group.length-1].timestamp>gap){rallies.push(group);group=[];}group.push(shot);}if(group.length)rallies.push(group);}
  const speeds=shots.flatMap(s=>s.estimatedSwingSpeed==null?[]:[s.estimatedSwingSpeed]);
  return {shots,counts,total:shots.length,known:shots.length-counts.unknown,duration:sessions.reduce((n,s)=>n+s.activeDuration,0),rallies:rallies.length,longest:Math.max(0,...rallies.map(r=>r.length)),averageRally:rallies.length?shots.length/rallies.length:null,averageSpeed:speeds.length?speeds.reduce((a,b)=>a+b,0)/speeds.length:null,maxSpeed:speeds.length?Math.max(...speeds):null,peakRotation:shots.length?Math.max(...shots.map(s=>s.peakRotation))*180/Math.PI:null};
}
export function personalRecords(sessions:Session[],gap=6){
  const ordered=[...sessions].sort((a,b)=>Date.parse(a.startedAt)-Date.parse(b.startedAt));
  const definitions=[{name:'Most shots',unit:'shots',value:(s:Session)=>s.shots.length},{name:'Longest session',unit:'seconds',value:(s:Session)=>s.activeDuration},{name:'Longest inferred rally',unit:'shots',value:(s:Session)=>analyze([s],gap).longest},{name:'Fastest swing',unit:'km/h',value:(s:Session)=>analyze([s],gap).maxSpeed},...['smash','clear','drive'].map(type=>({name:'Fastest '+type,unit:'km/h',value:(s:Session)=>{const v=s.shots.filter(x=>x.type===type).flatMap(x=>x.estimatedSwingSpeed==null?[]:[x.estimatedSwingSpeed]);return v.length?Math.max(...v):null;}}))];
  return definitions.map(d=>{const progression:{value:number;session:Session}[]=[];for(const s of ordered){const v=d.value(s);if(v!=null&&v>0&&(!progression.length||v>progression[progression.length-1].value))progression.push({value:v,session:s});}return {...d,best:progression.at(-1),progression};});
}
export function duration(value:number){const s=Math.floor(value);return `${Math.floor(s/60)}:${String(s%60).padStart(2,'0')}`;}
export function speed(value:number|null|undefined,unit:string){return value==null?'—':`${(unit==='mph'?value/1.609344:value).toFixed(0)} ${unit}`;}
