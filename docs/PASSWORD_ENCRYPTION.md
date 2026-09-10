# Password Encryption for Unattended Windows Deployment

This document describes how the Workflow Query App stores and decrypts SQL Server database passwords so the application can run unattended on a Windows Server (no interactive user logged in) under PM2 after reboot.

## Purpose

The app connects to one or more SQL Server databases using credentials from environment variables. On a production Windows Server, those credentials must persist on disk without storing plaintext passwords in `.env.local`.

Windows **DPAPI** (Data Protection API) encrypts each database password and stores the ciphertext in `.env.local`. At runtime the Node.js process decrypts the password only in memory when opening a SQL connection.

This design supports unattended operation because:

- PM2 starts the app at Windows boot via `pm2-windows-startup` (configured by `setup-windows.bat`).
- After reboot, no one needs to log in interactively to supply database passwords.
- Encrypted values use **LocalMachine** scope so decryption works for any process on the same machine, not only the user who ran setup.

## Mechanism

| Item | Implementation |
|------|----------------|
| API | `System.Security.Cryptography.ProtectedData` (.NET, invoked from PowerShell) |
| Encrypt | `ProtectedData.Protect(...)` |
| Decrypt | `ProtectedData.Unprotect(...)` |
| Scope | **`DataProtectionScope.LocalMachine`** |
| Encoding | UTF-8 password bytes → DPAPI blob → Base64 string |
| Optional entropy | `$null` (none) |

**LocalMachine** means any process on this Windows machine can decrypt the blob (subject to OS DPAPI ACLs). **CurrentUser** scope is not used by the production code path in this repository.

### Source files

| File | Role |
|------|------|
| `setup-windows.bat` (lines 44–63) | One-time / setup-time encryption of plaintext `DB_*_PASSWORD` entries |
| `lib/db.ts` (`resolvePassword`, lines 4–47) | Runtime decryption when a connection pool is created |
| `lib/db.ts` (`getPool`, line 70) | Calls `resolvePassword(key)` for each database key |
| `.env.local` | Stores `DB_<KEY>_PASSWORD_ENCRYPTED=...` values (gitignored) |
| `ecosystem.config.js` | PM2 process definition (`next start` on port 3000) |

`lib/db-password.ts.new` is an unused local debug helper that decrypts with **CurrentUser** scope. It is not imported by the application and should not be used for production setup.

## Storage location

Encrypted credentials are stored in the project root file:

```
<app-root>/.env.local
```

For each database key listed in `DB_NAMES` (for example `PROD`, `TEST`), the encrypted variable name is:

```
DB_<KEY>_PASSWORD_ENCRYPTED=<base64 DPAPI blob>
```

Example:

```env
DB_NAMES=PROD,TEST
DB_PROD_SERVER=sql01.example.com
DB_PROD_DATABASE=IvantiDB
DB_PROD_USER=svc_workflow
DB_PROD_PASSWORD_ENCRYPTED=AQAAANCMnd8BFdERjHoAwE/Cl+sBAAAA...
DB_PROD_PORT=1433
```

There is no separate registry key or credential file. The blob lives only in `.env.local`.

`.env*` files are listed in `.gitignore` and must **not** be committed or pushed to Git.

## Encryption workflow (admin setup)

### Prerequisites

- Windows Server (or Windows workstation used as the deployment host)
- Node.js installed
- `.env.local` created in the app root with `DB_NAMES` and per-database settings
- Plaintext passwords present as `DB_<KEY>_PASSWORD=...` lines before encryption

### Automated (recommended)

1. Copy the application folder to the server.
2. Create `.env.local` with plaintext `DB_<KEY>_PASSWORD=...` for each database key.
3. **Right-click `setup-windows.bat` → Run as administrator.**

During setup, `setup-windows.bat` runs PowerShell that:

1. Reads `.env.local` line by line.
2. For each line matching `DB_<something>_PASSWORD=<value>` (and not already `*_ENCRYPTED`):
   - UTF-8-encodes the password bytes.
   - Calls `ProtectedData.Protect` with **LocalMachine** scope.
   - Base64-encodes the result.
   - **Replaces** the plaintext line with `DB_<something>_PASSWORD_ENCRYPTED=<base64>`.
3. Writes the updated lines back to `.env.local`.
4. Continues with `npm install`, `npm run build`, PM2 install, and boot startup configuration.

Relevant script block: `setup-windows.bat` lines 44–63.

### Manual encryption (same machine that will run the app)

Run in an elevated PowerShell session on the deployment server:

```powershell
Add-Type -AssemblyName System.Security
$plain = "your-plaintext-password"
$bytes = [System.Text.Encoding]::UTF8.GetBytes($plain)
$protected = [System.Security.Cryptography.ProtectedData]::Protect(
  $bytes,
  $null,
  [System.Security.Cryptography.DataProtectionScope]::LocalMachine
)
[System.Convert]::ToBase64String($protected)
```

Paste the output into `.env.local`:

```env
DB_PROD_PASSWORD_ENCRYPTED=<paste base64 here>
```

Remove any plaintext `DB_PROD_PASSWORD=...` line after verifying the app connects.

## Decryption workflow (runtime)

1. Next.js loads `.env.local` when the process starts (dev, `next start`, or PM2).
2. An API route handles a request and calls `getPool(dbKey)` from `lib/db.ts`.
3. On first use of a database key, `getPool` builds a `mssql` config and calls `resolvePassword(key)` (line 70).
4. `resolvePassword` (lines 9–47):
   - Reads `process.env[`DB_${key}_PASSWORD_ENCRYPTED`]`.
   - If unset, falls back to `process.env[`DB_${key}_PASSWORD`]` (local development).
   - If set, spawns `powershell.exe` with `-NonInteractive` and runs `ProtectedData.Unprotect` using **LocalMachine** scope on the Base64 blob (passed via the `ENCRYPTED_PW` environment variable for that child process).
   - Returns the decrypted UTF-8 string to the connection pool.
