import json,logging,os,shutil,socket,socketserver,subprocess,threading,time
from pathlib import Path
import psutil
from .accounting import Accounting,parse_status,session_key
from .core import transaction,valid_name
LOG=logging.getLogger('mehrvpn.agent')
class Management:
 def __init__(self,path='/run/mehrvpn/management.sock'): self.path,self.lock=path,threading.Lock()
 def command(self,command,multi=False):
  with self.lock,socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as s:
   s.settimeout(5); s.connect(self.path); stream=s.makefile('rb'); greeting=stream.readline()
   if not greeting.startswith(b'>INFO:'): raise RuntimeError('Unexpected OpenVPN management greeting')
   s.sendall(command.encode('ascii')+b'\n'); lines=[]
   for _ in range(50000):
    raw=stream.readline(65536)
    if not raw: raise ConnectionError('OpenVPN management disconnected')
    line=raw.decode('utf-8','replace').rstrip('\r\n')
    if line.startswith('>'): continue
    if line.startswith('ERROR:'): raise RuntimeError(line)
    lines.append(line)
    if (multi and line=='END') or (not multi and line.startswith('SUCCESS:')): return '\n'.join(lines)
   raise RuntimeError('Oversized management reply')
class Agent:
 def __init__(self,state='/var/lib/mehrvpn-agent',vpn='/etc/openvpn/server'):
  self.state,self.vpn=Path(state),Path(vpn); self.state.mkdir(parents=True,exist_ok=True,mode=0o700); self.accounts=Accounting(self.state/'state.db'); self.management=Management(); self.pki_lock=threading.Lock(); self.live=[]; self.last_ok=0; self.error='Waiting for OpenVPN'; self.last_net=psutil.net_io_counters(); self.last_sample=time.monotonic()
  with transaction(self.accounts.path) as db: db.execute('CREATE TABLE IF NOT EXISTS metrics (at INTEGER PRIMARY KEY,value TEXT NOT NULL)')
  self.import_clients()
 def import_clients(self):
  index=self.vpn/'easy-rsa/pki/index.txt'
  if not index.exists(): return
  known={x['name'] for x in self.accounts.list()}
  for line in index.read_text().splitlines():
   f=line.split('\t')
   if len(f)<6 or f[0]!='V' or '/CN=' not in f[-1]: continue
   name=f[-1].split('/CN=')[-1]
   if name.lower() in {'server','ca'}: continue
   valid_name(name)
   if name not in known: self.accounts.add(name,note='Imported; usage starts at panel installation.'); self.accounts.update(name,state='active')
 def easyrsa(self,*args):
  r=subprocess.run([str(self.vpn/'easy-rsa/easyrsa'),'--batch',*args],cwd=self.vpn/'easy-rsa',capture_output=True,text=True,timeout=85,env={**os.environ,'EASYRSA_BATCH':'1'})
  if r.returncode: LOG.error('EasyRSA failed with exit status %s',r.returncode); raise RuntimeError('Certificate operation failed. Check server permissions and PKI health.')
 def config(self,name):
  valid_name(name); row=next((x for x in self.accounts.list() if x['name']==name),None)
  if not row or row['state'] in {'revoked','revoking','provisioning','error'}: raise ValueError('Configuration is unavailable')
  template=(self.vpn/'client-common.txt').read_text(); inline=(self.vpn/f'easy-rsa/pki/inline/private/{name}.inline').read_text(); result='\n'.join(x for x in (template+'\n'+inline).splitlines() if not x.startswith('#'))+'\n'
  if not all(tag in result for tag in ('<ca>','<cert>','<key>','<tls-crypt>')): raise ValueError('Incomplete EasyRSA inline profile')
  return result
 def disconnect(self,name):
  valid_name(name)
  try: self.management.command('kill '+name)
  except RuntimeError as e:
   if 'not found' not in str(e).lower(): raise
 def dispatch(self,action,data,hook=False):
  if hook:
   name=valid_name(data.get('name',''))
   if action=='check': return self.accounts.allowed(name) and time.time()-self.last_ok<15
   if action=='disconnect': self.accounts.account(name,session_key(name,data['remote'],int(data['since'])),int(data['upload']),int(data['download'])); return True
   raise ValueError('Unknown hook action')
  if action=='list':
   rows=self.accounts.list()
   for row in rows: row['connections']=[x for x in self.live if x['name']==row['name']] if time.time()-self.last_ok<15 else []
   return rows
  if action=='metrics':
   with transaction(self.accounts.path) as db: history=[json.loads(r[0]) for r in db.execute('SELECT value FROM metrics ORDER BY at DESC LIMIT 2880')][::-1]
   return {'history':history,'online':len(self.live) if time.time()-self.last_ok<15 else None,'healthy':time.time()-self.last_ok<15,'error':self.error,'last_ok':self.last_ok,'server':socket.gethostname(),'uptime':int(time.time()-psutil.boot_time())}
  if action=='server':
   conf=(self.vpn/'server.conf').read_text(); values={}
   for line in conf.splitlines():
    pair=line.split(maxsplit=1)
    if len(pair)==2 and pair[0] in {'port','proto','server','local','dev'}: values[pair[0]]=pair[1]
   values['profile_template']=(self.vpn/'client-common.txt').read_text(); return values
  if action=='restart': subprocess.run(['systemctl','restart','openvpn-server@server.service'],check=True,timeout=40); return True
  name=valid_name(data.get('name',''))
  if action in {'create','update'}:
   quota=data.get('quota_bytes',0); expiry=data.get('expires_at')
   if not isinstance(quota,int) or isinstance(quota,bool) or not 0<=quota<=10**16: raise ValueError('Invalid traffic quota')
   if expiry is not None and (not isinstance(expiry,int) or isinstance(expiry,bool) or not 1<=expiry<=253402300799): raise ValueError('Invalid expiry timestamp')
   for key,limit in [('label',100),('note',2000)]:
    if key in data and (not isinstance(data[key],str) or len(data[key])>limit): raise ValueError('Invalid client metadata')
  if action=='config': return self.config(name)
  if action=='create':
   with self.pki_lock:
    if (self.vpn/f'easy-rsa/pki/issued/{name}.crt').exists(): raise ValueError('Certificate name already exists')
    self.accounts.add(name,**{k:data[k] for k in ('label','quota_bytes','expires_at','note') if k in data})
    try: self.easyrsa('--days=3650','build-client-full',name,'nopass'); self.accounts.update(name,state='active'); self.config(name)
    except Exception: self.accounts.update(name,state='error',error='Certificate provisioning failed'); raise
   return True
  if action=='update':
   row=next((x for x in self.accounts.list() if x['name']==name),None)
   if not row or row['state'] not in {'active','suspended'}: raise ValueError('This client cannot be edited')
   changes={k:data[k] for k in ('label','quota_bytes','expires_at','note','state') if k in data}
   if 'state' in changes and changes['state'] not in {'active','suspended'}: raise ValueError('Invalid state')
   self.accounts.update(name,**changes)
   if not self.accounts.allowed(name): self.disconnect(name)
   return True
  if action=='reset': self.accounts.reset(name); return True
  if action=='kill': self.disconnect(name); return True
  if action=='revoke':
   with self.pki_lock:
    self.accounts.update(name,state='revoking'); index=(self.vpn/'easy-rsa/pki/index.txt').read_text()
    if any(line.startswith('V\t') and line.endswith('/CN='+name) for line in index.splitlines()): self.easyrsa('revoke',name)
    self.easyrsa('--days=3650','gen-crl'); target=self.vpn/'crl.pem.new'; shutil.copyfile(self.vpn/'easy-rsa/pki/crl.pem',target); os.chmod(target,0o644); os.replace(target,self.vpn/'crl.pem'); self.accounts.update(name,state='revoked',error='')
    for p in [self.vpn/f'easy-rsa/pki/private/{name}.key',self.vpn/f'easy-rsa/pki/inline/private/{name}.inline']: p.unlink(missing_ok=True)
    self.disconnect(name)
   return True
  raise ValueError('Unknown agent action')
 def monitor(self):
  failures_since=None; last_save=0
  while True:
   try:
    rows=parse_status(self.management.command('status 3',multi=True))
    for row in rows: self.accounts.account(row['name'],session_key(row['name'],row['remote'],row['since']),row['upload'],row['download'])
    self.live,self.last_ok,self.error=rows,time.time(),''; failures_since=None
    for name in {x['name'] for x in rows if not self.accounts.allowed(x['name'])}: self.disconnect(name)
   except Exception as e:
    self.error='OpenVPN monitoring unavailable; check the service and management socket.'; LOG.warning('Monitor: %s',type(e).__name__); failures_since=failures_since or time.monotonic()
    if time.monotonic()-failures_since>15: subprocess.run(['systemctl','stop','openvpn-server@server.service'],timeout=30,check=False); failures_since=time.monotonic()
   if time.monotonic()-last_save>=30:
    now,net=time.monotonic(),psutil.net_io_counters(); seconds=max(1,now-self.last_sample); memory,disk=psutil.virtual_memory(),psutil.disk_usage('/'); item={'at':int(time.time()),'cpu':psutil.cpu_percent(),'ram':memory.percent,'ram_used':memory.used,'ram_total':memory.total,'disk':disk.percent,'disk_used':disk.used,'disk_total':disk.total,'rx':max(0,net.bytes_recv-self.last_net.bytes_recv)/seconds,'tx':max(0,net.bytes_sent-self.last_net.bytes_sent)/seconds,'online':len(self.live) if time.time()-self.last_ok<15 else None}
    with transaction(self.accounts.path) as db: db.execute('INSERT OR REPLACE INTO metrics VALUES(?,?)',(item['at'],json.dumps(item))); db.execute('DELETE FROM metrics WHERE at<?',(int(time.time())-86400,))
    self.last_net,self.last_sample,last_save=net,now,now
   time.sleep(2)
