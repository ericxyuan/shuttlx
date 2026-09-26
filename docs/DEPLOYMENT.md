# ShuttlX web deployment

The ShuttlX website is a full-stack Worker application. The browser interface,
Apple callback, Watch API and per-account data store must be deployed together.
The `ericxyn/shuttlx` GitHub repository is the source of truth for this project;
GitHub Pages is not the runtime for this application because Pages cannot run the
D1-backed API or the Apple sign-in callback.

## Apple sign-in configuration

Create a Sign in with Apple Service ID for the final site host and add the exact
callback URL:

```
https://YOUR_HOST/api/auth/apple/callback
```

Configure these environment variables in the Worker/Sites project. Keep the
private key out of Git:

```
APPLE_CLIENT_ID=your.service.id
APPLE_TEAM_ID=your-team-id
APPLE_KEY_ID=your-key-id
APPLE_PRIVATE_KEY=-----BEGIN PRIVATE KEY-----...-----END PRIVATE KEY-----
APPLE_REDIRECT_URI=https://YOUR_HOST/api/auth/apple/callback
PUBLIC_BASE_URL=https://YOUR_HOST
```

The callback verifies Apple’s signed identity token, creates or updates the
Apple account, and stores only a hashed session identifier in D1. Every session,
preference and Watch device row is keyed by the account id. Apple only returns a
name on the first authorization, so the profile name can still be edited in
ShuttlX later.

## Watch QR pairing

1. On the standalone Watch app, open **Website sync**, enter the final HTTPS
   host, and choose **Show pairing QR**.
2. On the iPhone ShuttlX app, choose **Scan Watch pairing QR**.
3. The browser opens `/pair`, asks for Sign in with Apple when necessary, and
   claims the nonce exactly once at `/api/device/qr/claim`.
4. The browser returns a short-lived credential to the iPhone custom URL. The
   iPhone sends it to the Watch over WatchConnectivity; the Watch stores it in
   Keychain and uploads summaries directly to the website.

The QR is deliberately not a reusable account code. A nonce is recorded in the
`qr_claims` table, the resulting device token is stored as a hash, and a second
claim receives a conflict response. Apply the generated Drizzle migration before
the Worker receives traffic:

```
web/drizzle/0000_mute_patch.sql
web/drizzle/0001_sparkling_phalanx.sql
```

## Custom domain

Use the Sites/Worker deployment URL as the initial origin, then add the desired
custom domain with HTTPS. Point DNS to the target supplied by the hosting
provider, update `PUBLIC_BASE_URL` and `APPLE_REDIRECT_URI`, and add the same
callback URL in Apple Developer. The Watch must use the final HTTPS origin; it
does not follow browser sign-in redirects while uploading data.

Do not reuse `altitude.linkpc.net`. That CNAME belongs to the separate static
Altitude GitHub Pages project at
[`ericxyn/ericxyn.github.io`](https://github.com/ericxyn/ericxyn.github.io),
which remains unchanged.

## Local checks

From PowerShell in `C:\Users\admin\iCloudDrive\ShuttlX\web`, build the Worker,
apply the local D1 migrations and run the local acceptance check:

```
node scripts/run-framework.mjs build
node node_modules/wrangler/bin/wrangler.js d1 execute DB --local --persist-to .wrangler/state --file drizzle/0000_mute_patch.sql --config dist/server/wrangler.json
node node_modules/wrangler/bin/wrangler.js d1 execute DB --local --persist-to .wrangler/state --file drizzle/0001_sparkling_phalanx.sql --config dist/server/wrangler.json
python tests/api-check.py
```

The native project still needs a Mac with Xcode for Swift type checking,
simulator accessibility checks, Apple signing and paired Watch testing.
