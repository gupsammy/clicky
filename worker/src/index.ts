/**
 * Clicky Proxy Worker
 *
 * Proxies requests to Claude (via Google Vertex AI) and ElevenLabs APIs so the
 * app never ships with raw API keys. Credentials are stored as Cloudflare secrets.
 *
 * Routes:
 *   POST /chat              → Vertex AI Claude (streaming)
 *   POST /tts               → ElevenLabs TTS API
 *   POST /transcribe-token  → AssemblyAI temp token (legacy, unused with Apple Speech)
 */

interface Env {
  GCP_SERVICE_ACCOUNT_KEY: string;
  VERTEX_PROJECT_ID: string;
  VERTEX_REGION: string;
  ELEVENLABS_API_KEY: string;
  ELEVENLABS_VOICE_ID: string;
  ASSEMBLYAI_API_KEY: string;
}

interface ServiceAccountKey {
  client_email: string;
  private_key: string;
  token_uri: string;
}

// Module-scope cache for the Vertex OAuth access token. Cloudflare Workers keep
// warm isolates alive across requests in the same PoP, so this cache hits often
// enough to meaningfully reduce JWT signing load.
let cachedAccessToken: { token: string; expiresAtMillis: number } | null = null;

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (request.method !== "POST") {
      return new Response("Method not allowed", { status: 405 });
    }

    try {
      if (url.pathname === "/chat") {
        return await handleChat(request, env);
      }

      if (url.pathname === "/tts") {
        return await handleTTS(request, env);
      }

      if (url.pathname === "/transcribe-token") {
        return await handleTranscribeToken(env);
      }
    } catch (error) {
      console.error(`[${url.pathname}] Unhandled error:`, error);
      return new Response(
        JSON.stringify({ error: String(error) }),
        { status: 500, headers: { "content-type": "application/json" } }
      );
    }

    return new Response("Not found", { status: 404 });
  },
};

async function handleChat(request: Request, env: Env): Promise<Response> {
  // The Swift client builds a request body in the Anthropic Messages API shape
  // with "model", "max_tokens", "stream", "system", and "messages" fields.
  // For Vertex we need to move the model from the body to the URL path and
  // replace any top-level "anthropic_version" with Vertex's required value.
  const incomingBodyText = await request.text();

  let parsedBody: Record<string, unknown>;
  try {
    parsedBody = JSON.parse(incomingBodyText);
  } catch (parseError) {
    return new Response(
      JSON.stringify({ error: `Invalid JSON body: ${String(parseError)}` }),
      { status: 400, headers: { "content-type": "application/json" } }
    );
  }

  const modelName = typeof parsedBody.model === "string" ? parsedBody.model : null;
  if (!modelName) {
    return new Response(
      JSON.stringify({ error: "Request body is missing required 'model' field" }),
      { status: 400, headers: { "content-type": "application/json" } }
    );
  }

  // Remove the body-level "model" field (Vertex expects model in the URL path)
  // and splice in the Vertex-specific anthropic_version value.
  delete parsedBody.model;
  parsedBody.anthropic_version = "vertex-2023-10-16";

  // Vertex routes streaming vs non-streaming through different URL verbs.
  const isStreamingRequest = parsedBody.stream === true;
  const vertexVerb = isStreamingRequest ? "streamRawPredict" : "rawPredict";

  const vertexURL =
    `https://${env.VERTEX_REGION}-aiplatform.googleapis.com` +
    `/v1/projects/${env.VERTEX_PROJECT_ID}` +
    `/locations/${env.VERTEX_REGION}` +
    `/publishers/anthropic/models/${modelName}:${vertexVerb}`;

  const accessToken = await getVertexAccessToken(env);

  const vertexResponse = await fetch(vertexURL, {
    method: "POST",
    headers: {
      authorization: `Bearer ${accessToken}`,
      "content-type": "application/json",
    },
    body: JSON.stringify(parsedBody),
  });

  if (!vertexResponse.ok) {
    const errorBody = await vertexResponse.text();
    console.error(
      `[/chat] Vertex AI error ${vertexResponse.status} (model=${modelName}): ${errorBody}`
    );
    return new Response(errorBody, {
      status: vertexResponse.status,
      headers: { "content-type": "application/json" },
    });
  }

  // Forward the SSE stream through unchanged. Vertex's streamRawPredict emits
  // the same Anthropic-format SSE events (message_start, content_block_delta,
  // etc.) that ClaudeAPI.swift already parses.
  return new Response(vertexResponse.body, {
    status: vertexResponse.status,
    headers: {
      "content-type": vertexResponse.headers.get("content-type") || "text/event-stream",
      "cache-control": "no-cache",
    },
  });
}

