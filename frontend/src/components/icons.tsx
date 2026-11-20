// Simple stroke icons (no emoji as icons).
const paths: Record<string, string> = {
  bulb: 'M9 18h6M10 21h4M12 3a6 6 0 0 0-3.5 10.9c.6.5 1 1.2 1 2.1h5c0-.9.4-1.6 1-2.1A6 6 0 0 0 12 3z',
  term: 'M4 17l6-5-6-5M12 19h8',
  list: 'M9 6h11M9 12h11M9 18h11M4 6h.01M4 12h.01M4 18h.01',
  bell: 'M6 16V11a6 6 0 1 1 12 0v5l2 2H4zM10 21h4',
  map: 'M7 7l4 9M17 7l-4 9M7.5 6h9M5 8.5a2.5 2.5 0 1 0 0-5 2.5 2.5 0 0 0 0 5zM19 8.5a2.5 2.5 0 1 0 0-5 2.5 2.5 0 0 0 0 5zM12 20.5a2.5 2.5 0 1 0 0-5 2.5 2.5 0 0 0 0 5z',
  back: 'M15 18l-6-6 6-6',
  moon: 'M20 14.5A8 8 0 0 1 9.5 4a8 8 0 1 0 10.5 10.5z',
  sun: 'M12 16a4 4 0 1 0 0-8 4 4 0 0 0 0 8zM12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4',
  check: 'M5 12.5l4.5 4.5L19 7.5',
  lock: 'M5 11h14v9H5zM8 11V8a4 4 0 0 1 8 0v3',
  play: 'M7 5l12 7-12 7z',
}

export function Icon({ name, size = 18 }: { name: keyof typeof paths | string; size?: number }) {
  return (
    <svg className="icon" width={size} height={size} viewBox="0 0 24 24" aria-hidden="true">
      <path d={paths[name]} />
    </svg>
  )
}
