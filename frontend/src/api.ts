import { createConsumer } from '@rails/actioncable'
import type { LiveState, Run, ScenarioSummary, Step } from './types'

async function request<T>(path: string, body?: unknown): Promise<T> {
  const res = await fetch(`/api${path}`, {
    method: body === undefined ? 'GET' : 'POST',
    headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  })
  if (!res.ok) throw new Error(`${res.status} ${res.statusText}`)
  return res.json() as Promise<T>
}

export const api = {
  scenarios: () => request<ScenarioSummary[]>('/scenarios'),
  start: (scenario: string) => request<Run>('/runs', { scenario }),
  run: (id: number) => request<Run>(`/runs/${id}`),
  command: (id: number, input: string) => request<Step>(`/runs/${id}/commands`, { input }),
  tick: (id: number) => request<Step>(`/runs/${id}/tick`, { ticks: 1 }),
}

let consumer: ReturnType<typeof createConsumer> | null = null

// Live panel updates (map, metrics, alerts). Terminal output always comes from
// the HTTP response, so a missing socket never loses anything.
export function subscribeToRun(id: number, onState: (state: LiveState) => void) {
  consumer ??= createConsumer('/cable')
  const sub = consumer.subscriptions.create(
    { channel: 'RunChannel', run_id: id },
    { received: (data: LiveState) => onState(data) },
  )
  return () => { sub.unsubscribe() }
}
