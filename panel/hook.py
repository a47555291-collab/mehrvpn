import ipaddress,os,sys
from .core import rpc
def main():
 try:
  name=os.environ['common_name']
  if os.environ['script_type']=='client-connect': return 0 if rpc('check',{'name':name},hook=True) else 1
  address=ipaddress.ip_address(os.environ.get('trusted_ip') or os.environ['trusted_ip6']); remote=f"[{address}]:{os.environ['trusted_port']}" if address.version==6 else f"{address}:{os.environ['trusted_port']}"
  rpc('disconnect',{'name':name,'remote':remote,'since':int(os.environ['time_unix']),'upload':int(os.environ.get('bytes_received',0)),'download':int(os.environ.get('bytes_sent',0))},hook=True); return 0
 except Exception:
  print('MehrVPN policy check/accounting unavailable',file=sys.stderr); return 1
if __name__=='__main__': sys.exit(main())
