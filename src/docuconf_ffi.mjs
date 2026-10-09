// JavaScript target FFI (Node.js). Mirrors docuconf_ffi.erl.
import { Ok, Error, toList, BitArray } from "./gleam.mjs";
import * as fs from "node:fs";
import * as crypto from "node:crypto";

export function regex_compile(pattern) {
  try {
    new RegExp(pattern, "u");
    return new Ok(undefined);
  } catch (e) {
    return new Error(`invalid pattern: ${e.message}`);
  }
}

export function regex_matches(pattern, value) {
  return new RegExp(pattern, "u").test(value);
}

export function json_decode(text) {
  try {
    return new Ok(JSON.parse(text));
  } catch (e) {
    return new Error(e.message);
  }
}

export function read_file(path) {
  try {
    return new Ok(new BitArray(new Uint8Array(fs.readFileSync(path))));
  } catch (e) {
    return new Error((e.code ?? "error").toLowerCase());
  }
}

export function file_info(path) {
  try {
    const st = fs.statSync(path);
    const type = st.isFile() ? "regular" : st.isDirectory() ? "directory" : "other";
    return new Ok([type, st.size]);
  } catch (e) {
    return new Error((e.code ?? "error").toLowerCase());
  }
}

export function write_file(path, text) {
  try {
    fs.writeFileSync(path, text);
    return new Ok(undefined);
  } catch (e) {
    return new Error((e.code ?? "error").toLowerCase());
  }
}

export function exit(status) {
  process.exit(status);
}

export function identity(x) {
  return x;
}

export function file_exists(path) {
  try {
    return fs.statSync(path).isFile();
  } catch {
    return false;
  }
}

// Integers are exact only within ±(2^53 - 1) on this target.
// An integer literal beyond ±(2^53 - 1) in JSON text, kept as its source.
class BigLiteral {
  constructor(text) {
    this.text = text;
  }
}

export function json_decode_exact(text) {
  try {
    return new Ok(
      JSON.parse(text, (_key, value, context) =>
        typeof value === "number" && !Number.isSafeInteger(value) && /^-?[0-9]+$/.test(context?.source ?? "")
          ? new BigLiteral(context.source)
          : value,
      ),
    );
  } catch (e) {
    return new Error(e.message);
  }
}

export function big_literal(value) {
  return value instanceof BigLiteral ? new Ok(value.text) : new Error(undefined);
}

export function int_limits() {
  return new Ok([Number.MIN_SAFE_INTEGER, Number.MAX_SAFE_INTEGER]);
}

export function now_unix() {
  return Math.floor(Date.now() / 1000);
}

export function print_error(msg) {
  process.stderr.write(msg + "\n");
  return undefined;
}

function pemBlocks(pem) {
  return pem.match(/-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----/g) ?? [];
}

function parse(block) {
  try {
    return new crypto.X509Certificate(block);
  } catch {
    return null;
  }
}

export function pem_count(pem) {
  const blocks = pemBlocks(pem);
  return [blocks.length, blocks.map(parse).filter((c) => c !== null).length];
}

const ALG = { rsa: "RSA", ec: "ECDSA", ed25519: "Ed25519" };

