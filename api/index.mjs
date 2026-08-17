/*
  Lift Log sync API.

  Two endpoints behind a Lambda function URL:

    GET  /sync?since=<ISO>   ->  { items, serverTime }
    POST /sync {items:[...]} ->  { serverTime, written }

  The security model in one sentence: the caller's user id comes from the
  cryptographically verified JWT, never from the request body, so a client
  cannot ask for — or write to — another user's data.

  No npm dependencies. JWT verification uses node:crypto, and the AWS SDK v3
  clients used here ship with the nodejs20.x runtime. That means Terraform can
  zip this directory directly with no build step.
*/

import { createPublicKey, verify as cryptoVerify } from "node:crypto";
import { DynamoDBClient, QueryCommand, BatchWriteItemCommand } from "@aws-sdk/client-dynamodb";
import { marshall, unmarshall } from "@aws-sdk/util-dynamodb";

const TABLE = process.env.TABLE_NAME;
const ISSUER = process.env.COGNITO_ISSUER;
const CLIENT_ID = process.env.COGNITO_CLIENT_ID;

const ddb = new DynamoDBClient({});

/* Sort keys the client is allowed to write. Anything else is rejected — this
   stops a caller inventing item types we don't expect.

   Split into exact matches and prefixes deliberately. The previous check was
   `sk === p || sk.startsWith(p)` against a single list, which meant "PROFILE"
   — the one entry with no trailing "#" — also admitted PROFILE_anything and
   PROFILEX. A prefix without a delimiter is not a namespace. */
const ALLOWED_SK_EXACT = ["PROFILE"];

const ALLOWED_SK_PREFIXES = [
  "WORKOUT#",
  "ROUTINE#",
  "FOLDER#",
  "EXERCISE#",
  "BODY#",
];

function isAllowedSk(sk) {
  if (ALLOWED_SK_EXACT.includes(sk)) return true;
  /* Require something after the delimiter: "WORKOUT#" alone is not an item. */
  return ALLOWED_SK_PREFIXES.some((p) => sk.startsWith(p) && sk.length > p.length);
}

const MAX_ITEMS_PER_REQUEST = 500;
const BATCH_SIZE = 25; // DynamoDB BatchWriteItem hard limit

class HttpError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

/* ------------------------------------------------------------------ *
 * JWT verification
 * ------------------------------------------------------------------ */

let jwksCache = null;
let jwksFetchedAt = 0;
let jwksRefreshedAt = 0;
const JWKS_TTL_MS = 60 * 60 * 1000;

/* Cognito rotates signing keys. Between a rotation and this cache expiring,
   perfectly valid tokens carry a `kid` we haven't seen, so a cache miss must
   be able to trigger a refetch — otherwise sign-in fails for up to an hour
   and then fixes itself, which is a miserable thing to debug.

   The floor is what stops that being a denial-of-service vector: without it,
   anyone can force a JWKS fetch per request just by sending a garbage `kid`.
   One forced refetch per minute is plenty for a real rotation and useless as
   an amplifier. */
const JWKS_REFRESH_FLOOR_MS = 60 * 1000;

async function fetchJwks() {
  const res = await fetch(`${ISSUER}/.well-known/jwks.json`);
  if (!res.ok) throw new HttpError(500, "could not fetch signing keys");
  const body = await res.json();
  if (!Array.isArray(body.keys)) throw new HttpError(500, "malformed jwks");
  jwksCache = body.keys;
  jwksFetchedAt = Date.now();
  return jwksCache;
}

async function getJwks() {
  if (jwksCache && Date.now() - jwksFetchedAt < JWKS_TTL_MS) return jwksCache;
  return fetchJwks();
}

/* Returns null rather than throwing, so the caller decides the status code. */
async function findSigningKey(kid) {
  const keys = await getJwks();
  const hit = keys.find((k) => k.kid === kid);
  if (hit) return hit;

  if (Date.now() - jwksRefreshedAt < JWKS_REFRESH_FLOOR_MS) return null;
  jwksRefreshedAt = Date.now();

  const refreshed = await fetchJwks();
  return refreshed.find((k) => k.kid === kid) ?? null;
}

function b64url(segment) {
  return Buffer.from(segment.replace(/-/g, "+").replace(/_/g, "/"), "base64");
}

