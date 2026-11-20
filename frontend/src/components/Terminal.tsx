import { FitAddon } from '@xterm/addon-fit'
import { Terminal as XTerm } from '@xterm/xterm'
import '@xterm/xterm/css/xterm.css'
import { forwardRef, useEffect, useImperativeHandle, useRef } from 'react'

export interface TerminalHandle {
  /** Print text (with \n line breaks) above the prompt, keeping what the player is typing. */
  print: (text: string, color?: 'amber' | 'green' | 'muted' | 'red') => void
  /** Put a command on the prompt line without running it, so the player can read it first. */
  suggest: (command: string) => void
  focus: () => void
}

interface Props {
  prompt: string
  onCommand: (input: string) => Promise<void>
  busy: boolean
  /** Shown once when the terminal opens, like a message of the day. */
  intro?: string
}

const COLORS = { amber: '\x1b[38;2;255;181;71m', green: '\x1b[38;2;75;227;161m', muted: '\x1b[38;2;142;137;176m', red: '\x1b[38;2;255;143;166m' }
const RESET = '\x1b[0m'

// A small line editor on top of xterm.js: typing, backspace, left/right,
// history with up/down, Ctrl+C, Ctrl+L and paste. Commands go to the server.
export const Terminal = forwardRef<TerminalHandle, Props>(function Terminal({ prompt, onCommand, busy, intro }, ref) {
  const host = useRef<HTMLDivElement>(null)
  const term = useRef<XTerm | null>(null)
  const state = useRef({ line: '', cursor: 0, history: [] as string[], historyIndex: -1, prompt, busy, onCommand })
  state.current.prompt = prompt
  state.current.busy = busy
  state.current.onCommand = onCommand

  const promptText = () => `${COLORS.green}${state.current.prompt}${RESET} `

  const drawnRows = useRef(0)
  const redrawLine = () => {
    const t = term.current
    if (!t) return
    const s = state.current
    // Long input wraps over several rows; go back to the first one before redrawing.
    const up = drawnRows.current > 0 ? `\x1b[${drawnRows.current}A` : ''
    t.write(up + '\r\x1b[J' + promptText() + s.line)
    drawnRows.current = Math.floor((s.prompt.length + 1 + s.line.length) / Math.max(t.cols, 1))
    const back = s.line.length - s.cursor
    if (back > 0) t.write(`\x1b[${back}D`)
  }

  useImperativeHandle(ref, () => ({
    print(text, color) {
      const t = term.current
      if (!t || !text) return
      const body = text.replace(/\r?\n/g, '\r\n')
      const up = drawnRows.current > 0 ? `\x1b[${drawnRows.current}A` : ''
      drawnRows.current = 0
      t.write(up + '\r\x1b[J' + (color ? COLORS[color] + body + RESET : body) + '\r\n')
      if (!state.current.busy) redrawLine()
    },
    suggest(command) {
      state.current.line = command
      state.current.cursor = command.length
      redrawLine()
      term.current?.focus()
    },
    focus: () => term.current?.focus(),
  }))

  useEffect(() => {
    const t = new XTerm({
      fontFamily: '"Geist Mono", ui-monospace, monospace',
      fontSize: 13,
      lineHeight: 1.35,
      cursorBlink: true,
      convertEol: false,
      scrollback: 2000,
      theme: {
        background: '#08070F', foreground: '#C8C3E6', cursor: '#EEEAFB', selectionBackground: '#3A3466',
        green: '#4BE3A1', yellow: '#FFB547', red: '#FF8FA6', blue: '#8B7BFF', brightBlack: '#8E89B0',
      },
    })
    const fit = new FitAddon()
    t.loadAddon(fit)
    t.open(host.current!)
    term.current = t
    // Only fit while visible: on phones the terminal is display:none on other tabs,
    // and fitting to a zero-size box would rewrap the prompt into fragments.
    const resize = new ResizeObserver(() => {
      if (!host.current?.offsetWidth) return
      const dims = fit.proposeDimensions()
      if (dims && (dims.cols !== t.cols || dims.rows !== t.rows)) fit.fit()
    })
    resize.observe(host.current!)
    t.onResize(() => redrawLine())
    if (intro) t.write(COLORS.muted + intro.replace(/\r?\n/g, '\r\n') + RESET + '\r\n\r\n')
    redrawLine()

    const submit = async () => {
      const s = state.current
      const input = s.line
      t.write('\r\n')
      drawnRows.current = 0
      s.line = ''
      s.cursor = 0
      s.historyIndex = -1
      if (input.trim()) {
        if (s.history[0] !== input) s.history.unshift(input)
        s.history.length = Math.min(s.history.length, 100)
        if (/^\s*clear\s*$/.test(input)) { t.clear(); drawnRows.current = 0 }
        await s.onCommand(input)
      }
      redrawLine()
    }

    const insert = (text: string) => {
      const s = state.current
      s.line = s.line.slice(0, s.cursor) + text + s.line.slice(s.cursor)
      s.cursor += text.length
      redrawLine()
    }

    const disposable = t.onData((data) => {
      const s = state.current
      if (s.busy) return
      switch (data) {
        case '\r': void submit(); return
        case '\x7f': case '\b':
          if (s.cursor > 0) { s.line = s.line.slice(0, s.cursor - 1) + s.line.slice(s.cursor); s.cursor--; redrawLine() }
          return
        case '\x03': t.write('^C\r\n'); drawnRows.current = 0; s.line = ''; s.cursor = 0; redrawLine(); return
        case '\x0c': t.clear(); drawnRows.current = 0; redrawLine(); return
        case '\x1b[A':
          if (s.historyIndex < s.history.length - 1) { s.historyIndex++; s.line = s.history[s.historyIndex]; s.cursor = s.line.length; redrawLine() }
          return
        case '\x1b[B':
          if (s.historyIndex >= 0) { s.historyIndex--; s.line = s.historyIndex < 0 ? '' : s.history[s.historyIndex]; s.cursor = s.line.length; redrawLine() }
          return
        case '\x1b[D': if (s.cursor > 0) { s.cursor--; t.write(data) } return
        case '\x1b[C': if (s.cursor < s.line.length) { s.cursor++; t.write(data) } return
        case '\x1b[H': case '\x01': s.cursor = 0; redrawLine(); return
        case '\x1b[F': case '\x05': s.cursor = s.line.length; redrawLine(); return
      }
      if (data.startsWith('\x1b')) return
      // Typed characters or a paste: take the first line, run it if a newline came with it.
      const [first, ...rest] = data.split(/\r\n|\r|\n/)
      // oxlint-disable-next-line no-control-regex
      insert(first.replace(/[\x00-\x1f]/g, ''))
      if (rest.length) void submit()
    })

    return () => { disposable.dispose(); resize.disconnect(); t.dispose() }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  useEffect(() => { if (!busy) redrawLine() }, [prompt, busy])

  return <div className="xterm-host" ref={host} aria-label="Terminal. Type a command and press Enter." />
})
