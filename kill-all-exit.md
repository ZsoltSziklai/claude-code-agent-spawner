---
description: Kill ALL background agents (worktree drop) and exit this main session
---

Hard shutdown: minden agent kill + parent claude session exit. **Nincs confirm picker** — a parancs neve elég explicit.

Egyetlen Bash hívás csinál mindent:

```bash
~/.claude/agent-queue/bin/agent-kill-all.sh
```

A script:
1. Listázza az `agent-*` tmux session-öket
2. Mindegyikre `agent-kill-one.sh` (tmux kill + worktree drop)
3. Process-fán felfelé keresi a parent `claude --remote-control`-t
4. TERM-mel próbálja → 1 mp múlva KILL-lel ha még él

A Bash outputja:
- `"killed: <NAME>"` minden agentre
- `"all agents killed ($COUNT)"`
- `"shutting down parent pid X..."` vagy `"no parent claude found — manual /exit needed"`

Jelentés a usernek magyarul a Bash output alapján. Ne hívj több toolt.