5. The password is used only for the in-memory SQL connection; it is not written back to disk.

Decryption happens **lazily** on the first API request that needs each database, not at Node process startup.

### Required run context

- The app must run on the **same Windows machine** where the password was encrypted with LocalMachine DPAPI.
- The encrypting step should be performed **as Administrator** (required for reliable LocalMachine protect/unprotect).
- PM2 / `pm2-windows-startup` typically runs under the user account that completed setup; LocalMachine blobs remain decryptable by other local processes on that machine.
- The Node process must be able to execute `powershell.exe` (used for every new connection pool that relies on an encrypted password).

## Security considerations

### DPAPI binding

- **Machine binding:** LocalMachine ciphertext created on Server A cannot be decrypted on Server B.
- **OS binding:** Restoring `.env.local` to a new VM or rebuilt server requires re-encrypting passwords on that new host.
- **Not secret from local admins:** LocalMachine DPAPI protects against casual disclosure (file copy, backups of `.env.local` without the machine key) but does not protect against a malicious administrator on the same box.

### Plaintext fallback

If `DB_<KEY>_PASSWORD_ENCRYPTED` is missing, `resolvePassword` uses plaintext `DB_<KEY>_PASSWORD`. Use that only for local development; production servers should have only `*_ENCRYPTED` entries.

### File permissions

Restrict ACLs on `.env.local` to the service account and administrators. Even encrypted blobs should be treated as sensitive configuration.

### SQL login vs. DPAPI

Rotating the **SQL Server login password** does not automatically update `.env.local`. You must re-encrypt and replace the `DB_<KEY>_PASSWORD_ENCRYPTED` value (see Recovery below).

### Git / backups

Never commit `.env.local`. The repository `.gitignore` excludes `.env*`.

## Recovery and credential rotation

### SQL password changed

1. Stop the app: `pm2 stop workflow-query-app`
2. Edit `.env.local` and add a temporary plaintext line, for example `DB_PROD_PASSWORD=new-sql-password`
3. Remove the old `DB_PROD_PASSWORD_ENCRYPTED=...` line (or let setup replace it).
4. Re-run the encryption step:
   - **Option A:** Run `setup-windows.bat` as Administrator (it re-encrypts plaintext `DB_*_PASSWORD` lines), or
   - **Option B:** Run the manual PowerShell encrypt command above and update `DB_<KEY>_PASSWORD_ENCRYPTED` yourself.
5. Confirm no plaintext `DB_*_PASSWORD` lines remain.
6. Restart: `pm2 restart workflow-query-app`
7. Verify connectivity: `pm2 logs workflow-query-app` and exercise an API route.

### Server migration or rebuild

1. Deploy the application to the new server.
2. Create a fresh `.env.local` with plaintext passwords or new encrypted values generated **on the new server**.
3. Do **not** copy `DB_*_PASSWORD_ENCRYPTED` values from the old machine; they will not decrypt.
4. Run `setup-windows.bat` as Administrator on the new host.

### Decryption failures

Typical errors appear in PM2 logs as `Failed to decrypt DB_<KEY>_PASSWORD_ENCRYPTED` (from `lib/db.ts` lines 34–37).

| Symptom | Likely cause | Action |
|---------|----------------|--------|
| Decrypt error after copy/paste of `.env.local` | Blob from another machine or wrong DPAPI scope | Re-encrypt on this server with LocalMachine |
| Empty password after decrypt | Corrupt Base64 or wrong variable name | Regenerate blob; check `DB_<KEY>_PASSWORD_ENCRYPTED` spelling |
| Worked before reboot, fails after | `.env.local` missing or PM2 wrong cwd | Confirm `.env.local` in app root; `pm2 restart workflow-query-app` |
| `CurrentUser` blob on this codebase | Legacy ciphertext from older setup | Re-encrypt with current `setup-windows.bat` (LocalMachine) |

### Regenerate without full reinstall

From an elevated PowerShell prompt in the app root:

```powershell
$f = '.env.local'
$lines = Get-Content $f
$out = foreach ($l in $lines) {
  if ($l -match '^(DB_[^=]+_PASSWORD)=(.+)$' -and $l -notmatch '_ENCRYPTED') {
    $key = $matches[1]; $pw = $matches[2]
    Add-Type -AssemblyName System.Security
    $b = [System.Text.Encoding]::UTF8.GetBytes($pw)
    $e = [System.Convert]::ToBase64String(
      [System.Security.Cryptography.ProtectedData]::Protect(
        $b, $null,
        [System.Security.Cryptography.DataProtectionScope]::LocalMachine
      )
    )
    Write-Host "Encrypted: $key"
    "$key" + "_ENCRYPTED=$e"
  } else { $l }
}
Set-Content $f $out
```

Then restart PM2.

## Quick reference

| Task | Command / location |
|------|---------------------|
| Encrypt at setup | `setup-windows.bat` (as Administrator) |
| Encrypted storage | `.env.local` → `DB_<KEY>_PASSWORD_ENCRYPTED` |
| Runtime decrypt | `lib/db.ts` → `resolvePassword()` → PowerShell `Unprotect` |
| Process manager | PM2 via `ecosystem.config.js` |
| Boot persistence | `pm2-windows-startup` (global install path in `setup-windows.bat`) |
