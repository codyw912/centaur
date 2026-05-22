import { describe, expect, it } from 'bun:test'
import { mkdtemp, readFile, rm } from 'node:fs/promises'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { messagesFromSyncResponse } from './bot'
import { matrixThreadKey, normalizeMatrixMessage } from './matrix'
import { createSyncState, loadSyncToken, saveSyncToken } from './sync-state'

const config = { matrixUserId: '@centaur:example.com', matrixAllowedRooms: new Set<string>() }

describe('normalizeMatrixMessage', () => {
  it('normalizes text events that explicitly mention the bot', () => {
    const message = normalizeMatrixMessage(
      {
        type: 'm.room.message',
        room_id: '!room:example.com',
        event_id: '$event',
        sender: '@alice:example.com',
        content: {
          msgtype: 'm.text',
          body: '@centaur:example.com reply with pong',
          'm.mentions': { user_ids: ['@centaur:example.com'] }
        }
      },
      config
    )

    expect(message).toEqual({
      roomId: '!room:example.com',
      eventId: '$event',
      sender: '@alice:example.com',
      text: 'reply with pong',
      threadRootEventId: '$event',
      replyToEventId: undefined,
      threadKey: matrixThreadKey('!room:example.com', '$event')
    })
  })

  it('uses Matrix thread relations when present', () => {
    const message = normalizeMatrixMessage(
      {
        type: 'm.room.message',
        room_id: '!room:example.com',
        event_id: '$reply',
        sender: '@alice:example.com',
        content: {
          msgtype: 'm.text',
          body: 'question for @centaur:example.com',
          'm.relates_to': {
            rel_type: 'm.thread',
            event_id: '$root',
            'm.in_reply_to': { event_id: '$previous' }
          }
        }
      },
      config
    )

    expect(message?.threadRootEventId).toBe('$root')
    expect(message?.replyToEventId).toBe('$previous')
    expect(message?.threadKey).toBe(matrixThreadKey('!room:example.com', '$root'))
  })

  it('ignores messages from the bot user', () => {
    const message = normalizeMatrixMessage(
      {
        type: 'm.room.message',
        room_id: '!room:example.com',
        event_id: '$event',
        sender: '@centaur:example.com',
        content: {
          msgtype: 'm.text',
          body: '@centaur:example.com loop'
        }
      },
      config
    )

    expect(message).toBeNull()
  })
})

describe('messagesFromSyncResponse', () => {
  it('filters rooms outside the allowlist', () => {
    const state = createSyncState('token')
    const messages = messagesFromSyncResponse(
      { matrixUserId: config.matrixUserId, matrixAllowedRooms: new Set(['!allowed:example.com']) },
      state,
      {
        rooms: {
          join: {
            '!denied:example.com': {
              timeline: {
                events: [
                  {
                    type: 'm.room.message',
                    event_id: '$denied',
                    sender: '@alice:example.com',
                    content: {
                      msgtype: 'm.text',
                      body: '@centaur:example.com should not run'
                    }
                  }
                ]
              }
            }
          }
        }
      }
    )

    expect(messages).toEqual([])
  })

  it('suppresses duplicate event IDs within the running process', () => {
    const state = createSyncState('token')
    const response = {
      rooms: {
        join: {
          '!room:example.com': {
            timeline: {
              events: [
                {
                  type: 'm.room.message',
                  event_id: '$event',
                  sender: '@alice:example.com',
                  content: {
                    msgtype: 'm.text',
                    body: '@centaur:example.com run once'
                  }
                }
              ]
            }
          }
        }
      }
    }

    expect(messagesFromSyncResponse(config, state, response)).toHaveLength(1)
    expect(messagesFromSyncResponse(config, state, response)).toHaveLength(0)
  })
})

describe('sync token persistence', () => {
  it('round-trips the sync token through an atomic file write', async () => {
    const dir = await mkdtemp(join(tmpdir(), 'matrixbot-sync-'))
    const path = join(dir, 'sync-token')
    try {
      await saveSyncToken(path, 's123')
      expect(await readFile(path, 'utf8')).toBe('s123\n')
      expect(await loadSyncToken(path)).toBe('s123')
    } finally {
      await rm(dir, { recursive: true, force: true })
    }
  })

  it('treats a missing sync token file as no token', async () => {
    expect(await loadSyncToken('/tmp/centaur-matrixbot-missing-token')).toBeUndefined()
  })
})