async function verifyToken(token) {
  const parts = token.split(".");
  if (parts.length !== 3) throw new HttpError(401, "malformed token");
  const [headerB64, payloadB64, signatureB64] = parts;

  let header, payload;
  try {
    header = JSON.parse(b64url(headerB64).toString("utf8"));
    payload = JSON.parse(b64url(payloadB64).toString("utf8"));
  } catch {
    throw new HttpError(401, "malformed token");
  }

  /* Allowlist the algorithm rather than trusting header.alg. Accepting
     whatever the token claims is the classic JWT vulnerability: "none"
     skips verification entirely, and an HMAC alg lets an attacker sign
     with the public key as the shared secret. */
  if (header.alg !== "RS256") throw new HttpError(401, "unsupported algorithm");
  if (!header.kid) throw new HttpError(401, "missing key id");

  const jwk = await findSigningKey(header.kid);
  if (!jwk) throw new HttpError(401, "unknown signing key");

  /* The JWKS is fetched over TLS from our own issuer, so a non-RSA key here
     would be surprising. Assert it anyway: createPublicKey happily builds an
     EC key from an EC JWK, and passing one to an RSA-SHA256 verify is a
     confusing failure rather than a clean rejection. */
  if (jwk.kty !== "RSA") throw new HttpError(401, "unsupported key type");

  const signatureValid = cryptoVerify(
    "RSA-SHA256",
    Buffer.from(`${headerB64}.${payloadB64}`),
    createPublicKey({ key: jwk, format: "jwk" }),
    b64url(signatureB64)
  );
  if (!signatureValid) throw new HttpError(401, "invalid signature");

  /* A valid signature only proves the token wasn't tampered with. These
     claim checks prove it was issued by OUR pool, for OUR client, is an
     access token rather than an id token, and hasn't expired. */
  const now = Math.floor(Date.now() / 1000);
  if (typeof payload.exp !== "number" || payload.exp <= now) throw new HttpError(401, "token expired");
  if (payload.nbf && payload.nbf > now) throw new HttpError(401, "token not yet valid");
  if (payload.iss !== ISSUER) throw new HttpError(401, "wrong issuer");
  if (payload.token_use !== "access") throw new HttpError(401, "expected an access token");
  if (payload.client_id !== CLIENT_ID) throw new HttpError(401, "wrong client");
  if (!payload.sub) throw new HttpError(401, "token has no subject");

  return payload;
}

function bearerToken(headers) {
  const raw = headers?.authorization || headers?.Authorization || "";
  const match = /^Bearer\s+(.+)$/i.exec(raw.trim());
  if (!match) throw new HttpError(401, "missing bearer token");
  return match[1];
}

/* ------------------------------------------------------------------ *
 * Handlers
 * ------------------------------------------------------------------ */

async function handleGet(sub, query) {
  const since = query?.since;
  if (since && Number.isNaN(Date.parse(since))) {
    throw new HttpError(400, "since must be an ISO 8601 timestamp");
  }

  const items = [];
  let lastKey;

  do {
    const res = await ddb.send(
      new QueryCommand({
        TableName: TABLE,
        KeyConditionExpression: "PK = :pk",
        /* Filtering server-side saves bandwidth but not read cost —
           DynamoDB bills for items scanned, not returned. At one user's
           volume that's irrelevant; at scale this becomes a GSI on
           updatedAt. */
        ...(since
          ? {
              FilterExpression: "updatedAt > :since",
              ExpressionAttributeValues: marshall({ ":pk": `USER#${sub}`, ":since": since }),
            }
          : {
              ExpressionAttributeValues: marshall({ ":pk": `USER#${sub}` }),
            }),
        ExclusiveStartKey: lastKey,
      })
    );
    for (const raw of res.Items ?? []) {
      const item = unmarshall(raw);
      items.push({
        sk: item.SK,
        type: item.type,
        updatedAt: item.updatedAt,
        deleted: item.deleted === true,
        data: item.data,
      });
    }
    lastKey = res.LastEvaluatedKey;
  } while (lastKey);

  return { items, serverTime: new Date().toISOString() };
}

