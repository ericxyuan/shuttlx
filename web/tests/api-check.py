"""Integration acceptance against a local Worker; never against production.
Run with a built Worker on 127.0.0.1:5183. Identity headers emulate Sites dispatch.
Fixtures use unique test owners and remain only in the local preview database.
"""
import json, uuid, urllib.request, urllib.error
BASE='http://127.0.0.1:5183'
owner='acceptance-'+str(uuid.uuid4())
def call(path,method='GET',data=None,user=owner,token=None,origin=BASE):
    headers={'Content-Type':'application/json','Origin':origin,'cf-connecting-ip':owner,'Connection':'close'}
    if user: headers.update({'oai-authenticated-user-id':user,'oai-authenticated-user-email':user+'@example.test'})
    if token: headers['Authorization']='Bearer '+token
    req=urllib.request.Request(BASE+'/api/'+path,method=method,headers=headers,data=json.dumps(data).encode() if data is not None else None)
    try:
        with urllib.request.urlopen(req,timeout=30) as r: return r.status,json.load(r)
    except urllib.error.HTTPError as e:
        raw=e.read().decode()
        try: body=json.loads(raw)
        except json.JSONDecodeError: body={'error':raw}
        return e.code,body
def expect(status,result):
    assert result[0]==status,(status,result)
    return result[1]
expect(401,call('state',user=None))
device_id=str(uuid.uuid4()); nonce=''.join(uuid.uuid4().hex for _ in range(2))[:32]
paired=expect(200,call('device/qr/claim','POST',{'deviceID':device_id,'nonce':nonce,'name':'Acceptance Watch'}))
token=paired['token']
expect(409,call('device/qr/claim','POST',{'deviceID':device_id,'nonce':nonce,'name':'Replay Watch'}))
configuration=expect(200,call('device/configuration',user=None,token=token))
assert configuration['layout']['primary']=='shotCount'
session={'id':str(uuid.uuid4()),'name':'Acceptance fixture','startedAt':'2026-09-20T18:00:00Z','endedAt':'2026-09-20T19:00:00Z','activeDuration':600,'shots':[{'id':str(uuid.uuid4()),'timestamp':10,'type':'unknown','hand':'unknown','position':'unknown','tactical':'unknown','confidence':0,'handConfidence':0,'positionConfidence':0,'peakRotation':15,'peakAcceleration':3,'duration':.4,'samples':[]}],'equipmentIDs':[],'isDemo':False}
expect(200,call('device/sessions','POST',session,user=None,token=token))
expect(200,call('device/sessions','POST',session,user=None,token=token))
state=expect(200,call('state'))
assert len(state['sessions'])==1 and len(state['devices'])==1
assert len(expect(200,call('state',user=owner+'-other'))['sessions'])==0
expect(409,call('device/sessions','POST',{**session,'name':'Different payload'},user=None,token=token))
expect(400,call('device/sessions','POST',{**session,'activeDuration':-1},user=None,token=token))
prefs=state['preferences']; prefs['speedUnit']='mph';prefs['layout']={'preset':'minimal','primary':'sessionTime','secondary':'shotCount','tertiary':None}
expect(200,call('preferences','PUT',prefs))
config=expect(200,call('device/configuration',user=None,token=token))
assert config['speedUnit']=='mph' and config['layout']['primary']=='sessionTime'
expect(200,call('devices','DELETE',{'id':paired['deviceID']},user=owner+'-other'))
expect(200,call('device/configuration',user=None,token=token))
expect(200,call('devices','DELETE',{'id':paired['deviceID']}))
expect(401,call('device/configuration',user=None,token=token))
assert len(expect(200,call('sessions')))==1
expect(403,call('pairing','POST',{},origin='https://unrelated.example'))
print('PASS: anonymous access, cross-origin writes, QR pairing, one-time nonce, device config, upload, duplicate delivery, account isolation, conflict rejection, invalid data, persisted preferences, cross-account revocation isolation, revocation and retained sessions.')
