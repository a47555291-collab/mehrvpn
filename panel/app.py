import csv,io,json,os,secrets,time
from pathlib import Path
from urllib.parse import urlsplit
import qrcode
from qrcode.exceptions import DataOverflowError
from fastapi import FastAPI,HTTPException,Request
from fastapi.responses import FileResponse,JSONResponse,Response
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel,Field,ConfigDict,field_validator
from . import auth
from .core import PERMISSIONS,rpc,transaction,valid_name
ROOT=Path(__file__).parent; DB=os.environ.get('MEHRVPN_DB','/var/lib/mehrvpn/panel.db'); PUBLIC_URL=os.environ.get('MEHRVPN_PUBLIC_URL','https://localhost').rstrip('/')
_origin=urlsplit(PUBLIC_URL)
if _origin.path or _origin.query or _origin.fragment or _origin.username or not _origin.hostname: raise RuntimeError('MEHRVPN_PUBLIC_URL must be an origin without a path or credentials')
if (_origin.scheme=='https' and _origin.port==443) or (_origin.scheme=='http' and _origin.port==80): PUBLIC_URL=f'{_origin.scheme}://{_origin.hostname}'
SECURE=urlsplit(PUBLIC_URL).scheme=='https'
if not SECURE and urlsplit(PUBLIC_URL).hostname not in {'localhost','127.0.0.1','::1'}: raise RuntimeError('Public deployments require HTTPS')
auth.init_auth(DB); app=FastAPI(title='MehrVPN',docs_url=None,redoc_url=None,openapi_url=None)
@app.middleware('http')
async def security(request:Request,call_next):
    if request.method not in {'GET','HEAD','OPTIONS'}:
        if request.headers.get('origin')!=PUBLIC_URL: return JSONResponse({'detail':'Untrusted request origin'},status_code=403)
        try: length=int(request.headers.get('content-length','0'))
        except ValueError: return JSONResponse({'detail':'Invalid content length'},status_code=400)
        if length>16384: return JSONResponse({'detail':'Request too large'},status_code=413)
    response=await call_next(request); response.headers['X-Content-Type-Options']='nosniff'; response.headers['X-Frame-Options']='DENY'; response.headers['Referrer-Policy']='no-referrer'; response.headers['Permissions-Policy']='camera=(), microphone=(), geolocation=()'; response.headers['Content-Security-Policy']="default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"; response.headers['Cache-Control']='no-store' if request.url.path.startswith(('/api/','/share/')) else response.headers.get('Cache-Control',''); return response
def user(request,permission=None):
    data=auth.session(DB,request.cookies.get('mehrvpn_session',''))
    if not data: raise HTTPException(401,'Sign in to continue')
    if request.method not in {'GET','HEAD'} and not secrets.compare_digest(request.headers.get('x-csrf-token',''),data['csrf']): raise HTTPException(403,'Invalid security token')
    if permission and permission not in data['permissions']: raise HTTPException(403,'You do not have permission for this action')
    return data
def agent(action,data=None):
    try: return rpc(action,data)
    except ValueError as e: raise HTTPException(400,str(e)) from e
    except (OSError,ConnectionError) as e: raise HTTPException(503,'OpenVPN agent unavailable') from e
def operation(request,action,target,payload):
    who=user(request,'clients.write')
    try: result=agent(action,payload)
    except HTTPException: auth.audit(DB,who['username'],action,target,'failed'); raise
    auth.audit(DB,who['username'],action,target); return {'ok':True,'result':result}
class StrictModel(BaseModel): model_config=ConfigDict(extra='forbid')
class Login(StrictModel): username:str=Field(min_length=1,max_length=48); password:str=Field(min_length=1,max_length=256)
class Client(StrictModel):
    name:str; label:str=Field(default='',max_length=100); quota_bytes:int=Field(default=0,ge=0,le=10**16); expires_at:int|None=Field(default=None,ge=1,le=253402300799); note:str=Field(default='',max_length=2000)
    @field_validator('name')
    @classmethod
    def name_valid(cls,value): return valid_name(value)
class ClientEdit(StrictModel):
    label:str=Field(max_length=100); quota_bytes:int=Field(ge=0,le=10**16); expires_at:int|None=Field(default=None,ge=1,le=253402300799); note:str=Field(default='',max_length=2000); state:str=Field(pattern='^(active|suspended)$')
class Admin(StrictModel):
    username:str; password:str=Field(default='',max_length=256); permissions:list[str]; enabled:bool=True
    @field_validator('username')
    @classmethod
    def name_valid(cls,value): return valid_name(value)
    @field_validator('permissions')
    @classmethod
    def permissions_valid(cls,value):
        if not set(value)<=PERMISSIONS-{'admins'}: raise ValueError('Administrator management is reserved for the owner')
        return sorted(set(value))
