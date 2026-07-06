<!-- lean-ctx-owned: PROJECT-LEAN-CTX.md v1 -->
<!-- lean-ctx-rules -->
<!-- version: 1 -->

CRITICAL: ALWAYS use lean-ctx tools instead of native equivalents. This is NOT optional.

MANDATORY MAPPING:
• Read/cat -> ctx_read(path, mode)
• Glob/find -> ctx_glob(pattern)
• Shell/bash -> ctx_shell(command)
• Grep -> ctx_search(pattern, path)
• ls/find -> ctx_tree(path, depth)

NEVER use native Read/Grep/Shell/Glob when ctx_* equivalents are available.

Tool selection by intent:
• Understand code / find answers / before editing -> ctx_compose (call FIRST)
• Read a file -> ctx_read(path, mode=signatures|map|full)
• Find a symbol by name (exact) -> ctx_symbol
• Search code by pattern (fuzzy) -> ctx_search
• Search by meaning (concepts) -> ctx_semantic_search
• Find files by pattern (glob) -> ctx_glob
• Project structure -> ctx_tree
• Who calls this / call graph -> ctx_callgraph
• Session state / memory -> ctx_session / ctx_knowledge

Anti-patterns — do NOT:
• Chain ctx_search -> ctx_read -> ctx_symbol — one ctx_compose replaces all three
• Grep for symbol definitions — ctx_symbol is faster + more precise
• Use ctx_read(mode=full) for orientation — use mode=signatures
• Use ctx_callgraph or ctx_graph for const/static/variable references — they track
function call edges and file-level deps only. Use grep or ctx_compose instead

PARALLEL tool calls: fire independent calls in the SAME turn — don't sequence them.
One turn with 5 parallel ctx_read calls completes faster than 5 sequential turns.
ctx_compose bundles multiple lookups into one call; for anything it doesn't
cover, batch independent reads/searches together.

Auto: preload/dedup/compress run in background. ctx_session=memory, ctx_knowledge=facts, ctx_semantic_search=meaning search, ctx_shell raw=true=uncompressed. Details: LEAN-CTX.md

CEP v1: 1.ACT FIRST 2.DELTA ONLY (Fn refs) 3.STRUCTURED (+/-/~) 4.ONE LINE PER ACTION 5.QUALITY ANCHOR

OUTPUT: never echo tool output, no narration comments, show only changed code.

TOOL PREFERENCE (END): ctx_compose>chain ctx_read>Read ctx_shell>Shell ctx_search>Grep ctx_glob>Glob ctx_tree>ls | Edit/Write/Delete=native
OUTPUT STYLE: concise
- Bullet points over paragraphs
- Skip filler words and hedging ("I think", "probably", "it seems")
- 1-sentence explanations max, then code/action
- No repeating what the user said
<!-- /lean-ctx-rules -->
