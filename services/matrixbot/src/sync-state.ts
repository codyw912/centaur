import { mkdir, readFile, rename, writeFile } from 'node:fs/promises'
import { dirname } from 'node:path'

export type SyncState = {
  since?: string
  initialized: boolean
  seenEventIds: Set<string>
}

export function createSyncState(since?: string): SyncState {
  return {
    since,
    initialized: Boolean(since),
    seenEventIds: new Set()
  }
}

export async function loadSyncToken(path: string | undefined): Promise<string | undefined> {
  if (!path) return undefined
  try {
    const token = (await readFile(path, 'utf8')).trim()
    return token || undefined
  } catch (error) {
    if (isNotFound(error)) return undefined
    throw error
  }
}

export async function saveSyncToken(
  path: string | undefined,
  token: string | undefined
): Promise<void> {
  if (!path || !token) return
  await mkdir(dirname(path), { recursive: true })
  const tempPath = `${path}.tmp`
  await writeFile(tempPath, `${token}\n`, 'utf8')
  await rename(tempPath, path)
}

export function rememberEvent(state: SyncState, eventId: string, maxSeen = 2_000): boolean {
  if (state.seenEventIds.has(eventId)) return false
  state.seenEventIds.add(eventId)
  if (state.seenEventIds.size > maxSeen) {
    const oldest = state.seenEventIds.values().next().value
    if (oldest) state.seenEventIds.delete(oldest)
  }
  return true
}

function isNotFound(error: unknown): boolean {
  return (
    error instanceof Error &&
    'code' in error &&
    (error as Error & { code?: string }).code === 'ENOENT'
  )
}