@app.get('/api/health')
def health(): return {'status':'ok','version':'0.1.0'}
@app.post('/api/login')
def login(body:Login,request:Request):
    try: token,csrf=auth.login(DB,body.username,body.password,request.client.host)
    except ValueError as e: raise HTTPException(429 if 'Too many' in str(e) else 401,str(e)) from e
    response=JSONResponse({'csrf':csrf}); response.set_cookie('mehrvpn_session',token,httponly=True,secure=SECURE,samesite='strict',max_age=28800,path='/'); return response
@app.get('/api/me')
def me(request:Request):
    result=user(request)
    with transaction(DB) as db: result['preferences']={r[0]:json.loads(r[1]) for r in db.execute('SELECT * FROM settings')}
    return result
@app.post('/api/logout')
def logout(request:Request):
    who=user(request)
    with transaction(DB) as db: db.execute('DELETE FROM sessions WHERE token=?',(auth.digest(request.cookies.get('mehrvpn_session','')),))
    auth.audit(DB,who['username'],'logout'); response=JSONResponse({'ok':True}); response.delete_cookie('mehrvpn_session'); return response
class Password(StrictModel): current:str=Field(max_length=256); new:str=Field(min_length=12,max_length=256)
@app.post('/api/password')
def password(body:Password,request:Request):
    who=user(request)
    with transaction(DB) as db:
        row=db.execute('SELECT password FROM admins WHERE username=?',(who['username'],)).fetchone()
        try: auth.HASHER.verify(row[0],body.current)
        except auth.VerificationError as e: raise HTTPException(400,'Incorrect current password') from e
        db.execute('UPDATE admins SET password=? WHERE username=?',(auth.hash_password(body.new),who['username'])); db.execute('DELETE FROM sessions WHERE username=?',(who['username'],))
    auth.audit(DB,who['username'],'password'); return {'ok':True}
@app.get('/api/dashboard')
def dashboard(request:Request):
    user(request,'dashboard'); result=agent('metrics'); clients=agent('list'); result['totals']={'clients':len(clients),'active':sum(x['effective_state']=='active' for x in clients),'blocked':sum(x['effective_state'] in {'quota','expired','suspended'} for x in clients),'upload':sum(x['upload'] for x in clients),'download':sum(x['download'] for x in clients)}; return result
@app.get('/api/clients')
def clients(request:Request): user(request,'clients.read'); return agent('list')
@app.post('/api/clients')
def create_client(body:Client,request:Request): return operation(request,'create',body.name,body.model_dump())
@app.put('/api/clients/{name}')
def edit_client(name:str,body:ClientEdit,request:Request): return operation(request,'update',name,{'name':name,**body.model_dump()})
@app.post('/api/clients/{name}/{action}')
def client_action(name:str,action:str,request:Request):
    if action not in {'revoke','reset','kill'}: raise HTTPException(404)
    return operation(request,action,name,{'name':name})
@app.get('/api/clients/{name}/config')
def config(name:str,request:Request):
    who=user(request,'clients.export'); data=agent('config',{'name':name}); auth.audit(DB,who['username'],'export',name); return Response(data,media_type='application/x-openvpn-profile',headers={'Content-Disposition':f'attachment; filename="{valid_name(name)}.ovpn"'})
def qr_png(data):
    qr=qrcode.QRCode(error_correction=qrcode.constants.ERROR_CORRECT_M,box_size=6,border=4); qr.add_data(data)
    try: qr.make(fit=True)
    except (DataOverflowError,ValueError) as e: raise HTTPException(413,'Profile is too large for one QR code') from e
    output=io.BytesIO(); qr.make_image(fill_color='#10243a',back_color='white').save(output,format='PNG'); return Response(output.getvalue(),media_type='image/png')
@app.get('/api/clients/{name}/qr')
def config_qr(name:str,request:Request):
    who=user(request,'clients.export'); data=agent('config',{'name':name}); auth.audit(DB,who['username'],'qr',name); return qr_png(data)
@app.post('/api/share/{name}')
def share(name:str,request:Request):
    who=user(request,'clients.export')
    if not SECURE: raise HTTPException(400,'Download links require HTTPS')
    agent('config',{'name':name}); token=secrets.token_urlsafe(32)
    with transaction(DB) as db: db.execute('DELETE FROM shares WHERE expires_at<?',(int(time.time()),)); db.execute('INSERT INTO shares VALUES(?,?,?,?)',(auth.digest(token),name,int(time.time())+300,who['username']))
    auth.audit(DB,who['username'],'share.create',name); return {'url':PUBLIC_URL+'/share/'+token,'qr':'/api/share-qr/'+token,'expires_in':300}
