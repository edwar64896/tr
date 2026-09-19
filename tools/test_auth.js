/*
 * Tests for deploy/edge-auth.js — the CloudFront Function that gates the site.
 *
 * The function can't be unit-tested in place (it only ever runs at a CloudFront
 * edge), so we load the real source into a vm context that mimics the runtime:
 * cloudfront-js-2.0's crypto module is API-compatible with Node's, and the
 * event/response shapes are documented, so this exercises the actual code.
 *
 *   node tools/test_auth.js
 */
'use strict';
const fs = require('fs');
const vm = require('vm');
const path = require('path');
const nodeCrypto = require('crypto');

const SECRET = 'test-secret-not-the-real-one';
const SRC = fs.readFileSync(path.join(__dirname, '..', 'deploy', 'edge-auth.js'), 'utf8');

// Controllable clock so expiry is testable without waiting two weeks.
const clock = { now: Date.UTC(2026, 0, 1) };
function MockDate(...a) { return new Date(...a); }
MockDate.now = () => clock.now;

const ctx = {
  require: (m) => { if (m === 'crypto') return nodeCrypto; throw new Error('no module ' + m); },
  Date: MockDate, JSON, Math, String, parseInt, decodeURIComponent, console,
};
vm.createContext(ctx);
vm.runInContext(SRC.replace('REPLACE_AT_DEPLOY', SECRET) + '\nthis.__api = { handler, verify, issue };', ctx);
const { handler, verify, issue } = ctx.__api;

const readSrcWrap = (src) => src + '\nthis.__api = { handler, verify, issue };';

let pass = 0, fail = 0;
function ok(name, cond, extra) {
  if (cond) { pass++; console.log('  ok   ' + name); }
  else { fail++; console.log('  FAIL ' + name + (extra ? '  -> ' + JSON.stringify(extra) : '')); }
}
function section(s) { console.log('\n' + s); }

const req = (uri, opts = {}) => ({
  request: {
    uri,
    querystring: opts.query || {},
    cookies: opts.cookie ? { tr_pass: { value: opts.cookie } } : {},
    headers: { host: { value: 'archive.example.net' } },
  },
});
const sign = (p) => nodeCrypto.createHmac('sha256', SECRET).update(p).digest('hex');

// ---------------------------------------------------------------- tokens
section('token issue / verify');
const reader = issue('jane@example.org', '2');
const admin = issue('mark@example.org', '1');
const day = issue('bob@example.org', '3');

ok('type 2 issues a reader pass', verify(reader.token).role === 'p');
ok('type 1 issues an admin pass', verify(admin.token).role === 'a');
ok('subject survives the round trip', verify(reader.token).sub === 'jane@example.org');
ok('type 2 expires in 14 days', reader.exp - Math.floor(clock.now / 1000) === 14 * 86400);
ok('type 3 expires in 24 hours', day.exp - Math.floor(clock.now / 1000) === 86400);
ok('type 1 expires in a year', admin.exp - Math.floor(clock.now / 1000) === 31536000);
ok('unknown type is refused', issue('x@y.z', '9') === null);
ok('separator is stripped from the subject', verify(issue('a~b@y.z', '3').token).sub === 'ab@y.z');

section('forgery');
ok('empty token rejected', verify('') === null);
ok('malformed token rejected', verify('garbage') === null);
ok('tampered signature rejected', verify(reader.token.slice(0, -1) + '0') === null);
{
  const [payload] = reader.token.split('.');
  const bumped = payload.replace('~p~', '~a~');
  ok('privilege escalation rejected', verify(bumped + '.' + sign(payload)) === null);
  ok('re-signing with the wrong key rejected',
    verify(payload + '.' + nodeCrypto.createHmac('sha256', 'wrong').update(payload).digest('hex')) === null);
}
{
  const p = 'eve@example.org~a~' + (Math.floor(clock.now / 1000) + 99) + '~2';
  ok('token from a retired key version rejected', verify(p + '.' + sign(p)) === null);
}

section('expiry');
clock.now += 15 * 86400 * 1000; // jump past the 14-day pass
ok('expired pass is flagged, not forged', verify(reader.token).expired === true);
ok('admin pass still valid a fortnight on', verify(admin.token).role === 'a');
clock.now -= 15 * 86400 * 1000;

