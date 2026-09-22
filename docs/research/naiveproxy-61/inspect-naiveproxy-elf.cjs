const fs = require('node:fs');
const crypto = require('node:crypto');
// Research helper for the two pinned little-endian assets, not a package gate.
if (process.argv.length < 3) throw Error('Pass one or more ELF paths');
for (const path of process.argv.slice(2)) {
  const b = fs.readFileSync(path);
  if (b.subarray(0, 4).toString('hex') !== '7f454c46' || b[5] !== 1) throw Error('Expected LE ELF');
  if (![1, 2].includes(b[4])) throw Error('Unsupported ELF class');
  const wide = b[4] === 2;
  const u16 = o => b.readUInt16LE(o);
  const u32 = o => b.readUInt32LE(o);
  const word = o => wide ? Number(b.readBigUInt64LE(o)) : u32(o);
  const phoff = word(wide ? 32 : 28), shoff = word(wide ? 40 : 32);
  const phsize = u16(wide ? 54 : 42), phnum = u16(wide ? 56 : 44);
  const shsize = u16(wide ? 58 : 46), shnum = u16(wide ? 60 : 48);
  const types = Array.from({length: phnum}, (_, i) => u32(phoff + i * phsize));
  const sections = Array.from({length: shnum}, (_, i) => shoff + i * shsize);
  const abi = sections.find(s => u32(s + 4) === 0x7000002a);
  const offset = abi === undefined ? null : word(abi + (wide ? 24 : 16));
  console.log(JSON.stringify({file: path, bytes: b.length,
    sha256: crypto.createHash('sha256').update(b).digest('hex'),
    elfClass: wide ? 64 : 32, endian: 'little', type: u16(16), machine: u16(18),
    flags: '0x' + u32(wide ? 48 : 36).toString(16),
    PT_INTERP: types.includes(3), PT_DYNAMIC: types.includes(2),
    SHT_DYNAMIC: sections.some(s => u32(s + 4) === 6),
    mipsAbi: offset === null ? null : {version: u16(offset), isaLevel:b[offset+2],
      isaRevision:b[offset+3], gprSize:b[offset+4], cpr1Size:b[offset+5], fpAbi:b[offset+7]}
  }, null, 2));
}