@app.get('/api/share-qr/{token}')
def share_qr(token:str,request:Request):
    who=user(request,'clients.export')
    with transaction(DB) as db: row=db.execute('SELECT actor FROM shares WHERE token=? AND expires_at>?',(auth.digest(token),int(time.time()))).fetchone()
    if not row or row[0]!=who['username']: raise HTTPException(404)
    return qr_png(PUBLIC_URL+'/share/'+token)
@app.get('/share/{token}')
def download_share(token:str):
    with transaction(DB) as db:
        row=db.execute('SELECT * FROM shares WHERE token=? AND expires_at>?',(auth.digest(token),int(time.time()))).fetchone()
        if not row: raise HTTPException(410,'Download link expired or already used')
        db.execute('DELETE FROM shares WHERE token=?',(auth.digest(token),))
    data=agent('config',{'name':row['client']}); auth.audit(DB,row['actor'],'share.download',row['client']); return Response(data,media_type='application/x-openvpn-profile',headers={'Content-Disposition':f'attachment; filename="{row["client"]}.ovpn"'})
@app.get('/api/admins')
def admins(request:Request):
    who=user(request,'admins')
    if not who['owner']: raise HTTPException(403)
    with transaction(DB) as db: rows=[dict(r) for r in db.execute('SELECT username,permissions,owner,enabled FROM admins ORDER BY owner DESC,username')]
    for row in rows: row['permissions']=json.loads(row['permissions'])
    return rows
@app.put('/api/admins/{username}')
def save_admin(username:str,body:Admin,request:Request):
    who=user(request,'admins')
    if not who['owner'] or username!=body.username: raise HTTPException(403)
    with transaction(DB) as db:
        old=db.execute('SELECT owner,password FROM admins WHERE username=?',(username,)).fetchone()
        if old and old['owner']: raise HTTPException(400,'The owner account is protected')
        try: hashed=auth.hash_password(body.password) if body.password else old['password'] if old else auth.hash_password('')
        except ValueError as e: raise HTTPException(400,str(e)) from e
        db.execute('INSERT INTO admins(username,password,permissions,enabled) VALUES(?,?,?,?) ON CONFLICT(username) DO UPDATE SET password=excluded.password,permissions=excluded.permissions,enabled=excluded.enabled',(username,hashed,json.dumps(body.permissions),int(body.enabled))); db.execute('DELETE FROM sessions WHERE username=?',(username,))
    auth.audit(DB,who['username'],'admin.save',username); return {'ok':True}
@app.get('/api/settings')
def settings(request:Request):
    user(request,'settings')
    with transaction(DB) as db: stored={r[0]:json.loads(r[1]) for r in db.execute('SELECT * FROM settings')}
    stored.setdefault('panel_name','MehrVPN'); stored.setdefault('default_quota_gb',50); stored.setdefault('default_days',30); stored['public_url']=PUBLIC_URL
    try: stored['openvpn']=agent('server')
    except HTTPException as e: stored['openvpn_error']=e.detail
    return stored
class Settings(StrictModel): panel_name:str=Field(min_length=1,max_length=60); default_quota_gb:int=Field(ge=0,le=100000); default_days:int=Field(ge=0,le=3650)
@app.put('/api/settings')
def save_settings(body:Settings,request:Request):
    who=user(request,'settings')
    with transaction(DB) as db:
        for key,value in body.model_dump().items(): db.execute('INSERT OR REPLACE INTO settings VALUES(?,?)',(key,json.dumps(value)))
    auth.audit(DB,who['username'],'settings.save'); return {'ok':True}
@app.post('/api/server/restart')
def restart(request:Request):
    who=user(request,'settings'); result=agent('restart'); auth.audit(DB,who['username'],'server.restart'); return {'ok':result}
@app.get('/api/audit')
def audit_log(request:Request,before:int=2**63-1):
    user(request,'audit')
    with transaction(DB) as db: return [dict(r) for r in db.execute('SELECT * FROM audit WHERE id<? ORDER BY id DESC LIMIT 100',(before,))]
@app.get('/api/export/clients.csv')
def export_csv(request:Request):
    who=user(request,'clients.export'); user(request,'clients.read'); rows=agent('list'); output=io.StringIO(newline=''); writer=csv.writer(output); keys=['name','label','effective_state','quota_bytes','upload','download','expires_at']; writer.writerow(keys)
    for row in rows: writer.writerow([("'"+str(row[k])) if str(row[k]).startswith(('=','+','-','@','\t','\r')) else row[k] for k in keys])
    auth.audit(DB,who['username'],'clients.csv'); return Response('\ufeff'+output.getvalue(),media_type='text/csv',headers={'Content-Disposition':'attachment; filename="clients.csv"'})
app.mount('/static',StaticFiles(directory=ROOT/'static'),name='static')
@app.get('/')
def index(): return FileResponse(ROOT/'static/index.html')
