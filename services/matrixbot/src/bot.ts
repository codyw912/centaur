import { executeAgent } from './centaur'
import type { AppConfig } from './config'
import { logError, logInfo } from './logging'
import {
  joinedTimelineEvents,
  normalizeMatrixMessage,
  sync,
  type MatrixSyncResponse,
  type NormalizedMatrixMessage
} from './matrix'
import { createSyncState, loadSyncToken, rememberEvent, saveSyncToken, type SyncState } from './sync-state'

export function startMatrixSyncLoop(config: AppConfig): void {
  let state = createSyncState()

  const tick = async () => {
    try {
      if (!state.initialized) state = createSyncState(await loadSyncToken(config.matrixSyncTokenPath))
      const response = await sync(config, state.since)
      state.since = response.next_batch || state.since
      await saveSyncToken(config.matrixSyncTokenPath, state.since)

      const messages = messagesFromSyncResponse(config, state, response)
      if (!state.initialized && !config.matrixProcessInitialSync) {
        state.initialized = true
        logInfo('matrix_initial_sync_skipped', { event_count: joinedTimelineEvents(response).length })
        return
      }
      state.initialized = true

      for (const message of messages) {
        await executeAgent(config, {
          threadKey: message.threadKey,
          eventId: message.eventId,
          message: message.text,
          harness: config.matrixDefaultHarness,
          delivery: {
            platform: 'matrix',
            room_id: message.roomId,
            thread_root_event_id: message.threadRootEventId,
            reply_to_event_id: message.eventId,
            sender: message.sender
          },
          metadata: {
            matrix: {
              room_id: message.roomId,
              event_id: message.eventId,
              sender: message.sender
            }
          }
        })
        logInfo('matrix_message_enqueued', {
          room_id: message.roomId,
          event_id: message.eventId,
          thread_key: message.threadKey
        })
      }
    } catch (error) {
      logError('matrix_sync_failed', error)
    } finally {
      setTimeout(tick, config.matrixPollIntervalMs).unref?.()
    }
  }

  void tick()
}

export function messagesFromSyncResponse(
  config: Pick<AppConfig, 'matrixUserId' | 'matrixAllowedRooms'>,
  state: SyncState,
  response: MatrixSyncResponse
): NormalizedMatrixMessage[] {
  const messages: NormalizedMatrixMessage[] = []
  for (const event of joinedTimelineEvents(response)) {
    const message = normalizeMatrixMessage(event, config)
    if (!message) continue
    if (!isAllowedRoom(config, message.roomId)) {
      logInfo('matrix_room_ignored', { room_id: message.roomId, event_id: message.eventId })
      continue
    }
    if (!rememberEvent(state, message.eventId)) {
      logInfo('matrix_event_duplicate_ignored', {
        room_id: message.roomId,
        event_id: message.eventId
      })
      continue
    }
    messages.push(message)
  }
  return messages
}

function isAllowedRoom(config: Pick<AppConfig, 'matrixAllowedRooms'>, roomId: string): boolean {
  return config.matrixAllowedRooms.size === 0 || config.matrixAllowedRooms.has(roomId)
}
