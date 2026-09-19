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

console.log('\n' + pass + ' passed, ' + fail + ' failed');
process.exit(fail ? 1 : 0);
