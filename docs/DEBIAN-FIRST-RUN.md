# First-run test on Debian 12 "bookworm"

A checklist for someone with shell access to a Bookworm box who has never run
Tidal Wave on it. Written for the real-time-kernel machine on Linus's LAN, but
nothing here is specific to it.

## Why this box is the interesting one

Bookworm ships **Qt 6.4.2**. `CMakeLists.txt` declares 6.4 as its floor, but
the only configuration anyone has ever built is Qt 6.12, so 6.4 is a claim
rather than a tested fact. Two separate questions follow, and they have
different answers:

1. **Does the published `.deb` install here?** `CPACK_DEBIAN_PACKAGE_SHLIBDEPS`
   is ON, so dpkg-shlibdeps pins each Qt dependency to the version the package
   was *built* against. A `.deb` built on Qt 6.12 therefore asks for
   `libqt6core6 (>= 6.12.0)`, which Bookworm cannot satisfy. The expected
   outcome is apt refusing the install with unmet dependencies. That is the
   **good** failure - a clear message beats a binary that installs and then
   dies on a missing symbol - but it means the published `.deb` is only for
   distributions already on Qt 6.12, and the README has to say so.
2. **Does it build from source against 6.4.2?** This is the claim in the
   CMakeLists worth checking. Expect compile errors where the code uses
   something newer than 6.4; each one is either a thing to guard by version or
   a reason to raise the declared floor.

## 1. What is actually on the box

    cat /etc/os-release
    uname -a                      # confirm the RT kernel
    dpkg -l | grep -E 'libqt6core6|qt6-base' || echo "no Qt 6 installed"
    apt-cache policy libqt6core6  # the version Bookworm would install
    echo "$XDG_SESSION_TYPE"      # x11 or wayland
    echo "$XDG_CURRENT_DESKTOP"
    pactl info 2>/dev/null | head -5 || aplay -l | head

Record all of it before changing anything. A first-run test is only meaningful
against a known starting state.

## 2. The `.deb`

    sudo apt install ./tidal-wave-0.4.0-Linux.deb

Report the **exact** apt output. If it refuses, do not force it with `dpkg -i
--force-depends`: an install that cannot work is the finding, and forcing it
replaces a clean diagnosis with a crash. If it *does* install, carry on
through section 4.

## 3. From source

    sudo apt install build-essential cmake ninja-build \
      qt6-base-dev qt6-declarative-dev qt6-multimedia-dev qt6-svg-dev \
      libasound2-dev libavahi-client-dev
    cmake -S tidal-wave -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
    cmake --build build

Capture every error verbatim, with the file and line. The useful report is not
"it failed" but "this call needs Qt 6.x, introduced after 6.4". Then try the
test suite, which is behind an option that defaults to OFF:

    cmake -S tidal-wave -B build -DTIDALWAVE_BUILD_TESTS=ON -DCMAKE_BUILD_TYPE=Debug
    cmake --build build && ctest --test-dir build --output-on-failure

## 4. First run, as a user who has never seen it

Only if something runnable came out of 2 or 3.

- Launch it from the application menu, not just the shell: that exercises the
  `.desktop` file, the icon caches and the Wayland app id, which is where this
  app has had most of its packaging bugs.
- Does the window appear with the right icon in the taskbar, and is the
  launcher entry a single one rather than a duplicate?
- The login screen comes first. **Stop there and report** unless Linus has
  given you credentials: do not attempt to log in to his Tidal account.
- Without logging in, still check: does the window resize down to 640px wide
  without clipping? Does the theme switcher work? Does Settings open and close?
- `journalctl --user -b | grep -i tidal` and the app's own stderr: any QML
  warning at all is a finding. The suite runs with zero warnings on the
  development machine.

## 5. Audio, if it got that far

The RT kernel is the reason this box is interesting for audio. Report which of
PipeWire, PulseAudio or bare ALSA is in play, whether the app's output device
list matches `pactl list short sinks`, and whether switching devices while
playing causes a hang - that last one was a real deadlock on the development
machine: a device-changed signal arrived while PipeWire held its thread loop
lock, and rebinding the output took the same lock. It is fixed by deferring the
rebind to the next event loop turn, but the RT scheduler changes the timing, so
it is worth re-testing here specifically.

## What to send back

The commands you ran, their output, and the version strings from section 1. No
summaries without the raw text: the exact wording of an apt error or a compiler
diagnostic is the whole value of this run.
