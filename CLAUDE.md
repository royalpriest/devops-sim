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
  `scenarios/*.rb` (one chapter each, listed in `scenarios.rb`).
- `frontend/`: React + TypeScript (Vite).
- UI follows Royal's UI style (Geist, product-mode tokens).

## Checks before opening a pull request
- `cd backend && bin/rails test && bin/rubocop && bin/brakeman --no-pager`