// --------------------------------------------------------------- routing
section('routing — unauthenticated');
ok('gate page is reachable', handler(req('/gate.html')).uri === '/gate.html');
ok('site redirects to the gate', handler(req('/')).headers.location.value === '/gate.html');
ok('catalogue is not readable', handler(req('/catalogue.json')).statusCode === 401);
ok('scans are not readable', handler(req('/Z-DDJ-1-51a.jpeg')).statusCode === 302);
ok('admin page is not reachable', handler(req('/admin.html')).statusCode === 302);

section('routing — reader pass');
const asReader = { cookie: reader.token };
ok('site is served', handler(req('/', asReader)).uri === '/');
ok('catalogue is served', handler(req('/catalogue.json', asReader)).uri === '/catalogue.json');
ok('scans are served', handler(req('/Z-DDJ-1-51a.jpeg', asReader)).uri === '/Z-DDJ-1-51a.jpeg');
ok('admin page is refused', handler(req('/admin.html', asReader)).headers.location.value === '/gate.html?e=admin');
ok('minting is refused', handler(req('/mint', asReader)).statusCode === 403);

section('routing — admin pass');
const asAdmin = { cookie: admin.token };
ok('admin page is served', handler(req('/admin.html', asAdmin)).uri === '/admin.html');

section('routing — expired pass');
clock.now += 15 * 86400 * 1000;
ok('expired pass is sent to the gate', handler(req('/', asReader)).headers.location.value === '/gate.html?e=expired');
ok('expired pass gets JSON on data', handler(req('/catalogue.json', asReader)).statusCode === 401);
clock.now -= 15 * 86400 * 1000;

// -------------------------------------------------------------- redeeming
section('redeeming an emailed link');
{
  const r = handler(req('/access', { query: { t: { value: reader.token } } }));
  ok('redeem redirects to the site', r.statusCode === 302 && r.headers.location.value === '/');
  ok('redeem drops the pass cookie', r.cookies.tr_pass.value === reader.token);
  const attrs = r.cookies.tr_pass.attributes;
  ok('cookie is Secure', /Secure/.test(attrs), attrs);
  ok('cookie is HttpOnly', /HttpOnly/.test(attrs), attrs);
  ok('cookie is SameSite=Lax', /SameSite=Lax/.test(attrs), attrs);
  ok('cookie lifetime matches the pass', attrs.indexOf('Max-Age=' + 14 * 86400) > 0, attrs);

  const enc = handler(req('/access', { query: { t: { value: encodeURIComponent(reader.token) } } }));
  ok('a percent-encoded link still works', enc.cookies && enc.cookies.tr_pass.value === reader.token);

  ok('a forged link is refused',
    handler(req('/access', { query: { t: { value: 'nope.deadbeef' } } })).headers.location.value === '/gate.html?e=bad');

  clock.now += 15 * 86400 * 1000;
  ok('an expired link says so',
    handler(req('/access', { query: { t: { value: reader.token } } })).headers.location.value === '/gate.html?e=expired');
  clock.now -= 15 * 86400 * 1000;
}

section('minting through the edge');
{
  const r = handler(req('/mint', { cookie: admin.token, query: { type: { value: '3' }, sub: { value: 'new@example.org' } } }));
  ok('admin can mint', r.statusCode === 200);
  const body = JSON.parse(r.body.data);
  ok('minted token is valid', verify(body.token).sub === 'new@example.org');
  ok('minted day pass is a reader pass', verify(body.token).role === 'p');
  ok('link points at the redeem endpoint', body.link === 'https://archive.example.net/access?t=' + body.token);
  ok('link needs no escaping', body.link === encodeURI(body.link));
  ok('an unknown type is refused',
    handler(req('/mint', { cookie: admin.token, query: { type: { value: '7' } } })).statusCode === 400);
  ok('minting without a pass is refused', handler(req('/mint', { query: { type: { value: '3' } } })).statusCode === 403);
}

// ------------------------------------------- shell <-> edge interoperability
/* deploy/mint-token.sh signs with openssl; the edge verifies with the crypto
   module. If those two ever disagree about HMAC, bootstrapping silently breaks
   and nobody can get in — so mint a real token through the real script (with a
   stub `aws` standing in for Parameter Store) and verify it here. */
