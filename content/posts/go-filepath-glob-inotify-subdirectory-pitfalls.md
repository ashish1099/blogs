---
title: "Two Go stdlib traps when watching and scanning JSON files on Linux"
date: 2026-03-16
tags: ["go", "golang", "inotify", "fsnotify", "filepath", "linux", "gotchas"]
categories: ["development"]
---

Two bugs surfaced during a CEO-plan audit of the vuls-exporter codebase that are easy to introduce and silent enough to survive code review. Both involve standard-library primitives that look correct but fail quietly on Linux.

## The bugs at a glance

1. `filepath.Glob("**/*.json")` does not recurse on Linux — it matches nothing in subdirectories and returns `nil, nil`.
2. Raw `unix.InotifyAddWatch` does not automatically watch new subdirectories — any directory created after the watch is set up is silently ignored.

## Bug 1: filepath.Glob does not support `**`

The code looked like this:

```go
files, err := filepath.Glob(filepath.Join(dir, "**/*.json"))
```

This returns no error and an empty slice when the JSON files are in subdirectories. Go's `filepath.Glob` does not implement `**` globbing — the double-star is treated as a literal pattern component, and on Linux it simply never matches a directory name. The Go documentation does not call this out prominently, so it passes review.

The fix is `filepath.WalkDir`:

```go
var files []string
err := filepath.WalkDir(dir, func(path string, d fs.DirEntry, err error) error {
    if err != nil {
        return err
    }
    if !d.IsDir() && strings.HasSuffix(path, ".json") {
        files = append(files, path)
    }
    return nil
})
```

This recurses correctly and surfaces real errors rather than swallowing them.

## Bug 2: raw inotify does not watch new subdirectories

The original watcher called `unix.InotifyAddWatch` once at startup for the top-level results directory. This works until a scan run creates a new subdirectory (which vuls does per-host). The kernel inotify watch on the parent fires an `IN_CREATE` event for the new directory, but there is no watch on the directory itself — so any JSON files written inside it are invisible to the watcher.

The fix is to replace the raw inotify calls with `github.com/fsnotify/fsnotify` and add watches for new directories as they are created:

```go
watcher, _ := fsnotify.NewWatcher()
watcher.Add(root)

go func() {
    for event := range watcher.Events {
        if event.Has(fsnotify.Create) {
            if info, err := os.Stat(event.Name); err == nil && info.IsDir() {
                watcher.Add(event.Name)  // watch the new subdir immediately
            }
        }
        if event.Has(fsnotify.Write) && strings.HasSuffix(event.Name, ".json") {
            // process the file
        }
    }
}()
```

fsnotify abstracts over inotify on Linux and kqueue on macOS, and the recursive-watch pattern above is idiomatic.

## Other hardening applied in the same pass

While the two bugs above were the critical items, the same review turned up a few more patterns worth noting:

- **Last-error-only accumulation.** A loop was overwriting a single `err` variable, so only the last failure was reported. `errors.Join()` (Go 1.20+) collects all errors and is a one-line fix.
- **Unbounded API error reads.** `ioutil.ReadAll(resp.Body)` on an error response from an external API has no upper bound. Wrapping the body with `io.LimitReader(r, 4096)` before reading keeps a misbehaving server from allocating arbitrary memory.
- **Hard-coded HTTP timeout.** The client timeout was a magic-number constant. Moving it to the config struct costs nothing and makes integration tests easier to write.

## Key takeaways

| Trap | Symptom | Fix |
|---|---|---|
| `filepath.Glob("**/*.json")` | Empty results, no error | `filepath.WalkDir` |
| `unix.InotifyAddWatch` on static dir | New subdir files ignored | `fsnotify` + recursive add-on-create |
| Single `err` in accumulation loop | Only last error visible | `errors.Join()` |
| `ioutil.ReadAll` on error body | Potential OOM from bad server | `io.LimitReader` |

All four are the kind of bug that a unit test against a flat directory will miss — they only surface in production where directory structures are dynamic and error paths are real.