export function tls_check(certPem, keyPem, caPem, dnsNames, keyAlgs, minRemaining, now) {
  const out = [];
  const fail = (code, msg) => out.push([code, msg]);
  const blocks = pemBlocks(certPem);
  if (blocks.length === 0) {
    fail("certificate_invalid", "tls.crt holds no PEM certificate");
    return toList(out);
  }
  const chain = blocks.map(parse);
  if (chain.some((c) => c === null)) {
    fail("certificate_invalid", "tls.crt holds a certificate that cannot be parsed");
    return toList(out);
  }
  const leaf = chain[0];
  try {
    const key = crypto.createPrivateKey(keyPem);
    if (!leaf.checkPrivateKey(key)) fail("key_mismatch", "tls.key does not match the certificate in tls.crt");
  } catch {
    fail("certificate_invalid", "tls.key is not a readable PEM private key");
  }
  const from = Date.parse(leaf.validFrom) / 1000;
  const to = Date.parse(leaf.validTo) / 1000;
  if (now < from) fail("certificate_invalid", "certificate is not valid yet");
  else if (now > to) fail("certificate_invalid", "certificate has expired");
  else if (minRemaining > 0 && to - now < minRemaining)
    fail("certificate_expiring", `certificate expires in ${Math.floor(to - now)}s, less than minRemaining (${minRemaining}s)`);
  for (const name of dnsNames.toArray()) {
    if (leaf.checkHost(name, { wildcards: true, multiLabelWildcards: false, subject: "default" }) === undefined)
      fail("certificate_name_mismatch", `certificate does not cover ${name}`);
  }
  const algs = keyAlgs.toArray();
  if (algs.length > 0) {
    const alg = ALG[leaf.publicKey.asymmetricKeyType] ?? "other";
    if (!algs.includes(alg)) fail("certificate_invalid", `key algorithm ${alg} is not allowed`);
  }
  if (caPem !== "") {
    const anchors = pemBlocks(caPem).map(parse).filter((c) => c !== null);
    if (anchors.length === 0) fail("certificate_invalid", "ca.crt holds no parseable certificate");
    else {
      // Walk leaf -> intermediates -> an anchor, checking each signature.
      let ok = false;
      let current = leaf;
      const rest = chain.slice(1);
      for (let i = 0; i <= rest.length && !ok; i++) {
        if (anchors.some((a) => current.checkIssued(a) && current.verify(a.publicKey))) ok = true;
        else if (i < rest.length && current.checkIssued(rest[i]) && current.verify(rest[i].publicKey)) current = rest[i];
        else break;
      }
      if (!ok) fail("certificate_invalid", "tls.crt does not chain to a certificate in ca.crt");
    }
  }
  return toList(out);
}

// ---- keystores ----------------------------------------------------------------
//
// Verifies a keystore's integrity MAC with its password, like keystore_verify
// in docuconf_ffi.erl: PKCS#12 (RFC 7292 key derivation and HMAC with SHA-1 or
// SHA-2) and JKS/JCEKS (SHA-1 integrity digest). A correct MAC proves the
// password is right and the file is intact; nothing is decrypted.

const MAC_HASHES = {
  "1.3.14.3.2.26": ["sha1", 64],
  "2.16.840.1.101.3.4.2.4": ["sha224", 64],
  "2.16.840.1.101.3.4.2.1": ["sha256", 64],
  "2.16.840.1.101.3.4.2.2": ["sha384", 128],
  "2.16.840.1.101.3.4.2.3": ["sha512", 128],
};
const PBMAC1 = "1.2.840.113549.1.5.14";

class Bad extends globalThis.Error {}

export function keystore_verify(format, bits, password) {
  const bytes = Buffer.alloc(bits.byteSize);
  for (let i = 0; i < bits.byteSize; i++) bytes[i] = bits.byteAt(i);
  try {
    const why = format === "pkcs12" ? pkcs12(bytes, password) : jks(bytes, password);
    return why === null ? new Ok(undefined) : new Error(why);
  } catch (e) {
    if (e instanceof Bad) return new Error(e.message);
    return new Error("not a DER-encoded PKCS#12 (PFX) file");
  }
}

function tlv(buf) {
  if (buf.length < 2) throw new RangeError("short");
  const tag = buf[0];
  let len = buf[1];
  let off = 2;
  if (len === 0x80 && (tag === 0x30 || tag === 0x24 || tag === 0xa0))
    throw new Bad("BER indefinite-length encoding is not supported; convert with openssl pkcs12");
  if (len & 0x80) {
    const n = len & 0x7f;
    if (n < 1 || n > 4 || buf.length < 2 + n) throw new RangeError("length");
    len = 0;
    for (let i = 0; i < n; i++) len = len * 256 + buf[2 + i];
    off = 2 + n;
  }
  if (buf.length < off + len) throw new RangeError("truncated");
  return [tag, buf.subarray(off, off + len), buf.subarray(off + len)];
}

function seq(buf) {
  const items = [];
  while (buf.length > 0) {
    const [tag, value, rest] = tlv(buf);
    items.push([tag, value]);
    buf = rest;
  }
  return items;
}

function oid(der) {
  const arcs = [Math.floor(der[0] / 40), der[0] % 40];
  let cur = 0;
  for (const b of der.subarray(1)) {
    cur = cur * 128 + (b & 0x7f);
    if (!(b & 0x80)) {
      arcs.push(cur);
      cur = 0;
    }
  }
  return arcs.join(".");
}

