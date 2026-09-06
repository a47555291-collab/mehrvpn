const $ = (s) => document.querySelector(s);
const $$ = (s) => [...document.querySelectorAll(s)];
let csrf = '';
let me = null;
let clients = [];

const state = { filter: '', sort: 'name', dir: 'asc', view: 'dashboard' };

function escapeHtml(value) {
  return String(value ?? '').replace(/[&<>'"]/g, (c) => ({'&':'&amp;','<':'&lt;','>':'&gt;',"'":'&#39;','"':'&quot;'}[c]));
}
function fmtBytes(n) {
  n = Number(n || 0); const u=['B','KB','MB','GB','TB']; let i=0;
  while(n>=1024 && i<u.length-1){n/=1024;i++;}
  return `${n.toFixed(i?1:0)} ${u[i]}`;
}
function fmtDate(ts) { return ts ? new Date(Number(ts)*1000).toLocaleString() : '∞'; }
function fmtTime(sec) { sec=Number(sec||0); const h=Math.floor(sec/3600),m=Math.floor(sec%3600/60); return `${h}h ${m}m`; }
function toast(msg, bad=false) { const t=$('#toast'); t.textContent=msg; t.className=`toast ${bad?'bad':''} show`; setTimeout(()=>t.classList.remove('show'),2800); }

async function api(path, opt={}) {
  const method=(opt.method||'GET').toUpperCase();
  const headers={...(opt.headers||{})};
  if(method!=='GET'&&method!=='HEAD'){headers['Content-Type']='application/json'; headers['x-csrf-token']=csrf;}
  const r=await fetch(path,{...opt,headers});
  if(!r.ok) { const body=await r.json().catch(()=>({detail:r.statusText})); throw new Error(body.detail||r.statusText); }
  const type=r.headers.get('content-type')||'';
  return type.includes('application/json') ? r.json() : r.text();
}

function show(id) { $$('.page').forEach(x=>x.hidden=true); const el=$(`#page-${id}`); if(el) el.hidden=false; $$('.nav button').forEach(b=>b.classList.toggle('active',b.dataset.page===id)); state.view=id; }
function can(p){return !!(me?.owner || me?.permissions?.includes(p));}

async function boot(){
  try { me=await api('/api/me'); csrf=me.csrf||''; $('#login').hidden=true; $('#app').hidden=false; $('#who').textContent=me.username; applyPermissions(); await loadDashboard(); show('dashboard'); }
  catch { $('#login').hidden=false; $('#app').hidden=true; }
}
function applyPermissions(){
  $$('.nav button[data-perm]').forEach(b=>b.hidden=!can(b.dataset.perm));
  $('#admin-nav').hidden=!can('admins'); $('#settings-nav').hidden=!can('settings');
}

async function loadDashboard(){
  const d=await api('/api/dashboard');
  $('#stat-clients').textContent=d.totals.clients; $('#stat-active').textContent=d.totals.active;
  $('#stat-blocked').textContent=d.totals.blocked; $('#stat-up').textContent=fmtBytes(d.totals.upload); $('#stat-down').textContent=fmtBytes(d.totals.download);
  $('#server-health').textContent=d.healthy?'Healthy':'Degraded'; $('#server-health').className=d.healthy?'pill ok':'pill bad';
  $('#server-uptime').textContent=fmtTime(d.uptime);
  const hist=d.history||[]; const canvas=$('#chart'); if(canvas&&hist.length) drawChart(canvas,hist);
}
function drawChart(canvas, hist){
  const c=canvas.getContext('2d'), w=canvas.width=canvas.clientWidth*devicePixelRatio, h=canvas.height=canvas.clientHeight*devicePixelRatio; c.clearRect(0,0,w,h);
  const vals=hist.map(x=>Number(x.upload||0)+Number(x.download||0)); const max=Math.max(1,...vals); c.beginPath();
  vals.forEach((v,i)=>{const x=i*(w-20)/(Math.max(1,vals.length-1))+10,y=h-10-(v/max)*(h-20); i?c.lineTo(x,y):c.moveTo(x,y)}); c.stroke();
}

async function loadClients(){
  clients=await api('/api/clients'); renderClients();
}
function renderClients(){
  let rows=clients.filter(x=>JSON.stringify(x).toLowerCase().includes(state.filter.toLowerCase()));
  rows.sort((a,b)=>{const av=a[state.sort]??'',bv=b[state.sort]??''; return String(av).localeCompare(String(bv))* (state.dir==='asc'?1:-1);});
  $('#clients-count').textContent=rows.length;
  $('#clients-body').innerHTML=rows.map(x=>`<tr>
    <td><strong>${escapeHtml(x.name)}</strong><small>${escapeHtml(x.label||'')}</small></td>
    <td><span class="pill ${x.effective_state==='active'?'ok':'bad'}">${escapeHtml(x.effective_state)}</span></td>
    <td>${fmtBytes(x.upload)} ↑<br>${fmtBytes(x.download)} ↓</td>
    <td>${x.quota_bytes?fmtBytes(x.quota_bytes):'Unlimited'}</td>
    <td>${fmtDate(x.expires_at)}</td>
    <td class="actions">${can('clients.export')?`<button data-action="profile" data-name="${escapeHtml(x.name)}">Profile</button>`:''}${can('clients.write')?`<button data-action="edit" data-name="${escapeHtml(x.name)}">Edit</button><button class="danger" data-action="revoke" data-name="${escapeHtml(x.name)}">Revoke</button>`:''}</td>
  </tr>`).join('') || '<tr><td colspan="6" class="empty">No clients found.</td></tr>';
}

function openModal(id){$('#'+id).hidden=false} function closeModal(id){$('#'+id).hidden=true}
function setFormDefaults(){ $('#client-form').reset(); $('#client-name').disabled=false; $('#client-state').value='active'; $('#client-quota').value='50'; $('#client-days').value='30'; $('#client-modal-title').textContent='Create client'; }
function editClient(name){const x=clients.find(c=>c.name===name); if(!x)return; $('#client-form').reset(); $('#client-name').value=x.name; $('#client-name').disabled=true; $('#client-label').value=x.label||''; $('#client-quota').value=x.quota_bytes?Math.round(x.quota_bytes/1073741824):0; $('#client-days').value=x.expires_at?Math.max(0,Math.round((x.expires_at-Date.now()/1000)/86400)):0; $('#client-state').value=x.state||'active'; $('#client-note').value=x.note||''; $('#client-modal-title').textContent='Edit client'; openModal('client-modal'); }
async function saveClient(e){e.preventDefault(); const name=$('#client-name').value.trim(); const body={name,label:$('#client-label').value,quota_bytes:Number($('#client-quota').value||0)*1073741824,expires_at:Number($('#client-days').value||0)?Math.floor(Date.now()/1000)+Number($('#client-days').value)*86400:null,note:$('#client-note').value}; try{if($('#client-name').disabled){body.state=$('#client-state').value; await api(`/api/clients/${encodeURIComponent(name)}`,{method:'PUT',body:JSON.stringify(body)});toast('Client updated')}else{await api('/api/clients',{method:'POST',body:JSON.stringify(body)});toast('Client created')} closeModal('client-modal'); await loadClients(); await loadDashboard()}catch(err){toast(err.message,true)}}

async function clientAction(name,action){ if(!confirm(`${action} ${name}?`))return; try{await api(`/api/clients/${encodeURIComponent(name)}/${action}`,{method:'POST'});toast(action==='revoke'?'Client revoked':`${action} completed`);await loadClients();await loadDashboard()}catch(e){toast(e.message,true)} }
async function downloadProfile(name){try{const r=await fetch(`/api/clients/${encodeURIComponent(name)}/config`);if(!r.ok)throw new Error('Unable to download profile');const blob=await r.blob();const a=document.createElement('a');a.href=URL.createObjectURL(blob);a.download=`${name}.ovpn`;a.click();setTimeout(()=>URL.revokeObjectURL(a.href),1000);toast('Profile downloaded')}catch(e){toast(e.message,true)}}

async function loadSettings(){const s=await api('/api/settings');$('#panel-name').value=s.panel_name||'MehrVPN';$('#default-quota').value=s.default_quota_gb??50;$('#default-days').value=s.default_days??30;$('#public-url').textContent=s.public_url||'-';const o=s.openvpn||{};$('#vpn-info').textContent=o.port?`${o.proto||''} ${o.port} · ${o.server||''}`:(s.openvpn_error||'Unavailable')}
async function saveSettings(e){e.preventDefault();try{await api('/api/settings',{method:'PUT',body:JSON.stringify({panel_name:$('#panel-name').value,default_quota_gb:Number($('#default-quota').value),default_days:Number($('#default-days').value)})});toast('Settings saved')}catch(x){toast(x.message,true)}}
async function restartServer(){if(!confirm('Restart OpenVPN server?'))return;try{await api('/api/server/restart',{method:'POST'});toast('Server restart requested');setTimeout(loadDashboard,2000)}catch(e){toast(e.message,true)}}

async function loadAdmins(){const a=await api('/api/admins');$('#admins-body').innerHTML=a.map(x=>`<tr><td>${escapeHtml(x.username)}</td><td>${x.owner?'Owner':escapeHtml((x.permissions||[]).join(', '))}</td><td>${x.enabled?'Enabled':'Disabled'}</td></tr>`).join('')}
async function changePassword(e){e.preventDefault();try{await api('/api/password',{method:'POST',body:JSON.stringify({current:$('#current-password').value,new:$('#new-password').value})});toast('Password changed');$('#password-form').reset()}catch(x){toast(x.message,true)}}
async function loadAudit(){const rows=await api('/api/audit');$('#audit-body').innerHTML=rows.map(x=>`<tr><td>${x.id}</td><td>${escapeHtml(x.at||'')}</td><td>${escapeHtml(x.actor||'')}</td><td>${escapeHtml(x.action||'')}</td><td>${escapeHtml(x.target||'')}</td><td>${escapeHtml(x.detail||'')}</td></tr>`).join('')}

$('#login-form').addEventListener('submit',async e=>{e.preventDefault();$('#login-error').textContent='';try{const r=await api('/api/login',{method:'POST',body:JSON.stringify({username:$('#username').value,password:$('#password').value})});csrf=r.csrf;await boot()}catch(x){$('#login-error').textContent=x.message}});
$('#logout').addEventListener('click',async()=>{try{await api('/api/logout',{method:'POST'})}finally{location.reload()}});
$('.nav').addEventListener('click',async e=>{const b=e.target.closest('button[data-page]');if(!b)return;const p=b.dataset.page;show(p);try{if(p==='dashboard')await loadDashboard();if(p==='clients')await loadClients();if(p==='settings')await loadSettings();if(p==='admins')await loadAdmins();if(p==='audit')await loadAudit()}catch(x){toast(x.message,true)}});
$('#refresh').addEventListener('click',()=>loadDashboard().catch(e=>toast(e.message,true)));
$('#new-client').addEventListener('click',()=>{setFormDefaults();openModal('client-modal')});
$('#client-form').addEventListener('submit',saveClient);$('#close-client').addEventListener('click',()=>closeModal('client-modal'));$('#cancel-client').addEventListener('click',()=>closeModal('client-modal'));
$('#clients-search').addEventListener('input',e=>{state.filter=e.target.value;renderClients()});
$('#clients-body').addEventListener('click',e=>{const b=e.target.closest('button[data-action]');if(!b)return;const n=b.dataset.name; b.dataset.action==='edit'?editClient(n):b.dataset.action==='profile'?downloadProfile(n):clientAction(n,b.dataset.action)});
$('#settings-form').addEventListener('submit',saveSettings);$('#restart-server').addEventListener('click',restartServer);$('#password-form').addEventListener('submit',changePassword);
window.addEventListener('resize',()=>{if(state.view==='dashboard')loadDashboard().catch(()=>{})});
boot();
