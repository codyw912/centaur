import {
  claimFinalDeliveries,
  extractFinalText,
  markFinalDelivered,
  markFinalFailed,
  type FinalDelivery
} from './centaur'
import type { AppConfig } from './config'
import { logError } from './logging'
import { sendTextMessage } from './matrix'

export function startFinalDeliveryPoller(config: AppConfig): void {
  if (!config.centaurApiKey) return
  const tick = async () => {
    try {
      await pollFinalDeliveriesOnce(config)
    } catch (error) {
      logError('final_delivery_poll_failed', error)
    }
  }
  setInterval(tick, 2_000).unref?.()
  void tick()
}

export async function pollFinalDeliveriesOnce(config: AppConfig): Promise<void> {
  const deliveries = await claimFinalDeliveries(config)
  for (const delivery of deliveries) {
    try {
      await deliver(config, delivery)
      await markFinalDelivered(config, String(delivery.execution_id))
    } catch (error) {
      await markFinalFailed(config, String(delivery.execution_id), error).catch(failError =>
        logError('final_delivery_mark_failed_failed', failError)
      )
    }
  }
}

async function deliver(config: AppConfig, delivery: FinalDelivery): Promise<void> {
  const meta = delivery.delivery
  if (!meta?.room_id) throw new Error('missing_matrix_delivery_room')
  await sendTextMessage(config, {
    roomId: meta.room_id,
    body: extractFinalText(delivery.final_payload),
    txnId: `centaur-${delivery.execution_id}-final`,
    threadRootEventId: meta.thread_root_event_id,
    replyToEventId: meta.reply_to_event_id
  })
}
