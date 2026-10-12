# Brief: browsing plugins, and plugin lists (hako)

For Claude Design. Repositories, both public:

- <https://github.com/masshirodev/hako.ranma>, where this is built. Read
  `doc/SCREEN.md` (the screen this extends, and where it departs from its
  handoff), `doc/DESIGN.md` and `README.md` ("Using it").
- <https://github.com/masshirodev/ranma>, which draws every screen. Read
  `doc/handoffs/PLUGIN_MANAGER.md` with `PLUGIN_MANAGER_MOCK.txt` and
  `PLUGIN_MANAGER_screen.js` (the earlier handoff for hako's screen: match
  its look), `doc/CONFIG.md` ("Screens": the blocks a screen is made of) and
  `assets/ranma.d.lua` (the whole Lua API).

Nothing in this brief is built.

## The problem

ranma is extended by Lua plugins, the way Neovim is, and hako is its plugin
manager. hako already installs anything you name: `a` on its screen, or
`hako add owner/repo`. But you have to know the name. Neovim gets away with
that because its plugins are everywhere: blog posts, dotfiles, awesome-lists.
ranma is new and nobody has written those yet, so a new user has no idea
plugins exist, let alone which ones.

So hako gets a way to **browse** plugins and install one with a key, fed by
**plugin lists**: JSON files at a URL, like Dalamud's plugin repositories (the
plugin installer of the FFXIV launcher, if you know it). There is one official
list. Anyone can publish another, and a user can add it.

## What ranma is, briefly

A tiling window manager inside a terminal. Everything is **terminal cells**:
characters with a foreground, a background and bold, dim, italic, underline
or reverse. No pixels and no images (so no screenshots of plugins), no
animation. A plugin's screen floats on the right of the workspace and is
made of blocks ranma draws (headings, rows with a value and keys, a detail
area under the list, text, facts, progress, a log); the plugin never places
a cell. hako's screen is one of these.

## What to design

**A Browse view in hako's screen**, beside the current one (the installed
plugins in sections). One key flips between them, or whatever reads better.
It shows the plugins of every list the user has turned on:

- each plugin's name, a one-line description, and whether it is
  **installed**, **declared but not installed**, or **not here at all**
- the selected one's detail: the longer description, its author, its
  repository, its tags, what it **needs** outside ranma (agents.ranma needs
  kizuna; openpath needs nvim and yazi by default), the oldest ranma it works
  with, and **which list it came from**
- install it with one key (`i`, as in the other view). Installing writes its
  spec file and clones it, which is what `a` does today; the result shows on
  the row as it happens, the way the other view's meters do
- a way to narrow a list of maybe a hundred plugins: the screen's filter
  (`/`) matches names today; tags (`git`, `ai`, `ui`, `navigation`...) are
  the other obvious handle

**Managing the lists**, in the screen too:

- the lists the user has, the official one first: their names, how many
  plugins each has, when each was last fetched, and whether that worked
- add one by URL (a typed line, as `a` asks for `owner/repo` today), turn one
  off, remove one. The official list can be turned off but not removed
- **adding a list that is not the official one asks first**, the way
  Dalamud warns: a plugin is Lua that can run any program as you, and only
  the official list is looked at by anyone. The ask should say that plainly
  and need a deliberate answer (`y`, as hako's deleting asks do)

## States to draw

- the first time Browse opens, while the lists are being fetched
- a list that could not be fetched: show the copy from last time, saying how
  old it is; with no copy, say so on that list
- a plugin in two lists (the official one and someone else's): one row, both
  lists in its detail
- a plugin that needs a newer ranma than the one running: visible, but it
  says so and does not install
- a plugin from a non-official list: is that marked on its row, or only in
  the detail?
- nothing matches the filter
- every list turned off

## Words

The UI says **Browse** and **plugin lists** (or "lists"). No Japanese words
in the UI: `hako` and `ranma` are names, but a word the user has to read to
understand what something does should be plain English.

## Questions for you

- Where Browse sits in hako's screen, and the key that gets there.
- Whether the lists are a section of Browse, or a view of their own.
- How much a row says before you select it (author? tags? the list?).
- Whether a plugin that is already installed stays in Browse (marked) or
  leaves it.
- What the warning on adding a list says, word for word.

## Not part of this

- Ratings, download counts, comments, screenshots. A list says only what is
  in its file.
- Publishing: how someone gets a plugin onto the official list is a pull
  request to that list's repository, not a screen.
- Updating and removing plugins stay in the existing view.

## For reference: a list's file

A first draft, so the design knows what it has to show. Each list is one
JSON file at a URL, fetched with curl:

```json
{
  "name": "ranma plugins",
  "plugins": [
    {
      "repo": "masshirodev/history.ranma",
      "name": "history",
      "description": "Search a pane's scrollback by regex and jump to a match.",
      "author": "masshirodev",
      "tags": ["search", "scrollback"],
      "needs": [],
      "ranma": "0.1.0"
    }
  ]
}
```
