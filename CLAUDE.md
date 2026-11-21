# Notes for Claude

## Commits and pull requests
- No `Co-Authored-By: Claude`, `Claude-Session:` or other Claude attribution lines in commit messages.
- No "Generated with Claude Code" or similar footers in pull request descriptions or comments.
- No "claude" in branch names. Use short descriptive names such as `feat/scenario-engine` or `fix/terminal-scroll`.
- Only Royal merges. Never force-push without asking.

## Project
- Browser-based DevOps simulator for beginners. Everything is simulated; nothing runs real commands.
- `backend/`: Rails 8.1 API-only app (SQLite, Action Cable). The engine lives in `backend/lib/sim/`:
  `world.rb` (state), `shell.rb` (command interpreter), `engine.rb` (time + objectives),
  `scenarios/*.rb` (one chapter each, listed in `scenarios.rb`). Delivery chapters use `repo.rb` (fake git),
  `delivery_commands.rb` (git, gh, bin/rails test, deploy), `delivery_ci.rb` and `delivery_world.rb`.
- `frontend/`: React + TypeScript (Vite), xterm.js terminal. Play screen is `src/components/PlayScreen.tsx`.
- UI follows Royal's UI style rules (motion, accessibility). Type: Space Grotesk headings, Geist body, JetBrains Mono for terminal and labels, with this app's own "System map" theme in
  `frontend/src/styles.css`. Don't reuse the helpdesk look (dark sidebar + blue pill).

## Checks before opening a pull request
- `cd backend && bin/rails test && bin/rubocop && bin/brakeman --no-pager`
- `cd frontend && npm run lint && npm run build`
