#!/usr/bin/env node
/*
 * Prepare the gate, and mint passes, without an AWS account.
 *
 *   node tools/mint.js --new-key
 *       Generates a signing key and writes deploy/edge-auth.ready.js — the
 *       function with the key already in it, ready to paste into the
 *       CloudFront console. See deploy/INSTALL-AUTH.md.
 *
 *   node tools/mint.js --key <key> --type 1 --for someone@example.org
 *       Mints a pass and prints the link to email.
 *
 * deploy/mint-token.sh does the same job for anyone with the AWS CLI, reading
 * the key from SSM. This one takes the key directly, so it works on any machine
 * with Node and nothing else — which is what the console install needs, because
 * /admin.html sits behind the gate and can't issue the first administrator
 * pass.
 *
 * Day to day nobody should need this: administrators mint from /admin.html.
 * Keep the key in a password manager; it is the one secret behind every pass.
 */
'use strict';
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const TYPES = {
  '1': { role: 'a', ttl: 31536000, label: 'administrator pass (1 year)' },
  '2': { role: 'p', ttl: 1209600,  label: 'reader pass (14 days)' },
  '3': { role: 'p', ttl: 86400,    label: 'reader pass (24 hours)' },
};

const args = {};
for (let i = 2; i < process.argv.length; i++) {
  const a = process.argv[i];
  if (a.startsWith('--')) {
    const k = a.slice(2);
    const next = process.argv[i + 1];
    if (next && !next.startsWith('--')) { args[k] = next; i++; } else { args[k] = true; }
  }
}

const ROOT = path.join(__dirname, '..');
const SRC = path.join(ROOT, 'deploy', 'edge-auth.js');
const READY = path.join(ROOT, 'deploy', 'edge-auth.ready.js');
const KID = String(args.kid || '1');

function die(msg) { console.error('\n  ' + msg + '\n'); process.exit(1); }

// ------------------------------------------------------------- --new-key
if (args['new-key']) {
  const key = crypto.randomBytes(32).toString('hex');
  const src = fs.readFileSync(SRC, 'utf8');
  if (!src.includes('REPLACE_AT_DEPLOY')) die('deploy/edge-auth.js already has a key in it. Restore the placeholder first.');
  fs.writeFileSync(READY, src.replace('REPLACE_AT_DEPLOY', key), { mode: 0o600 });

  const size = Buffer.byteLength(fs.readFileSync(READY));
  console.log(`
  Signing key
  -----------
  ${key}

  Put that in a password manager now. It is the only secret behind every
  pass, it is not stored anywhere else, and you need it again to issue the
  first administrator pass (below) or to rotate.

  Function code
  -------------
  Written to deploy/edge-auth.ready.js  (${size} bytes; CloudFront allows 10240)

  That file has the key in it, so it is git-ignored — don't commit or email
  it. Paste its contents into the CloudFront console following
  deploy/INSTALL-AUTH.md, then delete it.

  Once the function is published and attached, come back for your own pass:

    node tools/mint.js --key ${key} \\
      --type 1 --for you@example.org
`);
  process.exit(0);
}

// ---------------------------------------------------------------- minting
const key = args.key;
const type = args.type && String(args.type);
const who = args['for'] || args.sub;

if (!key || typeof key !== 'string') die('Need --key <signing key>.  (Or --new-key to generate one.)');
if (!TYPES[type]) die('Need --type 1 (administrator), 2 (two weeks) or 3 (one day).');
if (!who || typeof who !== 'string') die('Need --for <who the pass is for>.');

// Same sanitising as the edge function, so a name can't smuggle in the field
// separator and forge itself a different role.
const sub = who.replace(/[^A-Za-z0-9@._+-]/g, '').slice(0, 64);
if (!sub) die('That name has no usable characters in it.');

const host = args.host || 'dmfmj7c4s21wr.cloudfront.net';
const t = TYPES[type];
const exp = Math.floor(Date.now() / 1000) + t.ttl;
const payload = `${sub}~${t.role}~${exp}~${KID}`;
const token = payload + '.' + crypto.createHmac('sha256', key).update(payload).digest('hex');

console.log(`
  ${t.label} for ${sub}
  valid until ${new Date(exp * 1000).toLocaleDateString('en-GB', { day: 'numeric', month: 'long', year: 'numeric' })}

  https://${host}/access?t=${token}
`);