async function handlePost(sub, body) {
  let parsed;
  try {
    parsed = JSON.parse(body || "{}");
  } catch {
    throw new HttpError(400, "body must be JSON");
  }

  const incoming = parsed.items;
  if (!Array.isArray(incoming)) throw new HttpError(400, "items must be an array");
  if (incoming.length === 0) return { serverTime: new Date().toISOString(), written: 0 };
  if (incoming.length > MAX_ITEMS_PER_REQUEST) {
    throw new HttpError(413, `too many items, max ${MAX_ITEMS_PER_REQUEST} per request`);
  }

  const rows = incoming.map((item, i) => {
    if (!item || typeof item !== "object") throw new HttpError(400, `item ${i} is not an object`);
    const { sk, type, updatedAt, deleted, data } = item;

    if (typeof sk !== "string" || sk.length === 0 || sk.length > 512) {
      throw new HttpError(400, `item ${i}: sk must be a non-empty string`);
    }
    if (!isAllowedSk(sk)) {
      throw new HttpError(400, `item ${i}: sk "${sk}" is not an allowed type`);
    }
    if (typeof updatedAt !== "string" || Number.isNaN(Date.parse(updatedAt))) {
      throw new HttpError(400, `item ${i}: updatedAt must be an ISO 8601 timestamp`);
    }

    return {
      PutRequest: {
        Item: marshall(
          {
            /* PK comes from the verified token. Even if the client sends a
               PK field, it is ignored — this single line is what makes
               cross-user access impossible. */
            PK: `USER#${sub}`,
            SK: sk,
            type: typeof type === "string" ? type : "unknown",
            updatedAt,
            deleted: deleted === true,
            data: data ?? {},
          },
          { removeUndefinedValues: true }
        ),
      },
    };
  });

  let written = 0;
  for (let i = 0; i < rows.length; i += BATCH_SIZE) {
    const chunk = rows.slice(i, i + BATCH_SIZE);
    let request = { [TABLE]: chunk };

    /* BatchWriteItem can partially succeed under throttling and hands back
       UnprocessedItems. Retrying with backoff is required for correctness,
       not politeness. */
    for (let attempt = 0; attempt < 5; attempt++) {
      const res = await ddb.send(new BatchWriteItemCommand({ RequestItems: request }));
      const unprocessed = res.UnprocessedItems?.[TABLE];
      if (!unprocessed || unprocessed.length === 0) {
        request = null;
        break;
      }
      request = { [TABLE]: unprocessed };
      await new Promise((r) => setTimeout(r, 50 * 2 ** attempt));
    }
    if (request) throw new HttpError(503, "write throttled, retry shortly");
    written += chunk.length;
  }

  return { serverTime: new Date().toISOString(), written };
}

/* ------------------------------------------------------------------ *
 * Entry point
 * ------------------------------------------------------------------ */

export async function handler(event) {
  const method = event?.requestContext?.http?.method ?? "GET";
  const path = event?.requestContext?.http?.path ?? "/";

  const respond = (status, payload) => ({
    statusCode: status,
    headers: { "content-type": "application/json" },
    body: JSON.stringify(payload),
  });

  /* The function URL's CORS config answers preflight before we're invoked,
     but returning cleanly here avoids a 404 if that ever changes. */
  if (method === "OPTIONS") return { statusCode: 204 };

  try {
    if (!TABLE || !ISSUER || !CLIENT_ID) {
      throw new HttpError(500, "function is misconfigured");
    }

    const claims = await verifyToken(bearerToken(event.headers));
    const sub = claims.sub;

    if (path !== "/sync" && path !== "/") {
      throw new HttpError(404, "not found");
    }

    if (method === "GET") {
      return respond(200, await handleGet(sub, event.queryStringParameters));
    }
    if (method === "POST") {
      const body = event.isBase64Encoded
        ? Buffer.from(event.body ?? "", "base64").toString("utf8")
        : event.body;
      return respond(200, await handlePost(sub, body));
    }

    throw new HttpError(405, "method not allowed");
  } catch (err) {
    if (err instanceof HttpError) {
      /* 4xx are the client's problem and safe to echo. 5xx get logged with
         detail but return something generic — internal errors leak
         implementation detail to anyone probing the endpoint. */
      if (err.status >= 500) console.error("server error:", err);
      return respond(err.status, {
        error: err.status >= 500 ? "internal error" : err.message,
      });
    }
    console.error("unhandled error:", err);
    return respond(500, { error: "internal error" });
  }
}