function bmp(password) {
  const out = Buffer.alloc(password.length * 2 + 2);
  for (let i = 0; i < password.length; i++) out.writeUInt16BE(password.charCodeAt(i), i * 2);
  return out;
}

function stretch(buf, v) {
  if (buf.length === 0) return buf;
  const len = v * Math.ceil(buf.length / v);
  const out = Buffer.alloc(len);
  for (let i = 0; i < len; i++) out[i] = buf[i % buf.length];
  return out;
}

// RFC 7292 appendix B.2.
function kdf(hash, v, password, salt, id, iterations, n) {
  const d = Buffer.alloc(v, id);
  let i = Buffer.concat([stretch(salt, v), stretch(password, v)]);
  const out = [];
  let produced = 0;
  while (produced < n) {
    let a = Buffer.concat([d, i]);
    for (let k = 0; k < iterations; k++) a = crypto.createHash(hash).update(a).digest();
    out.push(a);
    produced += a.length;
    const b = stretch(a, v).subarray(0, v);
    const next = Buffer.alloc(i.length);
    for (let off = 0; off < i.length; off += v) {
      // next block = (block + b + 1) mod 2^(8v), big-endian
      let carry = 1;
      for (let j = v - 1; j >= 0; j--) {
        const sum = i[off + j] + b[j] + carry;
        next[off + j] = sum & 0xff;
        carry = sum >> 8;
      }
    }
    i = next;
  }
  return Buffer.concat(out).subarray(0, n);
}

function pkcs12(der, password) {
  const [tag, pfx, rest] = tlv(der);
  if (tag !== 0x30 || rest.length !== 0) throw new RangeError("not a sequence");
  const [version, authSafe, ...mac] = seq(pfx);
  if (version[0] !== 0x02 || authSafe[0] !== 0x30) throw new RangeError("not a PFX");
  const plain = "PKCS#12 authSafe is not plain data (public-key integrity mode is not supported)";
  const content = seq(authSafe[1]);
  if (content.length !== 2 || content[0][0] !== 0x06 || content[1][0] !== 0xa0) return plain;
  const [dataTag, data, after] = tlv(content[1][1]);
  if (dataTag !== 0x04 || after.length !== 0) return plain;
  if (mac.length === 0) return "the PKCS#12 file has no integrity MAC, so its password cannot be checked";
  if (mac.length !== 1 || mac[0][0] !== 0x30) return "malformed PKCS#12 MacData";
  const macData = seq(mac[0][1]);
  if (macData.length < 2 || macData[0][0] !== 0x30 || macData[1][0] !== 0x04) return "malformed PKCS#12 MacData";
  const [alg, digest] = seq(macData[0][1]);
  const salt = macData[1][1];
  const iterations = macData.length > 2 ? parseInt(macData[2][1].toString("hex") || "0", 16) : 1;
  const [oidItem] = seq(alg[1]);
  const id = oid(oidItem[1]);
  const known = MAC_HASHES[id];
  if (!known) return id === PBMAC1 ? "PBMAC1 integrity MACs are not supported yet" : `unsupported MAC digest ${id}`;
  const [hash, block] = known;
  // OpenSSL encodes an empty password as the two-byte BMP terminator, some
  // other tools as nothing at all; try both.
  const candidates = password === "" ? [bmp(""), Buffer.alloc(0)] : [bmp(password)];
  const ok = candidates.some((pw) => {
    const key = kdf(hash, block, pw, salt, 3, iterations, digest[1].length);
    const got = crypto.createHmac(hash, key).update(data).digest();
    return crypto.timingSafeEqual(got, digest[1]);
  });
  return ok ? null : "wrong password or corrupted file: the integrity MAC does not match";
}

function jks(content, password) {
  const magic = content.length >= 4 ? content.readUInt32BE(0) : 0;
  if ((magic !== 0xfeedfeed && magic !== 0xcececece) || content.length <= 20) return "not a JKS or JCEKS keystore";
  const body = content.subarray(0, content.length - 20);
  const digest = content.subarray(content.length - 20);
  const pw = bmp(password).subarray(0, password.length * 2);
  const got = crypto.createHash("sha1").update(pw).update("Mighty Aphrodite").update(body).digest();
  return got.equals(digest) ? null : "wrong password or corrupted file: the integrity digest does not match";
}
