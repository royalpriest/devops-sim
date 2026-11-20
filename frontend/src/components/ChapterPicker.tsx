import type { ScenarioSummary } from '../types'
import { Icon } from './icons'

// The story has five chapters; the ones without a scenario yet show as coming soon.
const STORY = [
  { chapter: 1, topic: 'GitHub', title: 'Open your first pull request', teaser: 'Branch, commit and open a PR for a small feature.' },
  { chapter: 2, topic: 'CI', title: 'The build is red', teaser: 'Read the CI logs and fix the failing test.' },
  { chapter: 3, topic: 'Deploy', title: 'Roll back a bad release', teaser: 'A release breaks the site. Roll it back, fast.' },
  { chapter: 4, topic: 'Linux', title: 'The disk is full', teaser: '' },
  { chapter: 5, topic: 'Monitoring', title: 'Memory is climbing', teaser: '' },
]

interface Props {
  scenarios: ScenarioSummary[]
  starting: string | null
  onStart: (key: string) => void
}

export function ChapterPicker({ scenarios, starting, onStart }: Props) {
  return (
    <main className="picker">
      <header className="picker-head rise">
        <span className="logo big" aria-hidden="true" />
        <p className="eyebrow">DevOps Simulator</p>
        <h1>Learn on-call by fixing a shop that keeps breaking.</h1>
        <p className="lede">A real-feeling terminal, live dashboards and a server that misbehaves. Nothing is real, so you can't break anything.</p>
      </header>
      <ol className="chapters">
        {STORY.map((ch, i) => {
          const scenario = scenarios.find((s) => s.chapter === ch.chapter)
          return (
            <li key={ch.chapter} className={`card chapter rise ${scenario ? '' : 'soon'}`} style={{ animationDelay: `${80 * (i + 1)}ms` }}>
              <span className="chapter-n mono">0{ch.chapter}</span>
              <div className="chapter-text">
                <span className="eyebrow">{ch.topic}</span>
                <h2>{scenario?.title ?? ch.title}</h2>
                <p className="muted">{scenario?.summary ?? ch.teaser}</p>
              </div>
              {scenario ? (
                <button type="button" className="btn primary" disabled={starting !== null} onClick={() => onStart(scenario.key)}>
                  <Icon name="play" />{starting === scenario.key ? 'Starting…' : 'Start chapter'}
                </button>
              ) : (
                <span className="chip soon"><Icon name="lock" size={14} />Coming soon</span>
              )}
            </li>
          )
        })}
      </ol>
    </main>
  )
}
