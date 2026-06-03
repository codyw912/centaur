export type AppConfig = {
  nodeEnv: string
  port: number
  matrixHomeserverUrl: string
  matrixAccessToken: string
  matrixUserId: string
  matrixDeviceId: string
  matrixDefaultHarness: string
  matrixProcessInitialSync: boolean
  matrixSyncTimeoutMs: number
  matrixPollIntervalMs: number
  matrixSyncTokenPath?: string
  matrixAllowedRooms: Set<string>
  centaurApiUrl: string
  centaurApiKey?: string
}

export function loadConfig(env: Record<string, string | undefined> = process.env): AppConfig {
  return {
    nodeEnv: env.NODE_ENV ?? 'development',
    port: positiveInt(env.PORT, 3002),
    matrixHomeserverUrl: requiredUrl(env.MATRIX_HOMESERVER_URL, 'MATRIX_HOMESERVER_URL'),
    matrixAccessToken: required(env.MATRIX_ACCESS_TOKEN, 'MATRIX_ACCESS_TOKEN'),
    matrixUserId: required(env.MATRIX_USER_ID, 'MATRIX_USER_ID'),
    matrixDeviceId: env.MATRIX_DEVICE_ID || 'centaur-matrixbot',
    matrixDefaultHarness: env.MATRIX_DEFAULT_HARNESS || 'claude-code',
    matrixProcessInitialSync: bool(env.MATRIX_PROCESS_INITIAL_SYNC, false),
    matrixSyncTimeoutMs: positiveInt(env.MATRIX_SYNC_TIMEOUT_MS, 30_000),
    matrixPollIntervalMs: positiveInt(env.MATRIX_POLL_INTERVAL_MS, 1_000),
    matrixSyncTokenPath: optional(env.MATRIX_SYNC_TOKEN_PATH),
    matrixAllowedRooms: csvSet(env.MATRIX_ALLOWED_ROOMS),
    centaurApiUrl: requiredUrl(env.CENTAUR_API_URL || 'http://localhost:8000', 'CENTAUR_API_URL'),
    centaurApiKey: env.MATRIXBOT_API_KEY || env.CENTAUR_API_KEY || undefined
  }
}

function required(value: string | undefined, name: string): string {
  if (!value?.trim()) throw new Error(`${name} is required`)
  return value.trim()
}

function optional(value: string | undefined): string | undefined {
  const trimmed = value?.trim()
  return trimmed || undefined
}

function requiredUrl(value: string | undefined, name: string): string {
  const raw = required(value, name).replace(/\/+$/, '')
  try {
    return new URL(raw).toString().replace(/\/+$/, '')
  } catch {
    throw new Error(`${name} must be a valid URL`)
  }
}

function positiveInt(value: string | undefined, fallback: number): number {
  if (!value) return fallback
  const parsed = Number(value)
  return Number.isInteger(parsed) && parsed > 0 ? parsed : fallback
}

function bool(value: string | undefined, fallback: boolean): boolean {
  if (value === undefined) return fallback
  return /^(1|true|yes|on)$/i.test(value)
}

function csvSet(value: string | undefined): Set<string> {
  return new Set(
    (value ?? '')
      .split(',')
      .map(item => item.trim())
      .filter(Boolean)
  )
}
