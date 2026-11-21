export type Status = 'ok' | 'warn' | 'bad'

export interface ScenarioSummary {
  key: string
  title: string
  topic: string
  chapter: number
  summary: string
  focus_metric: Metric | null
}

export type Metric = 'memory' | 'disk' | 'errors'

export interface RealWorld { text: string; source_title: string; source_url: string }

export interface Objective { id: string; title: string; done: boolean }

export interface Alert {
  id: string
  state: 'firing' | 'resolved'
  severity: string
  summary: string
  fired_at: number
  acknowledged: boolean
}

export interface MetricPoint { t: number; memory: number; disk: number; cpu: number; errors: number }

export interface MapNode {
  id: string
  label: string
  kind: string
  host: string
  status: Status
  detail: string
  level?: number
  inspect?: string
  pos?: [number, number]
  pos_narrow?: [number, number]
}

export interface Notice { kind: 'alert' | 'resolved' | string; text: string }

export interface LiveState {
  id: number
  status: 'active' | 'completed'
  clock: number
  time: string
  prompt: string
  objectives: Objective[]
  alerts: Alert[]
  metrics: Record<string, MetricPoint[]>
  services: Record<string, Record<string, string>>
  current_host: string
  hint: string | null
  map: { nodes: MapNode[]; edges: [string, string][] }
  logs: Record<string, string[]>
}

export interface Run extends LiveState {
  scenario: ScenarioSummary & { briefing: string; real_world: RealWorld | null }
}

export interface Step extends LiveState {
  type: 'step'
  output: string
  exit_code: number
  notices: Notice[]
  completed: { id: string; title: string }[]
}
