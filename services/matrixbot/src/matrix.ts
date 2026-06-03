import type { AppConfig } from './config'

export type MatrixEvent = {
  type?: string
  event_id?: string
  sender?: string
  room_id?: string
  content?: Record<string, unknown>
}

export type NormalizedMatrixMessage = {
  roomId: string
  eventId: string
  sender: string
  text: string
  threadRootEventId: string
  replyToEventId?: string
  threadKey: string
}

export type MatrixSyncResponse = {
  next_batch?: string
  rooms?: {
    join?: Record<
      string,
      {
        timeline?: {
          events?: MatrixEvent[]
        }
      }
    >
  }
}

export async function matrixRequest(
  config: AppConfig,
  method: string,
  path: string,
  body?: unknown
): Promise<any> {
  const response = await fetch(new URL(path, config.matrixHomeserverUrl), {
    method,
    headers: {
      Authorization: `Bearer ${config.matrixAccessToken}`,
      ...(body === undefined ? {} : { 'Content-Type': 'application/json' })
    },
    body: body === undefined ? undefined : JSON.stringify(body)
  })
  const text = await response.text()
  const parsed = text ? JSON.parse(text) : {}
  if (!response.ok) {
    throw new Error(parsed?.error ?? response.statusText)
  }
  return parsed
}

export async function sync(config: AppConfig, since?: string): Promise<MatrixSyncResponse> {
  const params = new URLSearchParams({
    timeout: String(config.matrixSyncTimeoutMs),
    set_presence: 'offline'
  })
  if (since) params.set('since', since)
  return matrixRequest(config, 'GET', `/_matrix/client/v3/sync?${params.toString()}`)
}

export async function sendTextMessage(
  config: AppConfig,
  opts: {
    roomId: string
    body: string
    txnId: string
    threadRootEventId?: string
    replyToEventId?: string
  }
): Promise<unknown> {
  const content: Record<string, unknown> = {
    msgtype: 'm.text',
    body: opts.body
  }
  if (opts.threadRootEventId) {
    content['m.relates_to'] = {
      rel_type: 'm.thread',
      event_id: opts.threadRootEventId,
      is_falling_back: true,
      'm.in_reply_to': {
        event_id: opts.replyToEventId || opts.threadRootEventId
      }
    }
  }
  return matrixRequest(
    config,
    'PUT',
    `/_matrix/client/v3/rooms/${encodeURIComponent(opts.roomId)}/send/m.room.message/${encodeURIComponent(
      opts.txnId
    )}`,
    content
  )
}

export function joinedTimelineEvents(response: MatrixSyncResponse): MatrixEvent[] {
  const joined = response.rooms?.join ?? {}
  const events: MatrixEvent[] = []
  for (const [roomId, room] of Object.entries(joined)) {
    for (const event of room.timeline?.events ?? []) {
      events.push({ ...event, room_id: event.room_id || roomId })
    }
  }
  return events
}

export function normalizeMatrixMessage(
  event: MatrixEvent,
  config: Pick<AppConfig, 'matrixUserId'>
): NormalizedMatrixMessage | null {
  if (event.type !== 'm.room.message') return null
  const roomId = clean(event.room_id)
  const eventId = clean(event.event_id)
  const sender = clean(event.sender)
  if (!roomId || !eventId || !sender || sender === config.matrixUserId) return null

  const content = event.content ?? {}
  if (clean(content.msgtype) !== 'm.text') return null

  const body = clean(content.body)
  if (!body || !mentionsBot(content, body, config.matrixUserId)) return null

  const threadRootEventId = threadRoot(content) || eventId
  const replyToEventId = replyTo(content)
  return {
    roomId,
    eventId,
    sender,
    text: stripMention(body, config.matrixUserId),
    threadRootEventId,
    replyToEventId,
    threadKey: matrixThreadKey(roomId, threadRootEventId)
  }
}

export function matrixThreadKey(roomId: string, threadRootEventId: string): string {
  return `matrix:${encodeURIComponent(roomId)}:${encodeURIComponent(threadRootEventId)}`
}

function mentionsBot(content: Record<string, unknown>, body: string, userId: string): boolean {
  const mentions = content['m.mentions']
  if (mentions && typeof mentions === 'object' && !Array.isArray(mentions)) {
    const userIds = (mentions as Record<string, unknown>).user_ids
    if (Array.isArray(userIds) && userIds.includes(userId)) return true
  }
  return body.includes(userId)
}

function stripMention(body: string, userId: string): string {
  return body.replaceAll(userId, '').trim()
}

function threadRoot(content: Record<string, unknown>): string | null {
  const relatesTo = relation(content)
  if (clean(relatesTo?.rel_type) === 'm.thread') return clean(relatesTo?.event_id) || null
  return null
}

function replyTo(content: Record<string, unknown>): string | undefined {
  const relatesTo = relation(content)
  const reply = relatesTo?.['m.in_reply_to']
  if (!reply || typeof reply !== 'object' || Array.isArray(reply)) return undefined
  return clean((reply as Record<string, unknown>).event_id) || undefined
}

function relation(content: Record<string, unknown>): Record<string, unknown> | null {
  const relatesTo = content['m.relates_to']
  if (!relatesTo || typeof relatesTo !== 'object' || Array.isArray(relatesTo)) return null
  return relatesTo as Record<string, unknown>
}

function clean(value: unknown): string {
  return typeof value === 'string' ? value.trim() : ''
}
