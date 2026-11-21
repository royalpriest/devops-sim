import type { Metric, MetricPoint } from '../types'

interface Props {
  points: MetricPoint[]
  metric: Metric
  threshold: number
}

// Area chart of the last few minutes, with the alert line drawn in.
export function MetricChart({ points, metric, threshold }: Props) {
  const data = points.slice(-40).map((p) => p[metric])
  if (data.length < 2) data.unshift(data[0] ?? 0)
  const w = 300, h = 96
  const step = w / (data.length - 1)
  const y = (v: number) => h - (v / 100) * h
  const line = 'M' + data.map((v, i) => `${(i * step).toFixed(1)},${y(v).toFixed(1)}`).join(' L')
  const now = data.at(-1) ?? 0
  const warnAt = metric === 'errors' ? 2 : threshold - 10
  const tone = now >= threshold ? 'var(--bad)' : now >= warnAt ? 'var(--warn)' : 'var(--ok)'

  return (
    <svg className="chart" viewBox={`0 0 ${w} ${h}`} role="img" aria-label={`${metric} over the last ${data.length} minutes, now ${now} percent`}>
      <defs>
        <linearGradient id={`fill-${metric}`} x1="0" x2="0" y1="0" y2="1">
          <stop offset="0" stopColor={tone} stopOpacity=".28" />
          <stop offset="1" stopColor={tone} stopOpacity="0" />
        </linearGradient>
      </defs>
      {[25, 50, 75].map((v) => <line key={v} x1="0" x2={w} y1={y(v)} y2={y(v)} className="gridline" />)}
      <line x1="0" x2={w} y1={y(threshold)} y2={y(threshold)} stroke={tone} strokeDasharray="3 5" opacity=".75" />
      <text x={w - 2} y={y(threshold) - 6} textAnchor="end" className="chart-label" fill={tone}>ALERT {threshold}%</text>
      <path d={`${line} L${w},${h} L0,${h} Z`} fill={`url(#fill-${metric})`} />
      <path d={line} fill="none" stroke={tone} strokeWidth="2.2" strokeLinejoin="round" />
      <circle cx={w} cy={y(now)} r="4" fill={tone} />
    </svg>
  )
}
