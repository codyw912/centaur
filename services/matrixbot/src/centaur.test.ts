import { afterEach, describe, expect, it } from 'bun:test'
import { executeAgent, extractFinalText } from './centaur'
import type { AppConfig } from './config'

const originalFetch = globalThis.fetch

afterEach(() => {
  globalThis.fetch = originalFetch
})

describe('extractFinalText', () => {
  it('uses the first non-empty final payload field', () => {
    expect(extractFinalText({ result_text: '', final_text: 'done' })).toBe('done')
  })

  it('returns a fallback when no text was captured', () => {
    expect(extractFinalText({})).toContain('Execution completed')
  })
})

describe('executeAgent', () => {
  it('runs the durable spawn, message, execute sequence', async () => {
    const calls: Array<{ path: string; body: any }> = []
    globalThis.fetch = (async (url: URL | RequestInfo, init?: RequestInit) => {
      const path = new URL(String(url)).pathname
      const body = JSON.parse(String(init?.body ?? '{}'))
      calls.push({ path, body })

      if (path === '/agent/spawn') {
        return Response.json({
          thread_key: body.thread_key,
          assignment_generation: 7,
          state: 'assigned_idle'
        })
      }
      if (path === '/agent/message') {
        return Response.json({ ok: true, message_id: body.message_id })
      }
      if (path === '/agent/execute') {
        return Response.json({ ok: true, execution_id: body.execute_id, status: 'queued' })
      }
      return Response.json({ error: 'unexpected' }, { status: 404 })
    }) as typeof fetch

    await executeAgent(config(), {
      threadKey: 'matrix:room:event',
      eventId: '$event',
      message: 'hello',
      harness: 'claude-code',
      delivery: {
        platform: 'matrix',
        room_id: '!room:localhost',
        thread_root_event_id: '$event',
        reply_to_event_id: '$event',
        sender: '@alice:localhost'
      },
      metadata: { matrix: { room_id: '!room:localhost', event_id: '$event' } }
    })

    expect(calls.map(call => call.path)).toEqual([
      '/agent/spawn',
      '/agent/message',
      '/agent/execute'
    ])
    const spawnCall = calls[0]!
    const messageCall = calls[1]!
    const executeCall = calls[2]!
    expect(spawnCall.body).toMatchObject({
      thread_key: 'matrix:room:event',
      harness: 'claude-code'
    })
    expect(messageCall.body).toMatchObject({
      thread_key: 'matrix:room:event',
      assignment_generation: 7,
      role: 'user',
      user_id: '@alice:localhost',
      parts: [{ type: 'text', text: 'hello' }]
    })
    expect(executeCall.body).toMatchObject({
      thread_key: 'matrix:room:event',
      assignment_generation: 7,
      harness: 'claude-code',
      delivery: { platform: 'matrix', room_id: '!room:localhost' }
    })
    expect(spawnCall.body.spawn_id).toStartWith('spawn-matrix-')
    expect(messageCall.body.message_id).toBe(spawnCall.body.spawn_id.replace('spawn-', 'msg-'))
    expect(executeCall.body.execute_id).toBe(spawnCall.body.spawn_id.replace('spawn-', 'exec-'))
  })
})

function config(): AppConfig {
  return {
    nodeEnv: 'test',
    port: 3002,
    matrixHomeserverUrl: 'http://matrix.local',
    matrixAccessToken: 'matrix-token',
    matrixUserId: '@centaur:localhost',
    matrixDeviceId: 'device',
    matrixDefaultHarness: 'claude-code',
    matrixProcessInitialSync: false,
    matrixSyncTimeoutMs: 1000,
    matrixPollIntervalMs: 1000,
    matrixAllowedRooms: new Set(),
    centaurApiUrl: 'http://centaur.local',
    centaurApiKey: 'api-key'
  }
}
