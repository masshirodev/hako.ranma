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
  -- The operation running now ("update", ...), or nil; one at a time.
  busy = nil,
  -- name -> what its task is doing now.
  tasks = {},
}
