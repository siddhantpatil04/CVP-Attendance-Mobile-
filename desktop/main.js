// CVP Attendance - Windows desktop app.
// Opens the app in its own big window (always the DESKTOP layout: left menu, wide pages).
//  - If app-config.json has a "url" (your Netlify address) the app loads from there, so every desktop is always up to date.
//  - Otherwise it runs the copy of the website that is packed inside this program.
const { app, BrowserWindow, Menu, session, shell } = require('electron');
const fs = require('fs');
const http = require('http');
const path = require('path');

let cfg = {};
try { cfg = JSON.parse(fs.readFileSync(path.join(__dirname, 'app-config.json'), 'utf8')); } catch { /* no config */ }

const TYPES = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8', '.png': 'image/png', '.jpg': 'image/jpeg', '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon', '.ttf': 'font/ttf', '.woff': 'font/woff', '.woff2': 'font/woff2', '.webmanifest': 'application/manifest+json',
};

/** Serves the packed website on a private local port (the app needs real http addresses, not file:// ones) */
function serveBundled() {
  const root = path.join(__dirname, 'web');
  return new Promise((resolve, reject) => {
    const server = http.createServer((req, res) => {
      let file = path.join(root, decodeURIComponent(req.url.split('?')[0]));
      if (!file.startsWith(root) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) file = path.join(root, 'index.html');
      res.writeHead(200, { 'Content-Type': TYPES[path.extname(file).toLowerCase()] || 'application/octet-stream' });
      fs.createReadStream(file).pipe(res);
    });
    // A FIXED port keeps the same web address every time, so the saved login and server settings are remembered.
    const FIXED_PORT = 47615;
    server.once('error', () => {
      server.once('error', reject);
      server.listen(0, '127.0.0.1', () => resolve(`http://127.0.0.1:${server.address().port}/`)); // port busy: any free port
    });
    server.listen(FIXED_PORT, '127.0.0.1', () => resolve(`http://127.0.0.1:${FIXED_PORT}/`));
  });
}

async function createWindow() {
  const target = cfg.url && /^https?:\/\//.test(cfg.url) ? cfg.url : await serveBundled();
  const win = new BrowserWindow({
    width: 1366, height: 860, minWidth: 1000, minHeight: 700,   // wider than 900 px = desktop layout
    backgroundColor: '#F5F8FC', title: 'CVP Attendance', autoHideMenuBar: true,
    webPreferences: { contextIsolation: true, nodeIntegration: false },
  });
  win.maximize();
  win.loadURL(target).catch(() => {});
  // links to other websites open in the normal browser
  win.webContents.setWindowOpenHandler(({ url }) => { shell.openExternal(url); return { action: 'deny' }; });
  win.webContents.on('did-fail-load', (_e, code, desc, _url, isMain) => {
    if (isMain && code !== -3) win.loadURL(`data:text/html,<body style="font-family:Segoe UI;padding:40px"><h2>CVP Attendance</h2><p>Could not load the app (${desc}). Check the internet connection, then press Ctrl+R.</p>`);
  });
}

if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.on('second-instance', () => {
    const [win] = BrowserWindow.getAllWindows();
    if (win) { if (win.isMinimized()) win.restore(); win.focus(); }
  });
  app.whenReady().then(() => {
    Menu.setApplicationMenu(null);
    session.defaultSession.setPermissionRequestHandler((_wc, permission, cb) => cb(['geolocation', 'media', 'notifications', 'clipboard-read'].includes(permission)));
    createWindow();
    app.on('activate', () => { if (BrowserWindow.getAllWindows().length === 0) createWindow(); });
  });
  app.on('window-all-closed', () => { if (process.platform !== 'darwin') app.quit(); });
}