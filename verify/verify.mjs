#!/usr/bin/env node
// tesser-verify-boxd <bundle> <statement> <signature>
//
// Installed in the box image as /usr/local/bin/tesser-verify-boxd. At first
// boot, tesser-boot fetches boxd's bundle, its signed statement and the
// signature from the control plane, and only installs boxd if this exits 0.
//
// The statement is JSON: {"kind":"boxd","version":"...","sha256":"<hex>"}.
// It is accepted only if
//   1. the signature is a valid ed25519 signature over the statement's exact
//      bytes by RELEASE_PUBLIC_KEY,
//   2. its kind is "boxd",
//   3. it names a version and a sha256, and
//   4. sha256(bundle) equals that sha256.
// On success it prints the version. On failure it prints why and exits 1.
//
// Node built-ins only, so there is nothing else to audit.

import { createHash, createPublicKey, verify } from "node:crypto";
import { readFileSync } from "node:fs";

// tesser's release signing key: the base64url ed25519 public key (the JWK
// "x"). The same key is RELEASE_PUBLIC_KEY in tesser's protocol/src/signed.ts.
const RELEASE_PUBLIC_KEY = "jZCQ60xiCQIZFIQ5q0TMaTOPCYpmgboFbVP8eeyhkz0";

function verifySigned(text, signature, kind, publicKey) {
  const key = createPublicKey({ key: { kty: "OKP", crv: "Ed25519", x: publicKey }, format: "jwk" });
  if (!verify(null, Buffer.from(text), key, Buffer.from(signature.trim(), "base64"))) {
    throw new Error(`${kind} statement is not signed by the trusted key`);
  }
  const body = JSON.parse(text);
  const got = typeof body === "object" && body !== null ? body.kind : undefined;
  if (got !== kind) throw new Error(`signed statement is kind ${JSON.stringify(got)}, not ${kind}`);
  return body;
}

function verifyBoxd(bundle, text, signature, publicKey) {
  const s = verifySigned(text, signature, "boxd", publicKey);
  if (typeof s.version !== "string" || typeof s.sha256 !== "string") throw new Error("boxd statement has no version or sha256");
  const actual = createHash("sha256").update(bundle).digest("hex");
  if (actual !== s.sha256) throw new Error(`boxd bundle sha256 ${actual} does not match its statement (${s.sha256})`);
  return { kind: "boxd", version: s.version, sha256: s.sha256 };
}

const [bundle, statement, signature] = process.argv.slice(2);
if (bundle === undefined || statement === undefined || signature === undefined) {
  console.error("usage: tesser-verify-boxd <bundle> <statement> <signature>");
  process.exit(2);
}
try {
  console.log(verifyBoxd(readFileSync(bundle), readFileSync(statement, "utf8"), readFileSync(signature, "utf8"), RELEASE_PUBLIC_KEY).version);
} catch (err) {
  console.error(`tesser-verify-boxd: refusing ${bundle}: ${err instanceof Error ? err.message : err}`);
  process.exit(1);
}