def serve():
 import grp; os.umask(0o077); logging.basicConfig(level=logging.INFO); agent=Agent()
 class Handler(socketserver.StreamRequestHandler):
  def handle(self):
   self.request.settimeout(10)
   try:
    line=self.rfile.readline(65537)
    if len(line)>65536 or not line.endswith(b'\n'): raise ValueError('Invalid request')
    req=json.loads(line); result=agent.dispatch(req['action'],req.get('payload',{}),hook=self.server.is_hook); response={'ok':True,'data':result}
   except Exception as e: LOG.warning('Agent request failed: %s',type(e).__name__); response={'ok':False,'error':str(e) if isinstance(e,ValueError) else 'Server operation failed; inspect service logs.'}
   self.wfile.write(json.dumps(response).encode()+b'\n')
 class Server(socketserver.ThreadingUnixStreamServer): daemon_threads=True; request_queue_size=64
 Path('/run/mehrvpn').mkdir(mode=0o755,exist_ok=True)
 for name,group,hook in [('control','mehrvpn',False),('hook','nogroup',True)]:
  path=f'/run/mehrvpn/{name}.sock'; Path(path).unlink(missing_ok=True); server=Server(path,Handler); server.is_hook=hook; os.chown(path,0,grp.getgrnam(group).gr_gid); os.chmod(path,0o660); threading.Thread(target=server.serve_forever,daemon=True).start()
 agent.monitor()
if __name__=='__main__': serve()
