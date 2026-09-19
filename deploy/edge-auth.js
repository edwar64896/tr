/*
 * CloudFront Function (viewer-request) — access control for the archive.
 *
 * The site is static: S3 behind CloudFront, no backend. A gate written in
 * index.html would be decoration, because catalogue.json and every scan are
 * plain URLs. So the check runs here, at the edge, in front of S3 — it sees
 * every request, including cache hits.
 *
 * Attach to the DEFAULT cache behaviour as a viewer-request function
 * (deploy/publish-auth.sh does this). Runtime: cloudfront-js-2.0, which is
 * what provides the crypto module.
 *
 * Token: "<sub>~<role>~<exp>~<kid>.<hmac-sha256-hex>"
 *   sub  recipient (email or label), for the audit trail only
 *   role "a" administrator | "p" reader
 *   exp  expiry, epoch seconds — the token carries its own lifetime, so
 *        nothing is stored anywhere and there is no database to keep
 *   kid  key version; bump KID below to invalidate every issued token at once
 * Deliberately no base64 — parsing is split() and the signature is hex, which
 * keeps us well inside the 1 ms budget a CloudFront Function gets.
 */
var crypto = require('crypto');

// Substituted at deploy time from SSM (/trarchive/auth-secret). Never committed.
var SECRET = 'REPLACE_AT_DEPLOY';
var KID = '1';

var COOKIE = 'tr_pass';

// Pass types. 1 = administrator, 2 = two-week pass, 3 = day pass.
var TYPES = {
  '1': { role: 'a', ttl: 31536000 },  // 1 year — long, but still rotatable
  '2': { role: 'p', ttl: 1209600  },  // 14 days
  '3': { role: 'p', ttl: 86400    }   // 24 hours
};

/* Compare without leaking position through timing. */
function eq(a, b) {
  if (a.length !== b.length) return false;
  var d = 0;
  for (var i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

function sign(payload) {
  return crypto.createHmac('sha256', SECRET).update(payload).digest('hex');
}

/* null = absent or forged. {expired:true} = genuine but out of date, which is
   worth telling the visitor apart from "you were never let in". */
function verify(tok) {
  if (!tok) return null;
  var i = tok.lastIndexOf('.');
  if (i < 1) return null;
  var payload = tok.substring(0, i);
  if (!eq(tok.substring(i + 1), sign(payload))) return null;

  var f = payload.split('~');
  if (f.length !== 4 || f[3] !== KID) return null;
  var exp = parseInt(f[2], 10);
  if (!exp) return null;
  if (exp * 1000 < Date.now()) return { expired: true };
  return { sub: f[0], role: f[1], exp: exp };
}

function issue(sub, type) {
  var t = TYPES[type];
  if (!t) return null;
  sub = String(sub).replace(/[^A-Za-z0-9@._+-]/g, '').substring(0, 64) || 'guest';
  var exp = Math.floor(Date.now() / 1000) + t.ttl;
  var payload = sub + '~' + t.role + '~' + exp + '~' + KID;
  return { token: payload + '.' + sign(payload), exp: exp };
}

function qs(req, name) {
  var v = req.querystring[name];
  return v ? v.value : '';
}

function json(status, obj) {
  return {
    statusCode: status,
    statusDescription: status === 200 ? 'OK' : 'Error',
    headers: {
      'content-type': { value: 'application/json' },
      'cache-control': { value: 'no-store' }
    },
    body: { encoding: 'text', data: JSON.stringify(obj) }
  };
}

function toGate(why) {
  return {
    statusCode: 302,
    statusDescription: 'Found',
    headers: {
      'location': { value: '/gate.html' + (why ? '?e=' + why : '') },
      'cache-control': { value: 'no-store' }
    }
  };
}

/* An expired pass mid-session would otherwise redirect a fetch() to HTML and
   surface as a JSON parse error. Answer data requests in their own language. */
function deny(uri, why) {
  if (/\.json$/.test(uri)) return json(401, { error: why || 'no_pass' });
  return toGate(why);
}

/* GET /access?t=... — redeem an emailed link: verify, drop the cookie, go in. */
function redeem(req) {
  var tok = qs(req, 't');
  if (tok.indexOf('%') >= 0) { try { tok = decodeURIComponent(tok); } catch (e) {} }
  var c = verify(tok);
  if (!c || c.expired) return toGate(c ? 'expired' : 'bad');

  var maxAge = c.exp - Math.floor(Date.now() / 1000);
  return {
    statusCode: 302,
    statusDescription: 'Found',
    headers: { 'location': { value: '/' }, 'cache-control': { value: 'no-store' } },
    cookies: {
      tr_pass: {
        value: tok,
        attributes: 'Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age=' + maxAge
      }
    }
  };
}

/* GET /mint?type=N&sub=... — administrators only. The secret stays at the
   edge; admin.html never sees it, it just asks for a link to email. */
function mint(req, claims) {
  if (!claims || claims.expired || claims.role !== 'a') return json(403, { error: 'admin_only' });
  var out = issue(qs(req, 'sub'), qs(req, 'type'));
  if (!out) return json(400, { error: 'bad_type' });

  var host = req.headers.host ? req.headers.host.value : '';
  return json(200, {
    token: out.token,
    link: 'https://' + host + '/access?t=' + out.token,
    expires: new Date(out.exp * 1000).toISOString()
  });
}

function handler(event) {
  var req = event.request;
  var uri = req.uri;

  // Open to everyone, or nobody could ever get in.
  if (uri === '/access') return redeem(req);
  if (uri === '/gate.html' || uri === '/favicon.ico') return req;

  var claims = verify(req.cookies[COOKIE] ? req.cookies[COOKIE].value : '');

  if (uri === '/mint') return mint(req, claims);
  if (!claims) return deny(uri, '');
  if (claims.expired) return deny(uri, 'expired');
  if (uri === '/admin.html' && claims.role !== 'a') return deny(uri, 'admin');

  return req;
}
