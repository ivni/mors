// Controlled HTTPS CONNECT fixture, not a production Naive server.
// No network destinations are taken from requests: tunnels reach only our origin.
// No Naive padding is negotiated. Loopback + SSH transport is a separate test path.
const fs = require('node:fs');
const path = require('node:path');
const http2 = require('node:http2');
const https = require('node:https');
const net = require('node:net');
const dir = path.resolve(process.argv[2]);
const statsFile = path.join(dir, 'stats.json');
const stats = {tlsErrors: {}, sessions: {}, connects: {}, authRejects: {}, nonces: [], originRequests: 0};
const save = () => fs.writeFileSync(statsFile, JSON.stringify(stats));
const read = name => fs.readFileSync(path.join(dir, name));
const origin = https.createServer({key: read('valid.key'), cert: read('valid.pem')}, (req, res) => {
  stats.originRequests++;
  const url = new URL(req.url, 'https://nonce.fixture.invalid');
  if (url.pathname === '/nonce') {
    const nonce = url.searchParams.get('value');
    if (!/^[a-f0-9]{32}$/.test(nonce || '')) { res.writeHead(400); res.end(); return; }
    stats.nonces.push(nonce);
    save();
    res.writeHead(200, {'Content-Type': 'text/plain', 'Cache-Control': 'no-store'});
    res.end(nonce);
  } else if (url.pathname === '/bytes') {
    const size = 256 * 1024;
    res.writeHead(200, {'Content-Type': 'application/octet-stream', 'Content-Length': size});
    res.end(Buffer.alloc(size, 0x61));
  } else if (url.pathname === '/stream') {
    const chunks = 30;
    let sent = 0;
    res.writeHead(200, {'Content-Type': 'application/octet-stream', 'Content-Length': chunks * 1024});
    const timer = setInterval(() => {
      res.write(Buffer.alloc(1024, 0x62));
      if (++sent === chunks) { clearInterval(timer); res.end(); }
    }, 500);
    res.on('close', () => clearInterval(timer));
  } else { res.writeHead(404); res.end(); }
});
origin.listen(18444, '127.0.0.1');
const variants = [
  ['valid', 18443, 'valid.pem', 'valid.key'],
  ['wrong-name', 18445, 'wrong-name.pem', 'wrong-name.key'],
  ['expired', 18446, 'expired.pem', 'expired.key'],
  ['incomplete', 18447, 'chain.pem', 'chain.key'],
  ['full-chain', 18448, 'full-chain.pem', 'chain.key'],
  ['unknown', 18449, 'unknown.pem', 'unknown.key'],
];
const auth = 'Basic ' + Buffer.from('fixture:fixture-password').toString('base64');
const servers = variants.map(([label, port, cert, key]) => {
  const server = http2.createSecureServer({cert: read(cert), key: read(key), allowHTTP1: false});
  server.on('tlsClientError', () => { stats.tlsErrors[label] = (stats.tlsErrors[label] || 0) + 1; save(); });
  server.on('session', session => {
    stats.sessions[label] = (stats.sessions[label] || 0) + 1; save();
    session.on('error', () => {});
  });
  server.on('stream', (stream, headers) => {
    stream.on('error', () => {});
    if (headers['proxy-authorization'] !== auth) {
      stats.authRejects[label] = (stats.authRejects[label] || 0) + 1; save();
      stream.respond({':status': 407, 'proxy-authenticate': 'Basic realm="fixture"'});
      stream.end(); return;
    }
    if (headers[':method'] !== 'CONNECT' || headers[':authority'] !== 'nonce.fixture.invalid:18444') {
      stream.respond({':status': 403}); stream.end(); return;
    }
    stats.connects[label] = (stats.connects[label] || 0) + 1; save();
    const upstream = net.connect(18444, '127.0.0.1', () => {
      stream.respond({':status': 200});
      stream.pipe(upstream).pipe(stream);
    });
    upstream.on('error', () => stream.close());
    stream.on('close', () => upstream.destroy());
  });
  server.listen(port, '127.0.0.1');
  return server;
});
save();
console.log('FIXTURE_READY');
process.on('SIGTERM', () => { save(); process.exit(0); });
