# Plugin lists

A plugin list is one JSON file at a URL, naming plugins for Browse (`B` on
hako's screen) to show. The official list is
[masshirodev/ranma-plugins](https://github.com/masshirodev/ranma-plugins)
(`plugins.json`), reviewed before a plugin goes on it. Anyone can publish
another (a file in a repository, a gist, any URL `curl` can fetch), and anyone
can add it to their Browse with `a`.

## The format

```json
{
  "format": 1,
  "name": "kenji's plugins",
  "plugins": [
    {
      "repo": "kenji/tidy.ranma",
      "description": "Closes panes whose program exited, a minute after it did.",
      "author": "kenji",
      "tags": ["panes"],
      "needs": ["git"],
      "ranma": "0.1.0"
    }
  ]
}
```

| Field | | |
| --- | --- | --- |
| `format` | required | `1`. A list in a newer format is refused with "update hako", not read in part. |
| `name` | required | What Browse calls the list ("from kenji's plugins"). |
| `plugins` | required | The plugins, in any order (Browse sorts them by name). |
| `repo` | required | `owner/repo` on GitHub, or an `https://` (or `file://`) URL. It is what `i` installs, and what makes two mentions of a plugin, in two lists, one plugin. The plugin's name is its last part (`tidy.ranma`), as in a spec. |
| `description` | required | One or two sentences. The first line is shown beside the name on a wide screen. |
| `author` | | Who keeps it. Default: the `owner` of `owner/repo`. |
| `tags` | | Words to filter by (`/#git`). Lowercase, one word each. |
| `needs` | | Programs it needs outside ranma (`"kizuna"`, `"nvim"`). Said in its detail; nothing checks them. |
| `ranma` | | The oldest ranma it works with (`"0.2.0"`). An older ranma shows it under *Needs a newer ranma* and does not install it. |

Read strictly, as everything in ranma is: an unknown field, a missing one, a
wrong type or a plugin listed twice refuses the whole list, naming the field
and the plugin (`plugins[3] (kenji/tidy.ranma): unknown field \`stars\``).
Browse shows the error on the list's row and keeps the last copy that read.

## What hako does with lists

- **Which lists**: `hako-lists.json` beside the lockfile (or `setup`'s
  `lists = "…"`), written only when you add, turn off or remove one. Without
  it, Browse has the official list alone. Point it into your dotfiles to give
  another machine the same lists.
- **Fetching**: `curl -fsSL --max-time 10`, in the background. When Browse
  opens, the lists older than `hako.check_hours` (6) are fetched again; `C`
  fetches all of them now. A fetch that fails keeps the last good copy, which
  Browse uses and says how old it is.
- **The copies**: `<root>/.lists/`, in the data directory.
- **Adding** (`a`): the URL is fetched and read first; nothing is added until
  you have seen its name and size, and, for any list but the official one,
  answered `y` to a warning that nobody reviews it.
- **Installing** (`i`): what `hako add owner/repo` does, with the spec file
  saying which list it came from (`-- written by hako, from ranma plugins`).
  From there it is a plugin like any other; removing its list does not remove
  it, and it updates from its own repository.

## Getting a plugin on the official list

A pull request to
[masshirodev/ranma-plugins](https://github.com/masshirodev/ranma-plugins)
adding its entry. That repository's README says what review means, and its CI
checks the file with hako's own reader and loads every plugin into the latest
ranma release.
