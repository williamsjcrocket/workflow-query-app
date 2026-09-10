import sql from "mssql";
import { spawnSync } from "child_process";

/**
 * Decrypts DB_<key>_PASSWORD_ENCRYPTED using Windows DPAPI LocalMachine scope.
 * LocalMachine is required for unattended Windows Server execution (PM2/service
 * after reboot) when the process identity may differ from the encrypting user.
 */
function resolvePassword(key: string): string {
  const encrypted = process.env[`DB_${key}_PASSWORD_ENCRYPTED`];

  if (!encrypted) {
    return process.env[`DB_${key}_PASSWORD`] ?? "";
  }

  const result = spawnSync(
    "powershell.exe",
    [
      "-NoProfile",
      "-NonInteractive",
      "-Command",
      "[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; Add-Type -AssemblyName System.Security; [System.Text.Encoding]::UTF8.GetString([System.Security.Cryptography.ProtectedData]::Unprotect([System.Convert]::FromBase64String($env:ENCRYPTED_PW), $null, [System.Security.Cryptography.DataProtectionScope]::LocalMachine))",
    ],
    {
      env: { ...process.env, ENCRYPTED_PW: encrypted },
      encoding: "utf8",
    }
  );

  if (result.error) {
    throw result.error;
  }

  if (result.status !== 0) {
    throw new Error(
      `Failed to decrypt DB_${key}_PASSWORD_ENCRYPTED: ${result.stderr?.trim() || "unknown error"}`
    );
  }

  const password = result.stdout.replace(/\r?\n$/, "");

  if (!password) {
    throw new Error(`DPAPI decryption returned an empty password for DB key "${key}".`);
  }

  return password;
}

export interface DbInfo {
  key: string;
  label: string;
}

export function getDatabases(): DbInfo[] {
  return (process.env.DB_NAMES ?? "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean)
    .map((key) => ({ key, label: process.env[`DB_${key}_LABEL`] ?? key }));
}

const pools = new Map<string, { pool: sql.ConnectionPool; connect: Promise<sql.ConnectionPool> }>();

export function getPool(key: string) {
  if (!pools.has(key)) {
    const config: sql.config = {
      server: process.env[`DB_${key}_SERVER`]!,
      database: process.env[`DB_${key}_DATABASE`]!,
      user: process.env[`DB_${key}_USER`]!,
      password: resolvePassword(key),
      port: parseInt(process.env[`DB_${key}_PORT`] ?? "1433"),
      requestTimeout: 60000,
      connectionTimeout: 30000,
      options: { encrypt: true, trustServerCertificate: true },
    };

    console.log("DB config check", {
      key,
      server: process.env[`DB_${key}_SERVER`],
      database: process.env[`DB_${key}_DATABASE`],
      user: process.env[`DB_${key}_USER`],
      port: process.env[`DB_${key}_PORT`] ?? "1433",
      hasEncrypted: !!process.env[`DB_${key}_PASSWORD_ENCRYPTED`],
      hasPlain: !!process.env[`DB_${key}_PASSWORD`],
      resolvedPasswordLength: config.password?.length ?? 0,
    });

    const pool = new sql.ConnectionPool(config);
    pools.set(key, { pool, connect: pool.connect() });
  }
  return pools.get(key)!;
}

export function defaultDbKey(): string {
  const first = (process.env.DB_NAMES ?? "").split(",")[0]?.trim();
  return first ?? "";
}
