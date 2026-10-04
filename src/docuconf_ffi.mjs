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
  } catch {
    // best effort
  }
  return undefined;
}

export function file_exists(path) {
  try {
    return fs.statSync(path).isFile();
  } catch {
    return false;
  }
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
