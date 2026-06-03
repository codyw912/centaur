import { afterEach, describe, expect, it } from 'bun:test'
import { pollFinalDeliveriesOnce } from './final-delivery'
import type { AppConfig } from './config'

const originalFetch = globalThis.fetch

afterEach(() => {
  globalThis.fetch = originalFetch
})

describe('pollFinalDeliveriesOnce', () => {
  it('sends Matrix text and marks the delivery delivered', async () => {
    const calls: Array<{ host: string; path: string; method: string; body: any }> = []
    globalThis.fetch = (async (url: URL | RequestInfo, init?: RequestInit) => {
      const parsedUrl = new URL(String(url))
      const body = init?.body ? JSON.parse(String(init.body)) : undefined
      calls.push({ host: parsedUrl.host, path: parsedUrl.pathname, method: init?.method ?? 'GET', body })

      if (parsedUrl.pathname === '/agent/final-deliveries/claim') {
        return Response.json({
          deliveries: [
            {
              execution_id: 'exe_1',
              thread_key: 'matrix:room:event',
              delivery: {
                platform: 'matrix',
                room_id: '!room:example.com',
                thread_root_event_id: '$root',
                reply_to_event_id: '$event'
              },
              final_payload: { result_text: 'PONG' }
            }
          ]
        })
      }
      if (parsedUrl.pathname.includes('/send/m.room.message/')) {
        return Response.json({ event_id: '$reply' })
      }
      if (parsedUrl.pathname === '/agent/final-deliveries/exe_1/delivered') {
        return Response.json({ ok: true })
      }
      return Response.json({ error: 'unexpected' }, { status: 404 })
    }) as typeof fetch

    await pollFinalDeliveriesOnce(config())

    expect(calls.map(call => call.path)).toEqual([
      '/agent/final-deliveries/claim',
      '/_matrix/client/v3/rooms/!room%3Aexample.com/send/m.room.message/centaur-exe_1-final',
      '/agent/final-deliveries/exe_1/delivered'
    ])
    expect(calls[1]!.body).toMatchObject({
      msgtype: 'm.text',
      body: 'PONG',
      'm.relates_to': {
        rel_type: 'm.thread',
        event_id: '$root',
        'm.in_reply_to': { event_id: '$event' }
      }
    })
  })

  it('marks delivery failed when Matrix send fails', async () => {
    const calls: Array<{ path: string; body: any }> = []
    globalThis.fetch = (async (url: URL | RequestInfo, init?: RequestInit) => {
      const parsedUrl = new URL(String(url))
      const body = init?.body ? JSON.parse(String(init.body)) : undefined
      calls.push({ path: parsedUrl.pathname, body })

      if (parsedUrl.pathname === '/agent/final-deliveries/claim') {
        return Response.json({
          deliveries: [
            {
              execution_id: 'exe_2',
              thread_key: 'matrix:room:event',
              delivery: { platform: 'matrix', room_id: '!room:example.com' },
              final_payload: { result_text: 'PONG' }
            }
          ]
        })
      }
      if (parsedUrl.pathname.includes('/send/m.room.message/')) {
        return Response.json({ error: 'forbidden' }, { status: 403 })
      }
      if (parsedUrl.pathname === '/agent/final-deliveries/exe_2/failed') {
        return Response.json({ ok: true })
      }
      return Response.json({ error: 'unexpected' }, { status: 404 })
    }) as typeof fetch

    await pollFinalDeliveriesOnce(config())

    const failed = calls.find(call => call.path === '/agent/final-deliveries/exe_2/failed')
    expect(failed?.body.error).toBe('forbidden')
    expect(failed?.body.retry_after_seconds).toBe(10)
  })

  it('marks delivery failed when Matrix delivery metadata lacks a room', async () => {
    const calls: Array<{ path: string; body: any }> = []
    globalThis.fetch = (async (url: URL | RequestInfo, init?: RequestInit) => {
      const parsedUrl = new URL(String(url))
      const body = init?.body ? JSON.parse(String(init.body)) : undefined
      calls.push({ path: parsedUrl.pathname, body })

      if (parsedUrl.pathname === '/agent/final-deliveries/claim') {
        return Response.json({
          deliveries: [
            {
              execution_id: 'exe_3',
              thread_key: 'matrix:room:event',
              delivery: { platform: 'matrix' },
              final_payload: { result_text: 'PONG' }
            }
          ]
        })
      }
      if (parsedUrl.pathname === '/agent/final-deliveries/exe_3/failed') {
        return Response.json({ ok: true })
      }
      return Response.json({ error: 'unexpected' }, { status: 404 })
    }) as typeof fetch

    await pollFinalDeliveriesOnce(config())

    expect(calls.map(call => call.path)).toEqual([
      '/agent/final-deliveries/claim',
      '/agent/final-deliveries/exe_3/failed'
    ])
    expect(calls[1]!.body.error).toBe('missing_matrix_delivery_room')
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