section('deploy/mint-token.sh interoperates with the edge');
{
  const { execFileSync } = require('child_process');
  const os = require('os');
  const bin = fs.mkdtempSync(path.join(os.tmpdir(), 'awsstub-'));
  fs.writeFileSync(path.join(bin, 'aws'), '#!/bin/sh\necho "' + SECRET + '"\n', { mode: 0o755 });

  const run = (args) => execFileSync(
    path.join(__dirname, '..', 'deploy', 'mint-token.sh'), args,
    { encoding: 'utf8', env: Object.assign({}, process.env, { PATH: bin + ':' + process.env.PATH }) }
  );
  const tokenFrom = (out) => (out.match(/\/access\?t=(\S+)/) || [])[1];

  for (const [type, role, label] of [['1','a','admin'], ['2','p','two-week'], ['3','p','day']]) {
    const t = tokenFrom(run(['--type', type, '--for', 'shell@example.org']));
    const c = t && verify(t);
    ok('shell-minted ' + label + ' pass verifies at the edge', !!c && !c.expired && c.role === role, t);
  }

  const t = tokenFrom(run(['--type', '2', '--for', 'a~b@example.org']));
  ok('shell strips the separator like the edge does', verify(t).sub === 'ab@example.org');

  let refused = false;
  try { run(['--type', '9', '--for', 'x@y.z']); } catch (e) { refused = true; }
  ok('shell refuses an unknown type', refused);
}

// -------------------------------------------- the console install path
/* deploy/INSTALL-AUTH.md has the client generate a key with
   `node tools/mint.js --new-key`, paste deploy/edge-auth.ready.js into the
   CloudFront console, and mint their first administrator pass with the same
   key. Nothing in that path touches AWS or the shell scripts, so run it here
   for real: generate, load the *generated* file as the edge, and mint against
   it. If these drifted, the client would paste in a working gate and then be
   unable to get through it. */
section('the console install path (tools/mint.js)');
{
  const { execFileSync } = require('child_process');
  const mint = path.join(__dirname, 'mint.js');
  const ready = path.join(__dirname, '..', 'deploy', 'edge-auth.ready.js');
  const hadReady = fs.existsSync(ready);
  const backup = hadReady ? fs.readFileSync(ready) : null;

  const gen = execFileSync('node', [mint, '--new-key'], { encoding: 'utf8' });
  const key = (gen.match(/^\s*([0-9a-f]{64})\s*$/m) || [])[1];
  ok('--new-key generates a key', !!key);
  ok('--new-key writes the ready-to-paste function', fs.existsSync(ready));

  const readySrc = fs.readFileSync(ready, 'utf8');
  ok('the key is substituted in', readySrc.includes(key) && !readySrc.includes('REPLACE_AT_DEPLOY'));
  ok('it still fits a CloudFront Function', Buffer.byteLength(readySrc) <= 10240);

  // Load the generated file as the edge would.
  const c2 = {
    require: (m) => { if (m === 'crypto') return nodeCrypto; throw new Error('no module ' + m); },
    Date: MockDate, JSON, Math, String, parseInt, decodeURIComponent, console,
  };
  vm.createContext(c2);
  vm.runInContext(readSrcWrap(readySrc), c2);
  const edge = c2.__api;

  const out = execFileSync('node', [mint, '--key', key, '--type', '1', '--for', 'client@example.org', '--host', 'archive.example.net'], { encoding: 'utf8' });
  const token = (out.match(/\/access\?t=(\S+)/) || [])[1];
  ok('mints a link against that key', !!token);

  const c = token && edge.verify(token);
  ok('the pasted function accepts it', !!c && !c.expired && c.role === 'a');
  ok('and lets it reach the admin page',
    edge.handler({ request: { uri: '/admin.html', querystring: {}, cookies: { tr_pass: { value: token } }, headers: {} } }).uri === '/admin.html');
  ok('a stranger is still turned away',
    edge.handler({ request: { uri: '/', querystring: {}, cookies: {}, headers: {} } }).statusCode === 302);

  // A key from a different install must not open this one.
  const otherGen = execFileSync('node', [mint, '--key', 'a-different-key', '--type', '1', '--for', 'eve@example.org'], { encoding: 'utf8' });
  ok('a pass signed with another key is refused',
    edge.verify((otherGen.match(/\/access\?t=(\S+)/) || [])[1]) === null);

  let refused = false;
  try { execFileSync('node', [mint, '--type', '1', '--for', 'x@y.z'], { encoding: 'utf8', stdio: 'pipe' }); }
  catch (e) { refused = true; }
  ok('minting without a key is refused', refused);

  if (hadReady) fs.writeFileSync(ready, backup); else fs.unlinkSync(ready);
}

