# Layout.ps1 - shared page "chrome" (sidebar + top bar + theme) for the restyled UI.
# Get-AppChrome returns @{ head; open; close } HTML fragments that a .pode view wraps its content in:
#     $($data.head)$($data.open)  ...page content...  $($data.close)
# Composed in the ROUTE (where module functions are available) and passed to the view as data.
#
# Theme: light + dark via a [data-theme] attribute on <html>, persisted in localStorage. A tiny head
# script applies the saved theme before paint (no flash); the top-bar button toggles it.

$script:PSCIcons = @{
    run          = "<svg viewBox='0 0 24 24' fill='none' stroke='currentColor' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'><polyline points='4 17 10 11 4 5'/><line x1='12' y1='19' x2='20' y2='19'/></svg>"
    create       = "<svg viewBox='0 0 24 24' fill='none' stroke='currentColor' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'><path d='M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2'/><circle cx='9' cy='7' r='4'/><line x1='19' y1='8' x2='19' y2='14'/><line x1='16' y1='11' x2='22' y2='11'/></svg>"
    onboarding   = "<svg viewBox='0 0 24 24' fill='none' stroke='currentColor' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'><path d='M18 10h-1.26A8 8 0 1 0 9 20h9a5 5 0 0 0 0-10z'/></svg>"
    decommission = "<svg viewBox='0 0 24 24' fill='none' stroke='currentColor' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'><path d='M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2'/><circle cx='9' cy='7' r='4'/><line x1='16' y1='11' x2='22' y2='11'/></svg>"
    config       = "<svg viewBox='0 0 24 24' fill='none' stroke='currentColor' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'><circle cx='12' cy='12' r='3'/><path d='M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z'/></svg>"
    audit        = "<svg viewBox='0 0 24 24' fill='none' stroke='currentColor' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'><line x1='8' y1='6' x2='21' y2='6'/><line x1='8' y1='12' x2='21' y2='12'/><line x1='8' y1='18' x2='21' y2='18'/><line x1='3' y1='6' x2='3.01' y2='6'/><line x1='3' y1='12' x2='3.01' y2='12'/><line x1='3' y1='18' x2='3.01' y2='18'/></svg>"
    brand        = "<svg viewBox='0 0 24 24' fill='none' stroke='currentColor' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'><polyline points='4 7 9 12 4 17'/><line x1='12' y1='17' x2='20' y2='17'/></svg>"
    dashboard    = "<svg viewBox='0 0 24 24' fill='none' stroke='currentColor' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'><rect x='3' y='3' width='7' height='7'/><rect x='14' y='3' width='7' height='7'/><rect x='14' y='14' width='7' height='7'/><rect x='3' y='14' width='7' height='7'/></svg>"
    theme        = "<svg viewBox='0 0 24 24' fill='none' stroke='currentColor' stroke-width='2'><circle cx='12' cy='12' r='9'/><path d='M12 3v18a9 9 0 0 0 0-18z' fill='currentColor' stroke='none'/></svg>"
    reports      = "<svg viewBox='0 0 24 24' fill='none' stroke='currentColor' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'><line x1='6' y1='20' x2='6' y2='14'/><line x1='12' y1='20' x2='12' y2='4'/><line x1='18' y1='20' x2='18' y2='10'/></svg>"
    veeam        = "<svg viewBox='0 0 24 24' fill='none' stroke='currentColor' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'><path d='M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z'/><polyline points='9 12 11 14 15 10'/></svg>"
    inventory    = "<svg viewBox='0 0 24 24' fill='none' stroke='currentColor' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'><rect x='2' y='3' width='20' height='14' rx='2'/><line x1='8' y1='21' x2='16' y2='21'/><line x1='12' y1='17' x2='12' y2='21'/></svg>"
    hyperv       = "<svg viewBox='0 0 24 24' fill='none' stroke='currentColor' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'><rect x='2' y='3' width='9' height='7' rx='1'/><rect x='13' y='3' width='9' height='7' rx='1'/><rect x='2' y='14' width='9' height='7' rx='1'/><rect x='13' y='14' width='9' height='7' rx='1'/></svg>"
}

