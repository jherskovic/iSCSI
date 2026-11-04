# macOS iSCSI/NVMe-TCP Initiator

[![version](https://img.shields.io/github/v/release/jherskovic/iSCSI?sort=semver&display_name=tag&label=version)](https://github.com/jherskovic/iSCSI/releases/latest)
[![license](https://img.shields.io/github/license/jherskovic/iSCSI)](LICENSE)
[![build](https://github.com/jherskovic/iSCSI/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/jherskovic/iSCSI/actions/workflows/ci.yml)
[![tests](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/jherskovic/iSCSI/badges/tests.json)](https://github.com/jherskovic/iSCSI/actions/workflows/ci.yml)
[![coverage](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/jherskovic/iSCSI/badges/coverage.json)](https://github.com/jherskovic/iSCSI/actions/workflows/ci.yml)

iSCSIInitiator is a modern Apache-licensed, user-mode iSCSI/NVMeoF client ('initiator' in iSCSI parlance) for macOS 26+.
I started this project because existing initiators were either dead (kexts) or expensive and commercial.
I also wanted to see how far I could take Claude into systems programming. As it turned out, quite a lot.

It is written in Swift, mostly by Claude, with a lot of handholding, review, and testing by an
actual human (me), mostly against my homelab's TrueNAS machine.

The architecture evolved during development. It started as a DriverKit module but, because of some blocking
bugs in APFS, couldn't proceed that way. The code is still here and I still hope to work around them in the
future. At the moment, it has a pure user-mode backend that works the following, hackish way:

- iSCSI and NVMe reside in a user-space daemon. It presents targets/LUNs (namespaces, if you insist on NVMe
  terminology) as block devices.
- It creates a disk image file on the filesystem using FSKit, that is transparently backed by the target's device.
- It then uses `hdiutil` to mount this "disk image", and it works!

## Obvious warning

This project deals with data storage, and -like any such project- there is a risk of data loss. Bugs in the Initiator,
bugs in APFS, bugs in macOS, cosmic rays, power outages, acts of God, and plain bad luck can, may, or even **will**
result in data loss. This is inherent to the nature of the beast, i.e. you're sending data over a network but pretending
it's local. There are plenty of things that can go wrong.

**If you use this without testing it extensively on your own hardware, network, SAN/NAS, etc, you're insane**. In any
case, I can't be held responsible for data loss. Test it before trusting it.

## Mandatory screenshot

![Setup screen](https://github.com/jherskovic/iSCSI/raw/main/docs/screenshots/setup.jpg "The setup screen")

## AI warning

This README is 100% pure human-generated text. The code and documentation are almost completely written by
Claude Opus 5+ and Fable 5+. I supervise it closely and read+review attentively, but you've been warned.
If vibe-coded projects scare you, please move on.

## Basic usage

#### Setup

Drag the application to /Applications like any other Mac app. On first launch the setup screen will open,
showing any steps that need to be completed. You will likely have to enable the FSKit extension, shown below
![FS Kit Extension pane in System Settings](https://github.com/jherskovic/iSCSI/raw/main/docs/screenshots/fskit.jpg)

Certain versions of macOS, especially 26.x, have a bug that doesn't let you enable FSKit extensions through
System Settings. The problem is UI, not permissions. The app detects this and offers an override. It is safe.

You can also choose to enable the included Dock extension. The only thing it does is free the icon from Squircle Jail.

Setup also offers to put the included `iscsictl` command-line tool on your PATH, with a link in `/usr/local/bin`.
It's optional, and macOS will ask for an administrator's password.

Don't keep multiple copies of the app around. macOS may use their FSKit extension instead of the current version.
The app detects this on launch and will clean it up for you if you let it. It's probably a good idea to say yes.

#### Mounting a target

Head to the "Discover" page and enter the address of the target you wish to connect to. Scroll down for options
like username/password, or forcing the connection to a specific network interface. Click Search. Once discovery
finishes, you'll be able to Add targets to the target list.
![The list of targets](https://github.com/jherskovic/iSCSI/raw/main/docs/screenshots/attach.jpg)

Once your target appears on the target list, right-click it and select "Edit" for security and caching options.
Otherwise, click "Attach". Your target should be mounted in a few seconds. Eject it normally. Detach from the
target in the Targets screen.

## Repo/development

I (we?) use a lot of VMs running on UTM to develop and test this project. You'll see references to them in
test scripts and the codebase, mostly `herko@non-routable-ip-address`. I didn't bother removing them from
the repo, since I'm not exposing real passwords or actual machines.

There are hundreds of tests run on every iteration of the Initiator. Release builds on Github are
properly notarized with my Apple developer certificate.

I also manually test the initiator on a completely different bare-metal macOS (initially 26, now 27) machine.
It works. It's not just VMs. I daily-drive the project, too, over Tailscale and directly. As far as I can tell, it works.
It definitely suits my needs.

## Performance/testing

Performance is a somewhat complicated story. The best-case scenario for performance is large linear
reads and, to a lesser extent, writes. The initiator performs look-ahead retrieval if it detects
linear reads, and dynamically adjusts the size of the lookahead. You can set up a local cache,
which comes in handy for things like running VMs on remote storage, at the expense of SSD wear and tear.

The architecture severely limits write performance. The main issue is the lack of communication FSKit
provides; it has no write barrier signal, so I either force a sync on every write, or risk data loss.
If you tell FSKit that you're done with a write, APFS will act on the lie and corruption will result
in case of disconnection or any other hiccup. Issuing a Force Unit Access command on every write
slows down throughput by about 4.5x, at least on my hardware. If you're confident in your infra,
you can set the initiator to instead issue a FUA every a certain number of seconds. This will
speed writes up. It also WILL wreck your mounted filesystem if there's a disconnection or server issue
because the actual on-disk bytes will be inconsistent.

TL;DR don't disable FUA on every write unless you know what you're doing. **Especially don't disable it
over WiFi, or a VPN, or Tailscale, etc.** Caveat emptor.

Most of the work and testing is done against a LUN on my actual, geriatric TrueNAS 25.04 server in my
homelab. There is also a target simulator that can be, and was, used for destructive testing.

Test it yourself:

```bash
swift test                          # unit + integration suite
scripts/fuzz.sh 60                  # 60s ASan fuzz of the PDU decoder

# Against a real target (e.g. your NAS):
swift run iscsictl iscsi discover 192.168.1.50
swift run iscsictl iscsi verify 192.168.1.50 --target iqn.2000-01.com.example:disk0 \
    --lun 0 --write        # DESTRUCTIVE — scratch LUN only

# The same over NVMe/TCP (TrueNAS SCALE 25.04+, port 4420). The host NQN it
# prints is what to add to the subsystem's allowed hosts:
swift run iscsictl nvme discover 192.168.1.50
swift run iscsictl nvme verify 192.168.1.50 \
    --subsystem nqn.2011-06.com.truenas:uuid:...:disk0 --nsid 1 --write   # DESTRUCTIVE
```

Or against the local simulator, which needs no NAS and can be broken on
purpose (drop connections, corrupt payloads, stall commands, cut the target's
power with a volatile write cache):

```bash
swift run iscsi-target-sim --port 3260 --capacity-mib 1024 &
swift run iscsictl iscsi verify 127.0.0.1 --target iqn.2000-01.com.example:lun0 --write
printf 'crash\n' | nc 127.0.0.1 3262     # target power loss, on demand

swift run iscsi-target-sim --nvme --capacity-mib 1024 &     # the same, as NVMe/TCP on 4420
swift run iscsictl nvme verify 127.0.0.1 --subsystem nqn.2026-08.me.herko.sim:disk0 --write
```

`docs/open-questions.md` lists what is known to be untested, unexplained, or
deferred.

See `docs/architecture.md` for the two-backend design and the DriverKit
throughput caveat, `docs/backend-a-fskit-notes.md` for how the shipping backend
actually behaves on both OS versions, `docs/daemon-registration.md` for what
SMAppService really does, `docs/resilience.md` for the fault matrix, and
`docs/test-playbook.md` for the full test strategy.

## License

Apache License 2.0 — see [LICENSE](LICENSE).

Apache rather than MIT. The motivation is that Apache makes patent grants explicit,
reducing legal risk.

Bundled dependencies, both permissive and neither imposing conditions on this
code:

|                                                                         | licence    |
| ----------------------------------------------------------------------- | ---------- |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | Apache 2.0 |
| [Sparkle](https://github.com/sparkle-project/Sparkle)                   | MIT        |

Sparkle ships inside the app bundle, so a redistributed binary carries its
copyright notice; the framework includes its own license file.
