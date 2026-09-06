import argparse,getpass,hashlib,os
from pathlib import Path
from cryptography.hazmat.primitives.ciphers import Cipher,algorithms,modes
MAGIC=b'MEHRVPN1'; HEADER_LENGTH=36
def transform(source,target,password,decrypt=False):
 source,target=Path(source),Path(target)
 if target.exists(): raise ValueError('Output file already exists')
 temporary=target.with_name(target.name+'.partial'); created=False
 try:
  with source.open('rb') as src,temporary.open('xb') as dst:
   created=True; os.chmod(temporary,0o600)
   if decrypt:
    header=src.read(HEADER_LENGTH)
    if len(header)!=HEADER_LENGTH or header[:8]!=MAGIC: raise ValueError('Invalid backup header')
    size=source.stat().st_size-HEADER_LENGTH-16
    if size<0: raise ValueError('Truncated backup')
    src.seek(-16,2); tag=src.read(16); src.seek(HEADER_LENGTH); salt,nonce=header[8:24],header[24:36]; key=hashlib.pbkdf2_hmac('sha256',password.encode(),salt,600000,32); context=Cipher(algorithms.AES(key),modes.GCM(nonce,tag)).decryptor()
   else:
    salt,nonce=os.urandom(16),os.urandom(12); header=MAGIC+salt+nonce; dst.write(header); key=hashlib.pbkdf2_hmac('sha256',password.encode(),salt,600000,32); context=Cipher(algorithms.AES(key),modes.GCM(nonce)).encryptor(); size=source.stat().st_size
   context.authenticate_additional_data(header)
   while size:
    chunk=src.read(min(size,1024*1024))
    if not chunk: raise ValueError('Truncated backup')
    dst.write(context.update(chunk)); size-=len(chunk)
   dst.write(context.finalize())
   if not decrypt: dst.write(context.tag)
   dst.flush(); os.fsync(dst.fileno())
  os.link(temporary,target); temporary.unlink()
 except Exception:
  if created: temporary.unlink(missing_ok=True)
  raise
def main():
 p=argparse.ArgumentParser(); p.add_argument('action',choices=['encrypt','decrypt']); p.add_argument('source'); p.add_argument('target'); a=p.parse_args(); password=getpass.getpass('Backup password: ')
 if a.action=='encrypt' and (len(password)<12 or password!=getpass.getpass('Repeat backup password: ')): raise SystemExit('Passwords must match and have at least 12 characters')
 transform(a.source,a.target,password,a.action=='decrypt'); print('Backup operation completed.')
if __name__=='__main__': main()