function Get-AppStyles {
@'
<style>
:root{--bg:#f4f6f9;--panel:#fff;--text:#1f2733;--muted:#667085;--border:#e5e7eb;--accent:#2563eb;
--accent-soft:#e8f0fe;--hover:#f1f5f9;--topbar:#0f172a;--topbar-text:#e6eaf2;--sidebar:#fff;
--chip:rgba(255,255,255,.12);--shadow:0 1px 2px rgba(16,24,40,.06);--input:#fff;--input-border:#d0d5dd;
--ok-bg:#ecfdf3;--ok-fg:#067647;--ok-bd:#abefc6;--err:#d92d20;--warn-bg:#fffaeb;--warn-fg:#b54708;--warn-bd:#fedf89;}
html[data-theme=dark]{--bg:#0f1115;--panel:#141922;--text:#e6e6e6;--muted:#94a3b8;--border:#262b36;
--accent:#3b82f6;--accent-soft:#1e293b;--hover:#1b2130;--topbar:#0b0e14;--topbar-text:#e6eaf2;--sidebar:#141922;
--chip:rgba(255,255,255,.08);--shadow:none;--input:#171a21;--input-border:#2a3140;
--ok-bg:#0d2a1c;--ok-fg:#34d399;--ok-bd:#14532d;--err:#f87171;--warn-bg:#3b2f0b;--warn-fg:#fde68a;--warn-bd:#a16207;}
*{box-sizing:border-box}
body{margin:0;font-family:'Segoe UI',system-ui,Arial,sans-serif;background:var(--bg);color:var(--text);font-size:14px}
a{color:var(--accent);text-decoration:none}a:hover{text-decoration:underline}
.layout{display:flex;min-height:100vh}
.sidebar{width:232px;background:var(--sidebar);border-right:1px solid var(--border);position:fixed;top:0;bottom:0;left:0;display:flex;flex-direction:column;z-index:10}
.brand{display:flex;align-items:center;gap:9px;padding:15px 18px;font-weight:600;font-size:16px;border-bottom:1px solid var(--border)}
.brand svg{width:22px;height:22px;color:var(--accent)}
.nav{padding:12px 10px;display:flex;flex-direction:column;gap:3px;overflow-y:auto}
.nav-item{display:flex;align-items:center;gap:11px;padding:9px 12px;border-radius:8px;color:var(--muted);font-size:14px}
.nav-item:hover{background:var(--hover);color:var(--text);text-decoration:none}
.nav-item.active{background:var(--accent-soft);color:var(--accent);font-weight:600}
.nav-item svg{width:17px;height:17px;flex:none}
.main{margin-left:232px;flex:1;display:flex;flex-direction:column;min-width:0}
.topbar{height:56px;background:var(--topbar);color:var(--topbar-text);display:flex;align-items:center;justify-content:space-between;padding:0 22px;position:sticky;top:0;z-index:5}
.topbar .title{font-size:16px;font-weight:600}
.topbar .sub{font-size:13px;color:#aab4c5;margin-left:10px;font-weight:400}
.topbar .right{display:flex;align-items:center;gap:12px}
.chip{background:var(--chip);padding:4px 11px;border-radius:20px;font-size:12px;color:var(--topbar-text)}
.topbar button svg{width:15px;height:15px}
.topbar .right button,.topbar .right .btn{color:var(--topbar-text);border-color:rgba(255,255,255,.28)}
.topbar .right button:hover,.topbar .right .btn:hover{background:rgba(255,255,255,.10);filter:none}
.brand img{display:block}
.content{padding:22px;max-width:1200px;width:100%}
.card{background:var(--panel);border:1px solid var(--border);border-radius:10px;padding:16px 18px;margin-bottom:18px;box-shadow:var(--shadow)}
.card h3{margin:0 0 12px;font-size:15px}
h1,h2{margin:0 0 6px}
button,.btn{font-family:inherit;padding:9px 15px;background:var(--accent);border:0;color:#fff;border-radius:7px;cursor:pointer;font-size:13px}
button:hover,.btn:hover{filter:brightness(1.06)}
button.secondary,.btn.secondary{background:transparent;border:1px solid var(--input-border);color:var(--text)}
button.danger{background:var(--err)}
button:disabled{opacity:.5;cursor:not-allowed}
input,select,textarea{font-family:inherit;padding:9px 10px;background:var(--input);border:1px solid var(--input-border);color:var(--text);border-radius:7px;box-sizing:border-box}
label{display:block;margin:10px 0 4px;font-size:13px;color:var(--muted)}
table{width:100%;border-collapse:collapse}
th,td{border-bottom:1px solid var(--border);padding:7px 10px;font-size:13px;text-align:left}
th{background:var(--hover);font-weight:600}
.note{color:var(--muted);font-size:12px}
.ok{color:var(--ok-fg)}.err{color:var(--err)}
.badge{display:inline-flex;align-items:center;gap:5px;padding:2px 9px;border-radius:20px;font-size:12px;background:var(--ok-bg);color:var(--ok-fg);border:1px solid var(--ok-bd)}
.alert{padding:10px 13px;border-radius:8px;margin:12px 0;font-size:13px}
.alert.ok{background:var(--ok-bg);color:var(--ok-fg);border:1px solid var(--ok-bd)}
.alert.warn{background:var(--warn-bg);color:var(--warn-fg);border:1px solid var(--warn-bd)}
.alert.err{background:var(--warn-bg);color:var(--err);border:1px solid var(--warn-bd)}
.grid2{display:grid;grid-template-columns:1fr 1fr;gap:14px 20px}
td.k{color:var(--muted);width:190px}
.fold{border-top:1px solid var(--border);margin-top:16px;padding-top:14px}
code{background:var(--hover);padding:1px 5px;border-radius:4px;font-size:12px}
pre{background:var(--bg);border:1px solid var(--border);border-radius:8px;padding:12px;font-size:12px;overflow:auto}
textarea{width:100%;padding:10px;background:var(--input);border:1px solid var(--input-border);color:var(--text);border-radius:7px;box-sizing:border-box;font-family:Consolas,monospace;font-size:13px;line-height:1.5;resize:vertical}
.pill{padding:1px 8px;border-radius:10px;font-size:11px;font-weight:600;display:inline-block}
.s-complete{background:var(--ok-bg);color:var(--ok-fg)}
.s-pending-sync{background:var(--hover);color:var(--muted)}
.s-partial{background:var(--warn-bg);color:var(--err)}
.s-manual-needed{background:var(--warn-bg);color:var(--warn-fg)}
.man{color:var(--warn-fg)}.auto{color:var(--muted)}.fail{color:var(--err)}
body.login{display:flex;min-height:100vh;align-items:center;justify-content:center}
body.login .card{width:340px;max-width:90vw;margin:0}
body.login input{width:100%;margin:6px 0}
body.login button{width:100%;margin-top:10px}
</style>
'@
}

# Minimal head for the unauthenticated login page (shared styles + theme, no sidebar shell).
function Get-LoginHead {
    $fouc = "(function(){try{var t=localStorage.getItem('psc-theme')||'light';document.documentElement.setAttribute('data-theme',t);}catch(e){}})();"
    "<!DOCTYPE html><html data-theme='light'><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'><title>Sign in - PSConsole</title>$(Get-AppStyles)<script>$fouc</script></head>"
}

function Get-AppChrome {
    param([string]$Active, $User, [string]$Title, [string]$Subtitle = '', [bool]$HasLogo = $false)
    $role = [string]$User.role
    # Nav visibility mirrors RBAC: admin sees everything; helpdesk sees only its config-driven features
    # (Config > Helpdesk feature access). Compute the helpdesk set ONCE here (one config read) rather than
    # calling Test-Authorized per item. Add-on tabs also require the add-on to be configured.
    $isAdmin = ($role -eq 'admin')
    $hd = if ($isAdmin) { @() } else { @(Get-HelpdeskFeatures) }
    $items = @(
        @{ href='/dashboard';           key='dashboard';    label='Dashboard';     icon=$script:PSCIcons.dashboard;    show=$true }
        @{ href='/';                    key='run';          label='Run Scripts';   icon=$script:PSCIcons.run;          show=($isAdmin -or ($hd -contains 'run')) }
        @{ href='/users/new';           key='create';       label='Create User';   icon=$script:PSCIcons.create;       show=($isAdmin -or ($hd -contains 'create-user')) }
        @{ href='/users/onboarding';    key='onboarding';   label='Onboarding';    icon=$script:PSCIcons.onboarding;   show=($isAdmin -or ($hd -contains 'create-user')) }
        @{ href='/users/decommission';  key='decommission'; label='Decommission';  icon=$script:PSCIcons.decommission; show=($isAdmin -or ($hd -contains 'decommission-user')) }
        @{ href='/admin/reports';       key='reports';      label='Reports';       icon=$script:PSCIcons.reports;      show=($isAdmin -or ($hd -contains 'manage-reports')) }
        @{ href='/admin/veeam';         key='veeam';        label='Veeam';         icon=$script:PSCIcons.veeam;        show=(($isAdmin -or ($hd -contains 'veeam-reports')) -and (Test-VeeamConfigured)) }
        @{ href='/admin/hyperv';        key='hyperv';       label='Hyper-V';       icon=$script:PSCIcons.hyperv;       show=(($isAdmin -or ($hd -contains 'hyperv-view')) -and (Test-HyperVConfigured)) }
        @{ href='/inventory';           key='inventory';    label='Inventory';     icon=$script:PSCIcons.inventory;    show=(($isAdmin -or ($hd -contains 'inventory')) -and (Test-InventoryConfigured)) }
        @{ href='/admin/config';        key='config';       label='Config';        icon=$script:PSCIcons.config;       show=$isAdmin }
        @{ href='/audit';               key='audit';        label='Audit';         icon=$script:PSCIcons.audit;        show=$isAdmin }
    )
    $nav = ($items | Where-Object { $_.show } | ForEach-Object {
        $cls = if ($_.key -eq $Active) { 'nav-item active' } else { 'nav-item' }
        "<a class='$cls' href='$($_.href)'>$($_.icon)<span>$($_.label)</span></a>"
    }) -join ''

    $brandInner = if ($HasLogo) { "<img src='/logo' alt='PSConsole' style='max-height:50px;max-width:196px'>" } else { "$($script:PSCIcons.brand)<span>PSConsole</span>" }
    $sub  = if ($Subtitle) { "<span class='sub'>$Subtitle</span>" } else { '' }
    $userChip = "<span class='chip'>$(ConvertTo-PSCEncoded ([string]$User.username)) &middot; $(ConvertTo-PSCEncoded $role)</span>"

    $fouc   = "(function(){try{var t=localStorage.getItem('psc-theme')||'light';document.documentElement.setAttribute('data-theme',t);}catch(e){}})();"
    $toggle = "function pscToggleTheme(){var h=document.documentElement;var c=(h.getAttribute('data-theme')==='dark')?'light':'dark';h.setAttribute('data-theme',c);try{localStorage.setItem('psc-theme',c);}catch(e){}pscThemeLabel();}function pscThemeLabel(){var s=document.getElementById('themeLbl');if(!s)return;s.textContent=(document.documentElement.getAttribute('data-theme')==='dark')?'Light':'Dark';}pscThemeLabel();"
    $themeBtn = "<button id='themeBtn' class='secondary' style='padding:5px 10px;display:inline-flex;align-items:center;gap:6px' onclick='pscToggleTheme()'>$($script:PSCIcons.theme)<span id='themeLbl'>Dark</span></button>"

    $head = "<!DOCTYPE html><html data-theme='light'><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'><title>$Title - PSConsole</title>$(Get-AppStyles)<script>$fouc</script></head>"
    $open = "<body><div class='layout'><aside class='sidebar'><div class='brand'>$brandInner</div><nav class='nav'>$nav</nav></aside><div class='main'><header class='topbar'><div><span class='title'>$Title</span>$sub</div><div class='right'>$themeBtn$userChip<form method='post' action='/logout' style='margin:0'><button class='secondary' style='padding:5px 11px'>Logout</button></form></div></header><main class='content'>"
    $close = "</main></div></div><script>$toggle</script></body></html>"
    @{ head = $head; open = $open; close = $close }
}
