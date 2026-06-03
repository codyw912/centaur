export function logInfo(event: string, fields: Record<string, unknown> = {}): void {
  log('info', event, fields)
}

export function logWarn(event: string, fields: Record<string, unknown> = {}): void {
  log('warning', event, fields)
}

export function logError(event: string, error: unknown, fields: Record<string, unknown> = {}): void {
  log('error', event, {
    ...fields,
    error: error instanceof Error ? error.message : String(error)
  })
}

function log(level: string, event: string, fields: Record<string, unknown>): void {
  console.log(
    JSON.stringify({
      timestamp: new Date().toISOString(),
      level,
      service: 'matrixbot',
      event,
      ...fields
    })
  )
}
