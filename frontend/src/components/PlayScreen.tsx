import { useCallback, useEffect, useRef, useState } from 'react'
import { api, subscribeToRun } from '../api'
import type { LiveState, Notice, Run } from '../types'
import { Icon } from './icons'
import { MetricChart } from './MetricChart'
import { SystemMap } from './SystemMap'
import { Terminal, type TerminalHandle } from './Terminal'

const TICK_MS = 4000
type Tab = 'map' | 'terminal' | 'steps' | 'alerts'
type DrawerTab = 'terminal' | 'logs'

interface Props {
  run: Run
  onExit: () => void
  onNext?: () => void
}

export function PlayScreen({ run, onExit, onNext }: Props) {
  const [live, setLive] = useState<LiveState>(run)
  const [busy, setBusy] = useState(false)
  const [hintShown, setHintShown] = useState(false)
  const [tab, setTab] = useState<Tab>('map')
  const [drawer, setDrawer] = useState<DrawerTab>('terminal')
  const [logService, setLogService] = useState<string | null>(null)
  const [flash, setFlash] = useState<string | null>(null)
  const term = useRef<TerminalHandle>(null)
  const scenario = run.scenario
  const metric = scenario.focus_metric
  const threshold = metric === 'disk' ? 90 : 85

  const showNotices = useCallback((notices: Notice[]) => {
    notices.forEach((n) => term.current?.print(n.text, n.kind === 'resolved' ? 'green' : 'amber'))
  }, [])

  const celebrate = (completed: { title: string }[]) => {
    if (!completed.length) return
    completed.forEach((c) => term.current?.print(`✓ ${c.title}`, 'green'))
    setFlash(completed.at(-1)!.title)
    setHintShown(false)
    window.setTimeout(() => setFlash(null), 2600)
  }

  useEffect(() => subscribeToRun(run.id, setLive), [run.id])

  // Time keeps moving while the player reads, so incidents evolve.
  useEffect(() => {
    if (live.status === 'completed') return
    const timer = window.setInterval(async () => {
      if (document.hidden || busy) return
      try {
        const step = await api.tick(run.id)
        setLive(step)
        showNotices(step.notices)
        celebrate(step.completed)
      } catch { /* the next tick will try again */ }
    }, TICK_MS)
    return () => window.clearInterval(timer)
  })

  const runCommand = useCallback(async (input: string) => {
    setBusy(true)
    try {
      const step = await api.command(run.id, input)
      // The server's `clear` sends screen-reset escapes; the terminal already handled it.
      // oxlint-disable-next-line no-control-regex
      if (step.output && !/^\s*clear\s*$/.test(input)) term.current?.print(step.output.replace(/\x1b\[[0-9;]*[HJ]/g, ''))
      showNotices(step.notices)
      setLive(step)
      celebrate(step.completed)
    } catch {
      term.current?.print('Lost connection to the simulator. Is the Rails server running?', 'red')
    } finally {
      setBusy(false)
    }
  }, [run.id, showNotices])

  const inspect = (command: string) => {
    setDrawer('terminal')
    setTab('terminal')
    term.current?.suggest(command)
  }

  const objectives = live.objectives
  const doneCount = objectives.filter((o) => o.done).length
  const current = objectives.find((o) => !o.done)
  const firing = live.alerts.filter((a) => a.state === 'firing')
  const points = live.metrics['web-01'] ?? []
  const now = points.at(-1)?.[metric] ?? 0
  const hotService = live.map.nodes.find((n) => n.status !== 'ok' && live.logs[n.id])?.id
  const shownLogs = logService ?? hotService ?? 'shop-web'

  return (
    <div className="play" data-tab={tab}>
      <header className="play-top rise">
        <button type="button" className="icon-btn" onClick={onExit} aria-label="Back to chapters"><Icon name="back" /></button>
        <span className="logo" aria-hidden="true" />
        <div className="titles">
          <h1>{scenario.title}</h1>
          <p className="sub">Chapter {scenario.chapter} · {scenario.topic} · <span className="mono">{live.time}</span></p>
        </div>
        {firing.length > 0
          ? <span className="chip warn"><i />{firing[0].id} firing</span>
          : <span className="chip ok"><i />All quiet</span>}
      </header>

      <div className="stage">
        <div className="pane pane-map rise" style={{ animationDelay: '60ms' }}>
          <SystemMap nodes={live.map.nodes} edges={live.map.edges} onInspect={inspect} />
            <section className="card gauge pane-alerts">
              <span className="eyebrow">{metric === 'disk' ? 'Disk' : 'Memory'} · web-01</span>
              <div className={`metric ${now >= threshold ? 'bad' : now >= threshold - 10 ? 'warn' : 'ok'}`}>{now}%</div>
              <MetricChart points={points} metric={metric} threshold={threshold} />
              <ul className="alerts">
                {live.alerts.length === 0 && <li className="muted">No alerts yet.</li>}
                {live.alerts.slice(-3).reverse().map((a) => (
                  <li key={`${a.id}-${a.fired_at}`} className={a.state}>
                    <i /><span><b>{a.id}</b> {a.summary}</span>
                  </li>
                ))}
              </ul>
            </section>
        </div>

        <aside className="side">
          <section className="card quest pane-steps rise" style={{ animationDelay: '120ms' }} aria-live="polite">
            {live.status === 'completed' ? (
              <>
                <span className="eyebrow">Chapter complete</span>
                <h2>You fixed it, and it stays fixed.</h2>
                <p className="muted">All {objectives.length} steps done in {live.clock} minutes of simulated time.</p>
                <div className="row">
                  {onNext && <button type="button" className="btn primary" onClick={onNext}><Icon name="play" />Next chapter</button>}
                  <button type="button" className="btn ghost" onClick={onExit}>All chapters</button>
                </div>
              </>
            ) : (
              <>
                <span className="eyebrow">Step {doneCount + 1} of {objectives.length}</span>
                <div className="dots" aria-hidden="true">
                  {objectives.map((o, i) => <i key={o.id} className={o.done ? 'done' : i === doneCount ? 'current' : ''} />)}
                </div>
                <h2>{current?.title}</h2>
                {hintShown && live.hint && <p className="hint">{live.hint}</p>}
                <div className="row">
                  <button type="button" className="btn primary" onClick={() => setHintShown((v) => !v)} aria-expanded={hintShown}>
                    <Icon name="bulb" />{hintShown ? 'Hide the hint' : 'Show a hint'}
                  </button>
                </div>
              </>
            )}
            <ol className="steps">
              {objectives.map((o, i) => (
                <li key={o.id} className={o.done ? 'done' : i === doneCount ? 'current' : ''}>
                  <span className="tick">{o.done ? <Icon name="check" size={12} /> : i + 1}</span>{o.title}
                </li>
              ))}
            </ol>
          </section>

        </aside>
      </div>

      <section className="drawer pane-terminal rise" style={{ animationDelay: '240ms' }}>
        <div className="drawer-bar" role="tablist" aria-label="Terminal and logs">
          <button type="button" role="tab" aria-selected={drawer === 'terminal'} className={drawer === 'terminal' ? 'on' : ''} onClick={() => setDrawer('terminal')}>Terminal</button>
          <button type="button" role="tab" aria-selected={drawer === 'logs'} className={drawer === 'logs' ? 'on' : ''} onClick={() => setDrawer('logs')}>Logs</button>
          <span className="where mono">{live.prompt.replace(/[$#]$/, '')}</span>
        </div>
        <div className="drawer-body" hidden={drawer !== 'terminal'}>
          <Terminal ref={term} prompt={live.prompt} onCommand={runCommand} busy={busy}
            intro={scenario.briefing.trim() + "\nType help for a list of commands, or click a box on the map."} />
        </div>
        {drawer === 'logs' && (
          <div className="logs">
            <div className="log-pick">
              {Object.keys(live.logs).map((name) => (
                <button key={name} type="button" className={name === shownLogs ? 'on' : ''} onClick={() => setLogService(name)}>{name}</button>
              ))}
            </div>
            <pre>{(live.logs[shownLogs] ?? []).slice(-30).join('\n') || 'No log lines yet.'}</pre>
          </div>
        )}
      </section>

      {flash && <div className="toast" role="status"><Icon name="check" />{flash}</div>}

      <nav className="dock" aria-label="Sections">
        {([['map', 'Map', 'map'], ['terminal', 'Terminal', 'term'], ['steps', 'Steps', 'list'], ['alerts', 'Alerts', 'bell']] as const).map(([id, label, icon]) => (
          <button key={id} type="button" className={tab === id ? 'on' : ''} onClick={() => { setTab(id); if (id === 'terminal') window.setTimeout(() => term.current?.focus(), 50) }}>
            <Icon name={icon} />{label}
          </button>
        ))}
      </nav>
    </div>
  )
}
