# Workflow Query App

A Next.js internal tool for Ivanti ISM workflow team ownership, RO form attributes, RO workflow blocks, and BO workflow attributes. Supports multiple SQL Server databases via environment config.

## Features

- **RO Team Query** (`/`) — find which team owns a block in a request-offering workflow
- **RO Form Attributes** (`/ro-attributes`) — list form field attributes for request offerings
- **RO Workflow Blocks** (`/ro-workflow-blocks`) — list workflow blocks for request offerings
- **BO Workflow Attributes** (`/bo-workflows`) — query business-object workflow team assignments
- Multi-database selector
- CSV / clipboard export
- Database Explorer at `/explore`

## Offering Status

Results include linked offering statuses (`Published`, `Design`) and **No Offering** when a workflow has no linked request offering.

## Setup

Create a `.env.local` file in the project root (multi-database):

```
DB_NAMES=PROD,TEST
DB_PROD_LABEL=Production
DB_PROD_SERVER=your-sql-server
DB_PROD_DATABASE=your-database
DB_PROD_USER=your-username
DB_PROD_PASSWORD=your-password
DB_PROD_PORT=1433
DB_TEST_LABEL=Test
DB_TEST_SERVER=your-test-server
DB_TEST_DATABASE=your-test-database
DB_TEST_USER=your-username
DB_TEST_PASSWORD=your-password
DB_TEST_PORT=1433
```

Install dependencies and run the dev server:

```bash
npm install
npm run dev
```

Open [http://localhost:3000](http://localhost:3000).

## Encrypting Database Passwords (Windows DPAPI)

For Windows Server deployments, encrypt passwords with **DPAPI LocalMachine** so the app can decrypt them when running unattended under PM2/service accounts after reboot.

**If you use `setup-windows.bat`:** put plaintext `DB_<KEY>_PASSWORD=...` values in `.env.local` and run the script. It encrypts each to `DB_<KEY>_PASSWORD_ENCRYPTED=...` and removes the plaintext.

**Manual encrypt** (on the Windows machine that will run the app):

```powershell
Add-Type -AssemblyName System.Security
[System.Convert]::ToBase64String(
  [System.Security.Cryptography.ProtectedData]::Protect(
    [System.Text.Encoding]::UTF8.GetBytes("your-plaintext-password"),
    $null,
    [System.Security.Cryptography.DataProtectionScope]::LocalMachine
  )
)
```

Example encrypted entry:

```
DB_PROD_PASSWORD_ENCRYPTED=<paste encrypted value here>
```

Decryption is handled in `lib/db.ts`. If `DB_<KEY>_PASSWORD_ENCRYPTED` is unset, the app falls back to `DB_<KEY>_PASSWORD` for local development.

## Windows Deployment (unattended)

`setup-windows.bat` installs dependencies, builds the app, installs PM2, encrypts passwords with LocalMachine DPAPI, and configures startup on Windows boot.

**Prerequisites:**
- [Node.js](https://nodejs.org) installed (20 LTS or 22 LTS recommended)
- `.env.local` present with multi-DB settings

**Steps:**
1. Copy the app folder to the Windows Server
2. Create `.env.local` with `DB_NAMES` and per-database settings
3. Right-click `setup-windows.bat` → **Run as Administrator**

App URL: [http://localhost:3000](http://localhost:3000)

**Useful PM2 commands:**
```bash
pm2 status
pm2 logs workflow-query-app
pm2 restart workflow-query-app
pm2 stop workflow-query-app
```

## Uninstalling

Use `uninstall-windows.bat`, or manually:

```bash
pm2 delete workflow-query-app
npx pm2-windows-startup uninstall
pm2 save
npm uninstall -g pm2 pm2-windows-startup
```

## API Routes

| Route | Method | Description |
|---|---|---|
| `/api/databases` | GET | List configured databases |
| `/api/query` | POST | RO team/block query |
| `/api/teams` | GET | Service desk teams and approval groups (`?db=`) |
| `/api/export/workflow-results.csv` | GET | CSV export for RO team query |
| `/api/ro-attributes` | POST | RO form attributes query |
| `/api/ro-blocks` | POST | RO workflow blocks query |
| `/api/ro-statuses` | GET | Offering statuses |
| `/api/export/ro-attributes.csv` | GET | CSV export for RO attributes |
| `/api/bo-query` | POST | BO workflow query |
| `/api/bo-object-types` | GET | BO object types |
| `/api/explore` | POST | Ad-hoc schema explorer queries |

## Tech Stack

- Next.js 16 / React 19 / Tailwind CSS v4
- `mssql` for SQL Server
- PM2 + `pm2-windows-startup` for unattended Windows hosting
