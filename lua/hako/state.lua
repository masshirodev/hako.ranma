-- What hako knows in this configuration: one table, shared by its modules.
-- It starts over on every reload, as ranma's Lua does; what must outlive
-- that (update counts, the last check, a task's failure) is in
-- ranma.store("hako").
return {
  plugins = {},
  by_name = {},
  spec_errors = {},
  imports = {},
  lock = {},
  -- name -> what its task is doing now: { task, frac, since, tail }.
  tasks = {},
  -- name -> how its task in this run ended: { text, role }.
  results = {},
  -- The run going now: { op, total, done, failed }, or nil.
  run = nil,
}
