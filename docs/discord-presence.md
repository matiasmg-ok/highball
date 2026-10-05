# Discord game activity on macOS

Highball automatically shares Windows games with Discord for Mac while both apps
are open. The integration is always active and has no Highball setting or toggle.
Discord's own Activity Privacy settings control whether friends see the activity.

* **Basic presence:** Highball scans only processes in its Windows environments,
  including games opened in Steam's window, other launchers, and external Steam
  libraries. It resolves the game's Discord application ID from Discord's public
  detection catalog and publishes the game's name and elapsed time through local
  IPC. Steam IDs take precedence over titles; executable names are accepted only
  when unambiguous. No Highball application ID or Discord account token is required.
* **Rich Presence pass-through:** a small Windows helper creates
  `\\.\pipe\discord-ipc-0` through `discord-ipc-9` in each running environment. It
  connects to a native loopback listener authenticated with a per-run random token.
  Highball relays framed messages and replies to Discord's Unix socket, replacing
  Windows PIDs with Highball's macOS PID. Application IDs, assets, details, party
  data, join secrets, subscriptions, and events retain the original game's values.
  This forwards RPC; it does not implement an overlay or launch/join protocol handlers.

A game's own Rich Presence takes priority over basic presence. Basic presence
resumes after the richer connection ends. With multiple games running, Highball
keeps its selected basic activity until that game closes, then picks the newest
recognised game. Games absent from Discord's catalog cannot receive basic presence;
Rich Presence pass-through remains available for those games.

The catalog endpoint (`https://discord.com/api/v10/applications/detectable`) is
public but undocumented and can change. The last valid catalog is cached as
`discord-games.json` in Highball's data directory, refreshed weekly when a game and
Discord are running. Failed requests are retried at most hourly. Game titles,
process arguments, and account tokens are not sent in this request. An unavailable
catalog or Discord client never prevents a game launch.

Highball attaches to existing running prefixes within five seconds of opening.
Quitting Highball closes the IPC connections and ends its Windows helpers,
including when Windows programs are left running. The helpers run in `drive_c/windows`, so they count as plumbing for
Highball's idle-prefix and renderer restart rules. No service, LaunchAgent, engine
patch, or replacement Discord DLL is installed.

## Local build and validation

```sh
Scripts/make-app.sh debug 0.10.7-discord-local
open dist/Highball.app
```

The Windows helper is built from `spike/discord-bridge/main.c` with mingw-w64 and
bundled as `Contents/Resources/highball-discord-bridge.exe`. Release builds require
mingw-w64; debug builds warn when it is absent (basic presence still works).
Bare `swift run HighballApp` builds can find the helper under `spike/discord-bridge`
when run from the repository root; run its `build.sh` first.

```sh
swift test --filter DiscordPresenceTests
spike/discord-bridge/build.sh
x86_64-w64-mingw32-gcc -O2 -Wall -Wextra -Werror -static -s \
  -o spike/discord-bridge/probe.exe spike/discord-bridge/probe.c
HIGHBALL_DISCORD_SMOKE_ENGINE="/path/to/installed/Highball/engine" \
  swift test --filter DiscordPresenceTests/testWineNamedPipeSmokeWhenRequested
```

Tests use a fake Discord Unix socket and publish nothing to the user's Discord.
The optional Wine smoke boots a throwaway prefix with an installed engine, exercises
fragmented SDK frames on slots 0 and 9, checks native PID translation and bidirectional
replies, shuts down the bridge, verifies the helper exits, and repeats after restarting it.

For the final visual check, open Discord for Mac, enable activity sharing, and start
Geometry Dash in Highball or in its Windows Steam client. Check that Discord shows
**Playing Geometry Dash** and clears it after quitting the game. Repeat with a game
that has its own Rich Presence and restart Discord while playing. Also quit and
reopen Highball while leaving a game running; its activity should resume automatically.

Protocol reference: https://github.com/discord/discord-rpc/blob/master/documentation/hard-mode.md
