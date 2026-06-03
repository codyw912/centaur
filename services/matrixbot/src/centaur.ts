import type { AppConfig } from './config'

export type MatrixDelivery = {
  platform: 'matrix'
  room_id: string
  thread_root_event_id?: string
  reply_to_event_id?: string
  sender?: string
}

export type ExecuteInput = {
  threadKey: string
  eventId?: string
  message: string
  harness: string
  delivery: MatrixDelivery
  metadata?: Record<string, unknown>
}

export type FinalDelivery = {
  execution_id: string
  thread_key: string
  delivery?: MatrixDelivery
  final_payload?: Record<string, unknown>
  trace_id?: string
  traceparent?: string
}

const CONSUMER_ID = `matrixbot-${process.pid}`

export async function executeAgent(config: AppConfig, input: ExecuteInput): Promise<unknown> {
  const turnId = stableTurnId(input)
  const spawn = await centaur(config, '/agent/spawn', {
    thread_key: input.threadKey,
    spawn_id: `spawn-${turnId}`,
    harness: input.harness
  })
  const assignmentGeneration = Number(spawn?.assignment_generation)
  if (!Number.isInteger(assignmentGeneration)) {
    throw new Error('Centaur spawn response did not include assignment_generation')
  }

  await centaur(config, '/agent/message', {
    thread_key: input.threadKey,
    assignment_generation: assignmentGeneration,
    message_id: `msg-${turnId}`,
    role: 'user',
    parts: [{ type: 'text', text: input.message }],
    user_id: input.delivery.sender,
    metadata: input.metadata ?? {}
  })

  return centaur(config, '/agent/execute', {
    thread_key: input.threadKey,
    assignment_generation: assignmentGeneration,
    execute_id: `exec-${turnId}`,
    harness: input.harness,
    delivery: input.delivery,
    metadata: input.metadata ?? {}
  })
}

export async function claimFinalDeliveries(
  config: AppConfig,
  limit = 5
): Promise<FinalDelivery[]> {
  const response = await centaur(config, '/agent/final-deliveries/claim', {
    consumer_id: CONSUMER_ID,
    platform: 'matrix',
    limit,
    lease_seconds: 60
  })
  return Array.isArray(response?.deliveries) ? response.deliveries : []
}

export async function markFinalDelivered(config: AppConfig, executionId: string): Promise<void> {
  await centaur(config, `/agent/final-deliveries/${executionId}/delivered`, {
    consumer_id: CONSUMER_ID
  })
}

export async function markFinalFailed(
  config: AppConfig,
  executionId: string,
  error: unknown
): Promise<void> {
  await centaur(config, `/agent/final-deliveries/${executionId}/failed`, {
    consumer_id: CONSUMER_ID,
    error: error instanceof Error ? error.message : String(error),
    retry_after_seconds: 10
  })
}

async function centaur(config: AppConfig, path: string, body: unknown): Promise<any> {
  const response = await fetch(new URL(path, config.centaurApiUrl), {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      ...(config.centaurApiKey ? { Authorization: `Bearer ${config.centaurApiKey}` } : {})
    },
    body: JSON.stringify(body)
  })
  const text = await response.text()
  const parsed = text ? JSON.parse(text) : {}
  if (!response.ok) {
    throw new Error(parsed?.detail?.message ?? parsed?.detail ?? parsed?.error ?? response.statusText)
  }
  return parsed
}

export function extractFinalText(payload: Record<string, unknown> | undefined): string {
  const value = firstNonEmpty(
    payload?.result_text,
    payload?.result,
    payload?.text,
    payload?.final_text,
    payload?.message
  )
  return value || 'Execution completed, but no final text was captured.'
}

function firstNonEmpty(...values: unknown[]): string {
  for (const value of values) {
    const text = value === undefined || value === null ? '' : String(value).trim()
    if (text) return text
  }
  return ''
}

function stableTurnId(input: ExecuteInput): string {
  const source = input.eventId || input.delivery.reply_to_event_id || input.threadKey
  let hash = 0x811c9dc5
  for (let i = 0; i < source.length; i += 1) {
    hash ^= source.charCodeAt(i)
    hash = Math.imul(hash, 0x01000193)
  }
  return `matrix-${(hash >>> 0).toString(16).padStart(8, '0')}`
}