async function getVertexAccessToken(env: Env): Promise<string> {
  // Return cached token if it is still valid for at least 60 more seconds.
  const nowMillis = Date.now();
  if (cachedAccessToken && cachedAccessToken.expiresAtMillis > nowMillis + 60_000) {
    return cachedAccessToken.token;
  }

  let parsedServiceAccountKey: ServiceAccountKey;
  try {
    parsedServiceAccountKey = JSON.parse(env.GCP_SERVICE_ACCOUNT_KEY) as ServiceAccountKey;
  } catch (parseError) {
    throw new Error(`GCP_SERVICE_ACCOUNT_KEY is not valid JSON: ${String(parseError)}`);
  }

  const signedJwtAssertion = await signServiceAccountJwt(parsedServiceAccountKey);

  const tokenExchangeResponse = await fetch(parsedServiceAccountKey.token_uri, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body:
      "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer" +
      `&assertion=${encodeURIComponent(signedJwtAssertion)}`,
  });

  if (!tokenExchangeResponse.ok) {
    const errorBody = await tokenExchangeResponse.text();
    throw new Error(
      `Vertex OAuth token exchange failed ${tokenExchangeResponse.status}: ${errorBody}`
    );
  }

  const tokenPayload = (await tokenExchangeResponse.json()) as {
    access_token: string;
    expires_in: number;
  };

  const accessTokenLifetimeMillis = tokenPayload.expires_in * 1000;
  cachedAccessToken = {
    token: tokenPayload.access_token,
    expiresAtMillis: nowMillis + accessTokenLifetimeMillis,
  };

  return tokenPayload.access_token;
}

async function signServiceAccountJwt(
  parsedServiceAccountKey: ServiceAccountKey
): Promise<string> {
  const jwtHeader = { alg: "RS256", typ: "JWT" };

  const issuedAtSeconds = Math.floor(Date.now() / 1000);
  const expiresAtSeconds = issuedAtSeconds + 3600; // 1 hour — Google's max
  const jwtClaims = {
    iss: parsedServiceAccountKey.client_email,
    scope: "https://www.googleapis.com/auth/cloud-platform",
    aud: parsedServiceAccountKey.token_uri,
    iat: issuedAtSeconds,
    exp: expiresAtSeconds,
  };

  const encodedHeader = base64UrlEncode(new TextEncoder().encode(JSON.stringify(jwtHeader)));
  const encodedClaims = base64UrlEncode(new TextEncoder().encode(JSON.stringify(jwtClaims)));
  const unsignedAssertion = `${encodedHeader}.${encodedClaims}`;

  const privateKeyCryptoKey = await importServiceAccountPrivateKey(parsedServiceAccountKey.private_key);
  const signatureBytes = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    privateKeyCryptoKey,
    new TextEncoder().encode(unsignedAssertion)
  );

  const encodedSignature = base64UrlEncode(new Uint8Array(signatureBytes));
  return `${unsignedAssertion}.${encodedSignature}`;
}

async function importServiceAccountPrivateKey(privateKeyPem: string): Promise<CryptoKey> {
  // The PEM contains base64 between header/footer lines. Strip those and the
  // newlines, then base64-decode to get the raw PKCS#8 DER bytes that
  // crypto.subtle.importKey expects.
  const base64Contents = privateKeyPem
    .replace("-----BEGIN PRIVATE KEY-----", "")
    .replace("-----END PRIVATE KEY-----", "")
    .replace(/\s+/g, "");

  const derBytes = Uint8Array.from(atob(base64Contents), (character) => character.charCodeAt(0));

  return await crypto.subtle.importKey(
    "pkcs8",
    derBytes,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"]
  );
}

function base64UrlEncode(bytes: Uint8Array): string {
  let binaryString = "";
  for (let byteIndex = 0; byteIndex < bytes.length; byteIndex++) {
    binaryString += String.fromCharCode(bytes[byteIndex]);
  }
  return btoa(binaryString).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function handleTranscribeToken(env: Env): Promise<Response> {
  const response = await fetch(
    "https://streaming.assemblyai.com/v3/token?expires_in_seconds=480",
    {
      method: "GET",
      headers: {
        authorization: env.ASSEMBLYAI_API_KEY,
      },
    }
  );

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/transcribe-token] AssemblyAI token error ${response.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }

  const data = await response.text();
  return new Response(data, {
    status: 200,
    headers: { "content-type": "application/json" },
  });
}

async function handleTTS(request: Request, env: Env): Promise<Response> {
  const body = await request.text();
  const voiceId = env.ELEVENLABS_VOICE_ID?.trim();
  const elevenLabsAPIKey = env.ELEVENLABS_API_KEY?.trim();

  if (!voiceId) {
    return new Response(
      JSON.stringify({ error: "ELEVENLABS_VOICE_ID is not configured" }),
      { status: 500, headers: { "content-type": "application/json" } }
    );
  }

  if (!elevenLabsAPIKey) {
    return new Response(
      JSON.stringify({ error: "ELEVENLABS_API_KEY is not configured" }),
      { status: 500, headers: { "content-type": "application/json" } }
    );
  }

  const response = await fetch(
    `https://api.elevenlabs.io/v1/text-to-speech/${voiceId}`,
    {
      method: "POST",
      headers: {
        "xi-api-key": elevenLabsAPIKey,
        "content-type": "application/json",
        accept: "audio/mpeg",
      },
      body,
    }
  );

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/tts] ElevenLabs API error ${response.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }

  return new Response(response.body, {
    status: response.status,
    headers: {
      "content-type": response.headers.get("content-type") || "audio/mpeg",
    },
  });
}