// ------------------------------------- the console's own test-event shape
/* The CloudFront console validates a pasted test event against the full cookie
   schema, so deploy/INSTALL-AUTH.md tells the operator to include
   "attributes" — a field that only means anything on a response cookie. Make
   sure carrying it never changes the verdict, or the runbook would be handing
   people an event that tests something other than what production does. */
section("console test events (INSTALL-AUTH.md step 4)");
{
  const ev = (cookies) => ({ request: {
    method: 'GET', uri: '/', querystring: {},
    headers: { host: { value: 'archive.example.net' } }, cookies } });

  const tok = issue('mark@example.org', '1').token;
  ok('stranger event returns a response, not a request',
    handler(ev({})).statusCode === 302);
  ok('pass with attributes:"" is let through',
    handler(ev({ tr_pass: { value: tok, attributes: '' } })).uri === '/');
  ok('pass with a populated attributes string is let through',
    handler(ev({ tr_pass: { value: tok, attributes: 'Path=/; Secure; HttpOnly' } })).uri === '/');
  ok('pass with no attributes field at all is let through',
    handler(ev({ tr_pass: { value: tok } })).uri === '/');
  ok('attributes cannot smuggle in a valid pass',
    handler(ev({ tr_pass: { value: 'forged', attributes: tok } })).statusCode === 302);
}

// ------------------------------------ the no-install path (tools/mint.html)
/* The client operates this from a browser and may not have Node at all, so
   tools/mint.html mints with the browser's own Web Crypto. It is the recovery
   path used exactly when things have gone wrong, so it must agree with the
   edge to the byte — run its real script here (Node 22 has the same Web Crypto)
   and check the edge accepts what it makes. */
section('tools/mint.html — minting with no install');
{
  const html = fs.readFileSync(path.join(__dirname, 'mint.html'), 'utf8');

  ok('the page makes no network requests', !/\bfetch\s*\(|XMLHttpRequest|sendBeacon|WebSocket|src=["']https?:/.test(html));
  ok('nothing is loaded from a CDN', !/<(script|link)[^>]+(src|href)=["']https?:/i.test(html));

  const script = html.match(/<script>([\s\S]*?)<\/script>/)[1];
  const c3 = { crypto: globalThis.crypto, TextEncoder, Date: MockDate, Math, String, Array, Uint8Array, Error, console };
  vm.createContext(c3);
  vm.runInContext(script + '\nthis.mint = mintToken;', c3);

  return c3.mint(SECRET, 'client@example.org', '1').then(async (admin) => {
    const c = verify(admin.token);
    ok('an admin pass it mints is valid at the edge', !!c && !c.expired && c.role === 'a');
    ok('and opens the admin page',
      handler(req('/admin.html', { cookie: admin.token })).uri === '/admin.html');

    for (const [type, role] of [['2', 'p'], ['3', 'p']]) {
      const r = await c3.mint(SECRET, 'reader@example.org', type);
      ok('a type ' + type + ' pass carries role ' + role, verify(r.token).role === role);
    }

    const wrong = await c3.mint('not-the-signing-key', 'eve@example.org', '1');
    ok('a pass minted with the wrong key is refused', verify(wrong.token) === null);

    const sneaky = await c3.mint(SECRET, 'a~b@example.org', '3');
    ok('it strips the separator like the edge does', verify(sneaky.token).sub === 'ab@example.org');

    let bad = false;
    try { await c3.mint(SECRET, 'x@y.z', '9'); } catch (e) { bad = true; }
    ok('an unknown type is refused', bad);

    finish();
  });
}

function finish() {
console.log('\n' + pass + ' passed, ' + fail + ' failed');
process.exit(fail ? 1 : 0);
}
