import { useEffect, useState } from 'react'
import type { MapNode } from '../types'

// Where each part of the shop sits on the map, in % of the map's box.
const WIDE: Record<string, [number, number]> = {
  laptop: [12, 22], nginx: [35, 22], 'shop-web': [60, 22], disk: [86, 22], 'shop-worker': [60, 66], postgresql: [86, 66],
}
const NARROW: Record<string, [number, number]> = {
  laptop: [26, 9], nginx: [74, 9], 'shop-web': [26, 37], 'shop-worker': [74, 64], postgresql: [26, 91], disk: [74, 37],
}

function useNarrow(query = '(max-width: 720px)') {
  const [narrow, setNarrow] = useState(() => window.matchMedia(query).matches)
  useEffect(() => {
    const mq = window.matchMedia(query)
    const on = () => setNarrow(mq.matches)
    mq.addEventListener('change', on)
    return () => mq.removeEventListener('change', on)
  }, [query])
  return narrow
}

interface Props {
  nodes: MapNode[]
  edges: [string, string][]
  onInspect: (command: string) => void
}

export function SystemMap({ nodes, edges, onInspect }: Props) {
  const narrow = useNarrow()
  // Scenarios can place their own boxes; otherwise use the shop server layout.
  const layout: Record<string, [number, number]> = Object.fromEntries(nodes.map((n) => {
    const own = narrow ? n.pos_narrow : n.pos
    return [n.id, own ?? (narrow ? NARROW : WIDE)[n.id] ?? [50, 50]]
  }))
  const byId = Object.fromEntries(nodes.map((n) => [n.id, n]))

  return (
    <section className="map" aria-label="Map of the shop's system">
      <svg className="wires" viewBox="0 0 100 100" preserveAspectRatio="none" aria-hidden="true">
        {edges.map(([a, b]) => {
          const [x1, y1] = layout[a] ?? [0, 0]
          const [x2, y2] = layout[b] ?? [0, 0]
          const trouble = byId[a]?.status !== 'ok' || byId[b]?.status !== 'ok'
          return <line key={`${a}-${b}`} x1={x1} y1={y1} x2={x2} y2={y2} className={trouble ? 'wire hot' : 'wire'} vectorEffect="non-scaling-stroke" />
        })}
      </svg>
      {nodes.map((node) => {
        const [x, y] = layout[node.id]
        return (
          <button
            key={node.id}
            type="button"
            className={`node ${node.status}`}
            style={{ left: `${x}%`, top: `${y}%` }}
            onClick={() => node.inspect && onInspect(node.inspect)}
            aria-label={`${node.label}, ${node.kind}: ${node.detail}. Put an inspect command in the terminal.`}
          >
            <span className="node-kind">{node.host} · {node.kind}</span>
            <span className="node-name">{node.label}</span>
            <span className="node-status"><i />{node.detail}</span>
            {node.level !== undefined && node.status !== 'ok' && node.status !== 'bad' && (
              <span className="node-bar"><i style={{ width: `${Math.min(node.level * 2, 100)}%` }} /></span>
            )}
          </button>
        )
      })}
      <p className="map-legend">Click a box to put a command for it in the terminal. Lines show who talks to whom.</p>
    </section>
  )
}
