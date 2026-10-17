// ==============================================================================
// Freestone County ARES Tactical Operations - Apple APNs Push Relay Worker
// Cloudflare Worker (100% Free Tier, Zero Dependencies)
// ==============================================================================

const APNS_KEY_ID = '9YDR576U3N';
const APNS_TEAM_ID = 'LSMMV8JFAJ';
const APNS_TOPIC = 'org.freestone.ares.tactical';
const FIREBASE_DB_URL = 'https://freestone-ares-tactical-default-rtdb.firebaseio.com';

const APNS_KEY_PEM = `-----BEGIN PRIVATE KEY-----
MIGTAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBHkwdwIBAQQgGKRW7BVEDriKufTy
Tr0CZZW4J4Xxsoe7A0AXC4sL2MGgCgYIKoZIzj0DAQehRANCAASn23KF4g8A4joq
UmrPw3Od7jQ1giIhu8KqpVDtF1N57UbHOb5saeHu+oXlDPUrLeBDyuPAccYNGUZu
Hhf8Gxtt
-----END PRIVATE KEY-----`;

function base64UrlEncode(buffer) {
  let binary = '';
  const bytes = new Uint8Array(buffer);
  for (let i = 0; i < bytes.byteLength; i++) {
    binary += String.fromCharCode(bytes[i]);
  }
  return btoa(binary)
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/, '');
}

function pemToBinary(pem) {
  const base64 = pem
    .replace(/-----BEGIN [A-Z ]+-----/g, '')
    .replace(/-----END [A-Z ]+-----/g, '')
    .replace(/\s+/g, '');
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes.buffer;
}

let cachedJwt = null;
let cachedJwtExpiry = 0;

async function getApnsJwt() {
  const now = Math.floor(Date.now() / 1000);
  if (cachedJwt && now < cachedJwtExpiry - 120) {
    return cachedJwt;
  }

  const der = pemToBinary(APNS_KEY_PEM);
  const cryptoKey = await crypto.subtle.importKey(
    'pkcs8',
    der,
    { name: 'ECDSA', namedCurve: 'P-256' },
    false,
    ['sign']
  );

  const header = {
    alg: 'ES256',
    kid: APNS_KEY_ID
  };
  const payload = {
    iss: APNS_TEAM_ID,
    iat: now
  };

  const headerB64 = base64UrlEncode(new TextEncoder().encode(JSON.stringify(header)));
  const payloadB64 = base64UrlEncode(new TextEncoder().encode(JSON.stringify(payload)));
  const signingInput = new TextEncoder().encode(`${headerB64}.${payloadB64}`);

  const signature = await crypto.subtle.sign(
    { name: 'ECDSA', hash: 'SHA-256' },
    cryptoKey,
    signingInput
  );

  const signatureB64 = base64UrlEncode(signature);
  cachedJwt = `${headerB64}.${payloadB64}.${signatureB64}`;
  cachedJwtExpiry = now + 3500; // Apple JWT tokens are valid up to 1 hour (3600 seconds)
  return cachedJwt;
}

export default {
  async fetch(request, env) {
    const corsHeaders = {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
      'Access-Control-Allow-Headers': 'Content-Type, Authorization'
    };

    if (request.method === 'OPTIONS') {
      return new Response(null, { headers: corsHeaders });
    }

    if (request.method === 'GET') {
      return new Response(JSON.stringify({
        status: 'online',
        service: 'Freestone County ARES APNs Push Relay',
        team: APNS_TEAM_ID,
        topic: APNS_TOPIC
      }), {
        headers: { 'Content-Type': 'application/json', ...corsHeaders }
      });
    }

    if (request.method === 'POST') {
      try {
        const body = await request.json();
        const title = body.title || '🚨 FREESTONE ARES EMERGENCY DISPATCH';
        const message = body.body || body.message || 'Urgent incident callout transmitted.';
        const sound = body.sound || 'siren.caf';
        const badge = (body.badge !== undefined && body.badge !== null) ? Number(body.badge) : 1;

        // 1. Fetch registered device tokens from Firebase RTDB
        const fbRes = await fetch(`${FIREBASE_DB_URL}/device_tokens.json`);
        const tokenMap = await fbRes.json();
        if (!tokenMap || typeof tokenMap !== 'object') {
          return new Response(JSON.stringify({ success: true, count: 0, message: 'No registered device tokens found in Firebase' }), {
            headers: { 'Content-Type': 'application/json', ...corsHeaders }
          });
        }

        const tokens = Object.keys(tokenMap);
        if (tokens.length === 0) {
          return new Response(JSON.stringify({ success: true, count: 0, message: 'Device token list is empty' }), {
            headers: { 'Content-Type': 'application/json', ...corsHeaders }
          });
        }

        // 2. Generate signed APNs JWT
        const jwt = await getApnsJwt();

        // 3. Construct APNs High-Priority Alert Payload
        const aps = {
          alert: {
            title: title,
            body: message
          },
          sound: sound,
          badge: badge
        };

        if (body.interruptionLevel) {
          aps['interruption-level'] = body.interruptionLevel;
        }

        const apnsPayload = JSON.stringify({ aps });

        // 4. Send APNs Push to all devices simultaneously
        const deliveryPromises = tokens.map(async (token) => {
          try {
            const apnsRes = await fetch(`https://api.push.apple.com/3/device/${token}`, {
              method: 'POST',
              headers: {
                'authorization': `bearer ${jwt}`,
                'apns-topic': APNS_TOPIC,
                'apns-push-type': 'alert',
                'apns-priority': '10',
                'apns-expiration': '0'
              },
              body: apnsPayload
            });
            const text = await apnsRes.text();
            return {
              token: token.substring(0, 10) + '...',
              status: apnsRes.status,
              apnsId: apnsRes.headers.get('apns-id'),
              response: text || 'OK'
            };
          } catch (err) {
            return {
              token: token.substring(0, 10) + '...',
              status: 500,
              error: err.message
            };
          }
        });

        const results = await Promise.all(deliveryPromises);

        return new Response(JSON.stringify({
          success: true,
          devicesNotified: results.length,
          title: title,
          results: results
        }), {
          headers: { 'Content-Type': 'application/json', ...corsHeaders }
        });

      } catch (err) {
        return new Response(JSON.stringify({
          success: false,
          error: err.message
        }), {
          status: 500,
          headers: { 'Content-Type': 'application/json', ...corsHeaders }
        });
      }
    }

    return new Response('Method Not Allowed', { status: 405, headers: corsHeaders });
  }
};
