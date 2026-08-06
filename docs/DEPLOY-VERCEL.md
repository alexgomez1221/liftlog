# Lift Log

A workout tracker PWA. Static files, no build step, no backend — data lives in the browser's localStorage on your device.

**Stack note:** unlike the budget app, this one is plain HTML/CSS/JS in a single `index.html`. Same deploy pipeline (GitHub → Vercel), same PWA behavior, but no Vite/React build. To ship a change you edit `index.html` and push.

---

## ⚠️ Do this before you deploy

Your existing workouts are stored against **the exact origin you've been opening the app from**. A new URL is a new origin, which means an empty app. Nothing transfers automatically.

1. Open the app the way you have been
2. **Settings (⚙) → Back Up Now** — saves `liftlog-backup-YYYY-MM-DD.json`
3. Keep that file somewhere you can reach from your phone (iCloud Drive / Google Drive / email it to yourself)
4. After the site is live, open it, go to **Settings → Restore from backup file**, pick that JSON

Don't skip step 1. It's the only copy.

---

## Files

| File | Purpose |
|---|---|
| `index.html` | The entire app |
| `manifest.webmanifest` | App name, icons, standalone display |
| `sw.js` | Service worker — offline support + install |
| `icons/` | App icons (180/192/512 + maskable) |
| `vercel.json` | Cache headers so `sw.js` never goes stale |
| `.gitignore` | Keeps `.DS_Store`, zips and backup files out of commits |

---

## Deploy: GitHub → Vercel

Same pipeline as the budget app. If Git is already configured on this machine from that project, skip to step 2.

### 1. One-time machine setup

```bash
git --version                     # if missing, macOS will prompt to install
git config --global user.name  "Alex Gomez"
git config --global user.email "alexgomez1221@gmail.com"
```

Set the email **before** your first commit — fixing authorship afterward means rewriting history.

### 2. Put the folder somewhere permanent

Download `liftlog.zip`, double-click to unzip, and move the resulting `liftlog` folder somewhere you'll keep it — `Documents` or `Projects` is fine, **not** Downloads (things get cleaned out of there).

### 3. Create the repo

Open **Terminal** (Cmd+Space → "Terminal"). Type `cd ` — with a trailing space — then **drag the `liftlog` folder from Finder onto the Terminal window**. It fills in the real path for you. Press Enter.

```bash
cd            ← type this, then drag the folder in, then Enter
```

Confirm you're in the right place — this should list `index.html`, `sw.js`, `manifest.webmanifest`, `icons`:

```bash
ls
```

Then:

```bash
git init
git add -A
git commit -m "Lift Log: initial commit"
```

On github.com: **New repository** → name it `liftlog` → **don't** add a README or .gitignore (you have both) → Create.

Then run the two commands GitHub shows you, which look like:

```bash
git remote add origin https://github.com/<your-username>/liftlog.git
git branch -M main
git push -u origin main
```

When prompted for a password, paste a **Personal Access Token**, not your GitHub password (Settings → Developer settings → Personal access tokens → Tokens (classic) → Generate new token → check `repo`).

### 4. Connect Vercel

1. vercel.com → **Add New… → Project**
2. Import the `liftlog` repo
3. Framework Preset: **Other**. Leave build command and output directory **empty** — it's static.
4. **Deploy**

You get `liftlog-<something>.vercel.app`. In Project Settings → Domains you can rename it to something stable like `alex-liftlog.vercel.app`.

**Pick the URL you want and keep it.** Changing the domain later strands your data at the old one (restore from backup if you do).

### 5. Shipping changes

```bash
git add -A
git commit -m "what changed"
git push
```

Vercel deploys in ~1 minute. Bump `CACHE_VERSION` in `sw.js` when you change `index.html` so phones don't serve a stale cache.

---

## Install on your iPhone

1. Open the Vercel URL **in Safari** (not Chrome — iOS only allows Safari to install PWAs)
2. Tap the **Share** button
3. Scroll down → **Add to Home Screen** → **Add**

It launches fullscreen with no browser chrome and works offline at the gym.

**After every deploy:** swipe up to force-close the app, then reopen. iOS won't pick up a new service worker while the app is merely backgrounded.

### Android

Chrome → menu → **Install app** / **Add to Home screen**.

---

## How your data is protected

Three layers, guarding three different failures:

**Backup file** (Settings → Back Up Now) — the only real backup. A dated JSON you control. It's the sole thing that survives clearing your browser, losing your phone, or moving to a new URL. Store it off-device.

**Persistent storage** — on load the app calls `navigator.storage.persist()`, asking the browser not to evict its data. This matters on iOS, where Safari clears storage for sites untouched for ~7 days. Installing to the home screen makes the browser far more likely to grant it. Settings shows `🔒 Storage protected` or `⚠ Storage evictable`.

**Restore points** (Settings → Restore Points) — rolling snapshots taken on app open and before any import, so you can undo a bad import or a deleted workout. These live in the *same* storage as your data, so they're an undo, not a backup.

A banner appears on the Workout tab when your last backup is over a week old.

### Where the data actually is

`localStorage`, on the device, keyed to the origin. It is never uploaded — there's no server. Consequences:

- Your phone and your laptop keep **separate** data. Moving between them means export → import.
- Clearing Safari's website data wipes it.
- The GitHub repo is public on Vercel's free tier, but only the *code* is published. Your workouts are never in it.

---

## Troubleshooting

**"Add to Home Screen" is missing** — you're not in Safari, or the page hasn't finished loading.

**App won't update after a deploy** — force-close it (swipe up from app switcher) and reopen. If it persists, bump `CACHE_VERSION` in `sw.js`, push, then force-close again.

**Opened the URL and it's empty** — expected. New origin. Settings → Restore from backup file.

**Doesn't work offline** — the service worker only registers over HTTPS. It's intentionally disabled on `file://`. Load the real URL once while online, then it caches.

**Storage says "evictable"** — install to the home screen and use it a few times; browsers grant persistence based on engagement. Keep taking backup files regardless.
