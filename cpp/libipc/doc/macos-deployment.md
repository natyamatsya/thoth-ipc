<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors -->

# macOS Deployment & Distribution

This document covers the macOS-specific restrictions that affect process
spawning, shared memory, and signal handling — and how to handle them when
shipping a product built on cpp-ipc.

## Process Spawning Restrictions

The orchestration layer (`process_manager.h`, `service_group.h`) uses:

- **`posix_spawn()`** to launch service processes
- **`kill(SIGTERM)` / `kill(SIGKILL)`** for graceful and forced shutdown
- **`waitpid()`** to reap child processes
- **`kill(pid, 0)`** for liveness checks

These POSIX APIs work without restriction on macOS **unless** the app runs in
the App Sandbox.

### App Sandbox

Apps distributed through the **Mac App Store** must enable the App Sandbox
entitlement. A sandboxed app **cannot**:

- Spawn arbitrary child processes via `posix_spawn()` or `fork()`/`exec()`
- Send signals to other processes
- Access shared memory created outside its sandbox container

If App Store distribution is required, see [Alternative: XPC + LaunchAgent](#alternative-xpc--launchagent) below.

### Hardened Runtime

Apps signed for **notarization** (required for non-App-Store distribution)
run with Hardened Runtime enabled. This does **not** block `posix_spawn()`,
signals, or shared memory. Relevant entitlements:

Entitlement | When needed
------------|------------
`com.apple.security.cs.allow-unsigned-executable-memory` | Only if spawned service uses JIT
`com.apple.security.cs.disable-library-validation` | Only if loading unsigned dylibs

For a typical cpp-ipc deployment, **no special entitlements are needed** —
just sign and notarize.

## Shared Memory

`shm_open()` on macOS creates kernel-backed shared memory objects. Key points:

- Accessible to all processes running as the **same user**
- macOS enforces a **30-character name limit** (`PSHMNAMLEN`) including the
  leading `/` — the library already hashes long names to fit
  (see [macOS Technical Notes](macos-technical-notes.md))
- No cross-user access by default
- Works fine under Hardened Runtime
- **Blocked under App Sandbox** unless using App Group containers

### POSIX Shared Memory Limits

Resource | macOS default
---------|-------------
Max segment size | Limited by physical memory
Max name length | 30 characters (`PSHMNAMLEN`)
Max open segments | No hard limit (file descriptor based)

## Real-Time Thread Priority

`thread_policy_set()` with `THREAD_TIME_CONSTRAINT_POLICY`:

- Works for **any process** — no entitlements or root required
- This is what CoreAudio uses internally
- Works under both Hardened Runtime and App Sandbox
- See `libipc/proto/rt_prio.h` for the implementation

## Code Signing & Notarization

### Signing

Both the host and all service binaries must be signed:

```bash
# Sign with Developer ID (for distribution)
codesign --force --options runtime \
    --sign "Developer ID Application: Your Name (TEAMID)" \
    build/bin/my_host build/bin/my_service

# Or ad-hoc sign for local development
codesign --force --sign - build/bin/my_host build/bin/my_service
```

The `--options runtime` flag enables Hardened Runtime.

### Notarization

Required for non-App-Store distribution (Gatekeeper will block unsigned or
un-notarized binaries downloaded from the internet):

```bash
# Create a zip for notarization
ditto -c -k --keepParent build/bin/my_host my_host.zip

# Submit for notarization
xcrun notarytool submit my_host.zip \
    --apple-id "you@example.com" \
    --team-id "TEAMID" \
    --password "@keychain:notarytool" \
    --wait

# Staple the ticket (for .dmg or .pkg, not bare binaries)
xcrun stapler staple MyApp.dmg
```

### Packaging

For distribution, package the signed binaries in a:

- **`.pkg` installer** — can install the service binary alongside the host,
  set up LaunchAgents, etc.
- **`.dmg` disk image** — drag-to-install, simpler but no install scripts
- **`.app` bundle** — embed the service binary in
  `MyApp.app/Contents/MacOS/` or `Contents/Helpers/`

When embedding in an `.app` bundle, locate the service binary at runtime:

```cpp
// Get path to the running app bundle
CFBundleRef bundle = CFBundleGetMainBundle();
CFURLRef url = CFBundleCopyExecutableURL(bundle);
// Service is at: <bundle>/Contents/Helpers/my_service
```

## Distribution Options

### Option A: Developer ID (recommended for pro audio)

This is the standard for professional audio software (DAWs, plugins, audio
engines). All of Logic Pro, Ableton, Pro Tools ship this way.

- **No sandbox** — full access to `posix_spawn`, signals, shared memory
- Sign with Developer ID + notarize
- Distribute as `.pkg` or `.dmg`
- Our orchestration layer works **as-is**

### Option B: App Store

If App Store distribution is required:

- Replace `posix_spawn()` with XPC or LaunchAgent (see below)
- Replace POSIX shared memory with App Group file-backed `mmap()`
- Replace signal-based shutdown with XPC messages
- Add the `com.apple.security.application-groups` entitlement

### Option C: Hybrid (XPC lifecycle + shm data)

A pragmatic middle ground:

- Use **XPC** or **`launchd`** for service lifecycle management
- Keep **POSIX shared memory** for the lock-free audio ring buffer
- The service runs as a LaunchAgent or XPC service
- Lifecycle commands go over XPC; audio data goes over `shm_ring`

## Alternative: XPC + LaunchAgent

For sandboxed or App Store distribution, replace the process manager with
macOS-native service management:

### LaunchAgent (per-user daemon)

Install a plist in `~/Library/LaunchAgents/`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.yourcompany.audioservice</string>
    <key>ProgramArguments</key>
    <array>
        <string>/path/to/my_service</string>
        <string>0</string>
    </array>
    <key>KeepAlive</key>
    <true/>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
```

`launchd` handles respawning (`KeepAlive`), health monitoring, and
graceful shutdown automatically.

### XPC Service

For tighter integration, create an XPC service embedded in the app bundle:

```text
MyApp.app/
  Contents/
    XPCServices/
      com.yourcompany.audioservice.xpc/
        Contents/
          MacOS/audio_service
          Info.plist
```

The host connects via `NSXPCConnection`. XPC services:

- Are automatically launched on first connection
- Are killed when the host exits
- Can share data via App Group shared memory

### App Group Shared Memory

Under sandbox, use a file in the shared App Group container instead of
`shm_open()`:

```cpp
// Both host and service have the entitlement:
// com.apple.security.application-groups = ["group.com.yourcompany.audio"]

// Map a file in the shared container
const char *group_dir = /* NSFileManager containerURLForSecurityApplicationGroupIdentifier */;
std::string path = std::string(group_dir) + "/audio_ring";
int fd = open(path.c_str(), O_RDWR | O_CREAT, 0600);
ftruncate(fd, ring_size);
void *mem = mmap(nullptr, ring_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
```

The `shm_ring` template can be adapted to use file-backed `mmap()` instead
of `shm_open()` with minimal changes.

## Summary

Component | Developer ID | App Store
----------|-------------|----------
`posix_spawn()` | ✅ Works | ❌ Use XPC/launchd
`kill()` / signals | ✅ Works | ❌ Use XPC messages
`shm_open()` | ✅ Works | ⚠️ Use App Group mmap
`thread_policy_set()` (RT) | ✅ Works | ✅ Works
`service_registry` | ✅ Works | ⚠️ Adapt to App Group shm
`shm_ring` | ✅ Works | ⚠️ Adapt to file-backed mmap
Code signing | Required | Required
Notarization | Required | Automatic
