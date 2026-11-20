import { useEffect, useState } from 'react'
import { api } from './api'
import { ChapterPicker } from './components/ChapterPicker'
import { Icon } from './components/icons'
import { PlayScreen } from './components/PlayScreen'
import type { Run, ScenarioSummary } from './types'

type Theme = 'light' | 'dark'

function initialTheme(): Theme {
  const saved = localStorage.getItem('theme')
  if (saved === 'light' || saved === 'dark') return saved
  return window.matchMedia('(prefers-color-scheme: light)').matches ? 'light' : 'dark'
}

// The run id lives in the URL hash (#/run/12) so a reload picks up where you were.
const runIdFromHash = () => Number(location.hash.match(/^#\/run\/(\d+)/)?.[1]) || null

export default function App() {
  const [scenarios, setScenarios] = useState<ScenarioSummary[]>([])
  const [run, setRun] = useState<Run | null>(null)
  const [starting, setStarting] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [theme, setTheme] = useState<Theme>(initialTheme)

  useEffect(() => {
    document.documentElement.dataset.theme = theme
    localStorage.setItem('theme', theme)
  }, [theme])

  useEffect(() => {
    api.scenarios().then(setScenarios).catch(() => setError('Could not reach the simulator API. Start it with `bin/rails server` in backend/.'))
    const id = runIdFromHash()
    if (id) api.run(id).then(setRun).catch(() => { location.hash = '' })
    const onHash = () => { if (!runIdFromHash()) setRun(null) }
    window.addEventListener('hashchange', onHash)
    return () => window.removeEventListener('hashchange', onHash)
  }, [])

  const start = async (key: string) => {
    setStarting(key)
    try {
      const next = await api.start(key)
      location.hash = `#/run/${next.id}`
      setRun(next)
    } catch {
      setError('Could not start that chapter. Is the Rails server running?')
    } finally {
      setStarting(null)
    }
  }

  const next = run && scenarios.find((s) => s.chapter > run.scenario.chapter)

  return (
    <>
      <button type="button" className="theme-toggle icon-btn" onClick={() => setTheme(theme === 'dark' ? 'light' : 'dark')}
        aria-label={theme === 'dark' ? 'Switch to light theme' : 'Switch to dark theme'}>
        <Icon name={theme === 'dark' ? 'sun' : 'moon'} />
      </button>
      {error && <p className="banner" role="alert">{error}</p>}
      {run
        ? <PlayScreen key={run.id} run={run} onExit={() => { location.hash = '' }} onNext={next ? () => void start(next.key) : undefined} />
        : <ChapterPicker scenarios={scenarios} starting={starting} onStart={(k) => void start(k)} />}
    </>
  )
}
