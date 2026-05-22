import { startMatrixSyncLoop } from './bot'
import { loadConfig } from './config'
import { startFinalDeliveryPoller } from './final-delivery'
import { logError, logInfo } from './logging'

const config = loadConfig()

startMatrixSyncLoop(config)
startFinalDeliveryPoller(config)

Bun.serve({
  port: config.port,
  fetch(request) {
    const path = new URL(request.url).pathname
    if (path === '/health' || path === '/health/ready') {
      return Response.json({
        ok: true,
        service: 'matrixbot',
        commit: process.env.COMMIT_SHA ?? 'local'
      })
    }
    return Response.json({ ok: false, error: 'not_found' }, { status: 404 })
  },
  error(error) {
    logError('http_server_error', error)
    return Response.json({ ok: false, error: 'internal_error' }, { status: 500 })
  }
})

logInfo('matrixbot_started', {
  port: config.port,
  homeserver: config.matrixHomeserverUrl,
  user_id: config.matrixUserId,
  harness: config.matrixDefaultHarness
})
