# Phase 4 — Client sync

Goal: the app signs in against Cognito and syncs workouts through the API automatically.

Done when a workout logged on your phone appears on your laptop without exporting a file.

---

## 1. Deploy

No Terraform in this phase — it's all client code, already written into `index.html`.

```bash
cd <your-repo>
git add -A
git commit -m "Phase 4: cloud sync in the app"
git push
```

Vercel deploys in about a minute. Then **force-close the app on your phone and reopen it twice** — the service worker cache version moved to `liftlog-v6`.

Confirm you're on the new build: Settings should read **build 6**.

---

## 2. Sign in

Settings → **Cloud Sync** → **Sign In to Sync**.

You'll go to the Cognito hosted UI, sign in, and come back to the app. The `?code=` in the URL is exchanged for tokens and stripped from the address bar automatically.

The card should then show **Synced just now**.

---

## 3. Prove it works across devices

On your laptop, open the same URL and sign in with the same account. Your workouts should appear.

Then the real test:

1. Log a workout on your phone
2. Open the app on your laptop (or hit **Sync Now**)
3. It's there

Deletion works the same way — delete a workout on one device, sync, and it disappears on the other rather than coming back.

---

## How it works

### Offline-first

`localStorage` remains the source of truth. Every network call is best-effort and nothing blocks the UI. Log a full session in a basement with no signal and it uploads next time you open the app with a connection.

Sync triggers on app open, when the tab becomes visible, when the browser reports coming back online, and after finishing a workout. All of those are quiet — failures don't nag. Only the explicit **Sync Now** button reports either way.

### Pull before push

This is the part that matters, and I got it wrong the first time.

On a first sync there's no `lastSyncAt`, so *every* local item counts as outgoing. Pushing first uploads stale local records over newer remote ones, then the pull reads back what was just clobbered. Silent data loss, and it only shows up on a second device.

Pulling first merges by timestamp, so whatever gets pushed afterwards is already the winning version. The test that caught it seeds a newer remote routine against an older local one and asserts the remote survives.

### Conflict resolution

Last-write-wins on `updatedAt`. One person can't be in two gyms at once, so genuine concurrent edits are near-impossible and a CRDT would be complexity for nothing. Revisit if routines ever become shareable.

### Deletions need tombstones

Deleting a record locally can't just remove it — the next pull would see it on the server and restore it. Instead a tombstone `{sk, updatedAt}` is recorded and synced, and the server stores the item with `deleted: true`.

Tombstones are pruned after 90 days. Any device that hasn't synced in that long has an expired refresh token anyway and will sign in fresh.

A tombstone and a live item for the same key resolve by timestamp like anything else, so a stale delete can't keep killing a record another device has recreated.

### Entity mapping

| Local | Sort key |
|---|---|
| profile | `PROFILE` |
| workout | `WORKOUT#<date>#<id>` |
| routine | `ROUTINE#<id>` |
| folder | `FOLDER#<id>` |
| custom exercise | `EXERCISE#<id>` |
| body weight entry | `BODY#<date>` |

Date-prefixing workouts means a range query over a date window works without a secondary index.

### Auth

Authorization code flow with **PKCE**. The app generates a random verifier, sends its SHA-256 hash to Cognito, and proves possession when exchanging the code. That's what makes the flow safe for a public client with no secret — an intercepted code is useless without the verifier.

Access tokens last an hour and refresh silently in the background; refresh tokens last 30 days. Sign-out clears tokens and leaves all local data untouched.

### Sync is not backup

Worth being explicit, because it's a common and expensive misunderstanding. Sync replicates whatever you did — including deleting something by accident. The backup file is still the only thing that can undo a mistake. The Settings copy says so.

---

## Troubleshooting

**Card says "Not signed in" after signing in** — the redirect URL must be registered in Cognito. `callback_urls` in `terraform.tfvars` needs to contain your exact origin with a trailing slash.

**"Sync failed: 401"** — expired refresh token, after 30 days idle. Sign in again.

**"Sync failed: 403"** — the Lambda function URL's resource policy. See Phase 3.

**Workouts not appearing on the other device** — confirm both are signed in as the same account, and both report build 6. Hit **Sync Now** on both.

**Watch the API while testing:**

```bash
aws logs tail "$(terraform output -raw api_log_group)" --follow
```

---

## Next: Phase 5

Move hosting from Vercel to S3 + CloudFront, so the whole stack lives in AWS.

Note that this changes the origin, which means `localStorage` starts empty at the new URL — but with sync working, signing in restores everything. That's the first real payoff: the migration that would have needed an export/import file now just works.
