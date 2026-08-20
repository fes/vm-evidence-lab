# Parallels platform notes (Apple Silicon host)

Operational gotchas discovered while bringing up all three guest platforms
(Linux, Windows, macOS) on a fresh Apple Silicon Mac. Read this before
provisioning a new host or debugging a "job never runs" / "job fails at
checkout" symptom.

## Apple Silicon macOS VMs cannot move between physical Macs

A macOS guest's `aux.bin` (inside the `.macvm` bundle) holds boot/Secure
Enclave keys cryptographically bound to the *physical host* that created the
VM. Copying or restoring a macOS VM onto a different Apple Silicon Mac (even a
newer chip generation, e.g. M1/M2 -> M4) produces a VM that boots to a
permanently black screen: the host process runs at ~0% CPU (check with
`ps aux | grep prl_macvm_app`) and `parallels.log` shows
`macVM started successfully` with no further progress. This is an Apple
Virtualization.framework restriction, not a Parallels bug, and there is no
workaround (see Parallels KB 129502). Clicking into the window, waiting, or
restarting the VM does not help.

**If you inherit an archived macOS VM created on different hardware, do not
try to debug the black screen.** Delete it and build a fresh macOS VM
directly on the new host:

```sh
prlctl create festerm-macos-m4 --distribution macosx
prlctl start festerm-macos-m4   # will fail with "Cannot retrieve the
                                 # hardware model data" -- expected, no
                                 # restore image is attached yet
```

There is no scriptable `prlctl` flag that fetches the correct IPSW
automatically; use the Parallels Desktop GUI's *File > New... > Install
macOS...* assistant, which downloads the right restore image for the host.
`prlctl create ... --restore-image <path>` only accepts an already-downloaded
`.ipsw`.

## Fresh macOS VMs need Xcode Command Line Tools and Rust installed manually

Neither ships by default. Bootstrap headlessly over SSH once Parallels Tools
and Remote Login are enabled:

```sh
# Enable SSH (Remote Login) -- systemsetup requires Full Disk Access and
# fails headlessly; use launchd directly instead:
prlctl exec <vm> launchctl bootstrap system /System/Library/LaunchDaemons/ssh.plist
prlctl exec <vm> launchctl enable system/com.openssh.sshd
prlctl exec <vm> launchctl kickstart -k system/com.openssh.sshd

# Install Xcode CLT headlessly (exact label matters -- copy it from `-l`):
ssh festerm@<ip> "softwareupdate -l"
ssh festerm@<ip> "echo <password> | sudo -S softwareupdate -i 'Command Line Tools for Xcode <version>-<version>' --verbose"

# Install Rust:
ssh festerm@<ip> "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y"
```

Take the baseline snapshot only *after* both are installed, or every reset
will re-trigger the missing-tooling failure (`failure_class=artifact` from
`relay_stage_sources`/git, or a build failure from missing `cargo`).

## `prlctl exec` on macOS VZ_VM guests flattens argv and re-splits it

Unlike the Linux/Windows guest agents, the macOS Apple Silicon guest agent
appears to join all `prlctl exec` arguments with spaces and re-parse the
result once with a shell, rather than preserving the original argv boundary.
This silently breaks the common `bash -c '<multi-word command>'` pattern:
`bash -c 'echo hello > file'` only ever executes `echo` (the first word),
with the remaining words consumed as `bash`'s positional parameters, and any
`>`/`|` you intended for the inner command instead applies to the *outer*
re-invocation.

Symptom: commands report exit code 0 but produce empty/truncated output or
empty files, with no error.

Workarounds:
- Prefer plain SSH (`ssh festerm@<ip> "command"`) over `prlctl exec` for
  anything beyond a single direct executable + literal arguments -- SSH
  preserves quoting normally.
- If you must use `prlctl exec`, pass shell metacharacters (`|`, `>`, `>>`) as
  their own unquoted-from-the-shell's-perspective tokens directly to
  `prlctl exec`, without an extra `sh -c`/`bash -c` wrapper, e.g.:
  `prlctl exec <vm> echo "$B64" '|' base64 -d '>>' /path/to/file`.

## macOS preserves the logged-in console session across a snapshot revert; Windows does not

After `prlctl snapshot-switch`, a macOS guest resumes with the same user still
active on `console` (confirmed via `prlctl exec <vm> who`). A Windows guest,
by contrast, fully logs out back to `LogonUI` after every snapshot
revert/resume, even though the snapshot was taken while a user was signed in.
`prlctl exec <vm> --current-user ...` (required for `provider_exec_current_user`
on Windows) silently fails with "the -File parameter does not exist" when no
interactive session is present -- this is misleading; the real cause is the
missing session, not a bad path.

Fix for Windows: enable autologon so the console session comes back on its
own after every reset, independent of manual intervention:

```powershell
$key = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
Set-ItemProperty -Path $key -Name AutoAdminLogon -Value "1" -Type String
Set-ItemProperty -Path $key -Name DefaultUserName -Value "festerm" -Type String
Set-ItemProperty -Path $key -Name DefaultPassword -Value "<password>" -Type String
Set-ItemProperty -Path $key -Name DefaultDomainName -Value "$env:COMPUTERNAME" -Type String
```

Take the baseline snapshot only after confirming autologon survives a full
`prlctl restart` (not just a snapshot switch).

macOS does not need this to survive a snapshot revert, but GUI-based
autologin (System Settings -> Users & Groups -> Login Options) is still worth
setting up so the session also survives a full VM restart/reboot, not just a
snapshot switch. There is no reliable headless/CLI way to set macOS autologin
credentials: `sysadminctl -autologin set -userName ... -password ...` fails
with `SACSetAutoLoginPassword error:22` ("Unable to get the SessionAgent
endpoint") whether run over SSH or via `prlctl exec --current-user` -- this
API requires running literally inside the console session's own process
tree. Set it through the GUI once, then snapshot.

## PowerShell native-command stderr is treated as fatal

With `$ErrorActionPreference = 'Stop'` (used throughout `relay/windows.ps1`
and the fesTerm Windows adapter), any stderr text from a directly-invoked
native command (`git`, `cargo`, `cmd.exe`, ...) is promoted into a
script-terminating error, *regardless of stream redirection* (`*> $null`
does not suppress it). Since `git clone`/`git fetch` and `cargo build` both
write routine progress output to stderr, every Windows job used to fail
before doing any real work. Both `relay/windows.ps1` and fesTerm's
`scripts/vm-evidence-adapter/windows.ps1` now wrap native invocations in an
`Invoke-NativeCommand` helper that temporarily sets
`$ErrorActionPreference = 'Continue'` around the call and relies on
`$LASTEXITCODE` (already checked everywhere) to detect real failures. Apply
the same wrapper to any new native command added to a Windows relay/adapter
script.
