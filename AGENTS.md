# Worklight development

This is an independent macOS app repository. Other folders in the parent workspace are monitored projects, not part of this codebase.

- Keep the dashboard accessible through words and symbols as well as color.
- Never automatically pull, push, stage, commit, stash, reset, or terminate other apps.
- Keep Git and process collection off the main thread.
- Preserve explicit confirmations for pulling and quitting.
- Test Git behavior with temporary repositories, never by modifying neighboring projects.
- Run `swift build` and `.build/debug/Worklight --self-test` after changes affecting behavior.
- Avoid dependencies and continuous high-frequency polling.
