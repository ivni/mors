// Research-only unpadded HTTP/2 CONNECT and HTTPS/DoH origin.
// settings.json contains the authorized bind/peer and synthetic credentials.
const fs = require('node:fs');
const path = require('node:path');
const http2 = require('node:http2');
const https = require('node:https');
const net = require('node:net');
const dir = path.resolve(process.argv[2]);
const settings = JSON.parse(fs.readFileSync(path.join(dir, 'settings.json')));
const read = name => fs.readFileSync(path.join(dir, name));
const tls = {key: read('valid.key'), cert: read('valid.pem')};
const stats = {sessions: 0, connects: 0, bytesRequests: 0, dnsRequests: 0,
  authRejects: 0, errors: {}};
const failure = (where, error) => {
  const code = /^[A-Z0-9_]+$/.test(error.code || '') ? error.code : 'UNKNOWN';
  const key = `${where}:${code}`;
  stats.errors[key] = (stats.errors[key] || 0) + 1;
};
const save = () => {
  const target = path.join(dir, 'fixture-stats.json');
  fs.writeFileSync(`${target}.tmp`, JSON.stringify(stats));
  fs.renameSync(`${target}.tmp`, target);
};
const body = Buffer.alloc(256 * 1024, 0x61);
const origin = https.createServer(tls, (req, res) => {
  if (req.url === '/bytes') {
    stats.bytesRequests++;
    res.writeHead(200, {'Content-Length': body.length}); res.end(body);
  } else if (req.url === '/dns-query' && req.method === 'POST') {
    const chunks = []; let total = 0;
    req.on('data', chunk => {
      total += chunk.length;
      if (total > 4096) req.destroy(); else chunks.push(chunk);
    });
    req.on('end', () => {
      try {
        const query = Buffer.concat(chunks); let offset = 12;
        while (query[offset]) {
          if (query[offset] > 63) throw Error('invalid label');
          offset += 1 + query[offset];
        }
        offset++;
        const type = query.readUInt16BE(offset);
        const header = Buffer.alloc(12);
        query.copy(header, 0, 0, 2); header.writeUInt16BE(0x8180, 2);
        header.writeUInt16BE(1, 4); header.writeUInt16BE(type === 1 ? 1 : 0, 6);
        const answer = type === 1
          ? Buffer.from('c00c000100010000001e0004c612003f', 'hex') : Buffer.alloc(0);
        const response = Buffer.concat([header, query.subarray(12, offset + 4), answer]);
        stats.dnsRequests++;
        res.writeHead(200, {'Content-Type': 'application/dns-message',
          'Content-Length': response.length}); res.end(response);
      } catch (_) { res.writeHead(400); res.end(); }
    });
  } else { res.writeHead(404); res.end(); }
});
origin.on('tlsClientError', error => failure('origin_tls', error));
origin.listen(18444, '127.0.0.1');
const auth = 'Basic ' + Buffer.from(`${settings.user}:${settings.password}`).toString('base64');
const proxy = http2.createSecureServer({...tls, allowHTTP1: false});
proxy.on('tlsClientError', error => failure('proxy_tls', error));
proxy.on('session', session => {
  if (session.socket.remoteAddress !== settings.peer) { session.close(); return; }
  stats.sessions++;
  session.on('error', error => failure('session', error));
});
proxy.on('stream', (stream, headers) => {
  stream.on('error', error => failure('stream', error));
  if (headers['proxy-authorization'] !== auth) {
    stats.authRejects++;
    stream.respond({':status': 407, 'proxy-authenticate': 'Basic realm="fixture"'});
    stream.end(); return;
  }
  if (headers[':method'] !== 'CONNECT' || headers[':authority'] !== 'nonce.fixture.invalid:18444') {
    stream.respond({':status': 403}); stream.end(); return;
  }
  stats.connects++;
  const upstream = net.connect(18444, '127.0.0.1', () => {
    if (stream.destroyed) { upstream.destroy(); return; }
    stream.respond({':status': 200}); stream.pipe(upstream).pipe(stream);
  });
  upstream.on('error', error => { failure('upstream', error); stream.close(); });
  stream.on('close', () => upstream.destroy());
});
proxy.listen(18443, settings.bind);
setInterval(save, 1000);
process.on('SIGTERM', () => { save(); process.exit(0); });
