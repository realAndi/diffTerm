<div align="center">

# diffTerm

### *a different terminal to use*

<img src="screenshots/modern-app-icon.png" width="128" alt="diffTerm App Icon">

<br>

<img src="screenshots/screenshot1.png" width="320" alt="diffTerm on iPhone">
<img src="screenshots/screenshot2.png" width="320" alt="diffTerm on iPhone">

</div>

---

diffTerm is another terminal emulator for jailbroken iOS and iPadOS devices. It runs a real shell on your device and draws the result the way a terminal is supposed to, so the tools you already use behave the way you expect. It supports iOS 14 and
later (if we can reach later).

The emulator is written from scratch against the DEC VT500 state diagram rather than pattern matching on escape sequences. It covers VT100, VT220 and xterm control sequences, 24-bit colour, the alternate screen, scroll regions, mouse reporting and the OSC extensions modern shells rely on. Accuracy is measured with esctest rather than claimed.

The iPad layout is implemented but has not yet been run on real hardware. (I don't own real hardware.)

## Installing

diffTerm is published in my package repository. Add the source in Sileo or Zebra and then search for diffTerm.

**Repository**

https://reallyitsandi.com/repo/

## Building

diffTerm builds on the device it runs on. You need the Procursus toolchain with `clang`, `swiftc`, `ldid`, `make` and `python3`, and the iPhoneOS SDK at `/var/jb/usr/share/SDKs/iPhoneOS.sdk`. Building a package also needs `dpkg-deb`.

The same Makefile also cross-builds on a Mac (or a CI runner) with Xcode — it picks the bootstrap SDK on-device and Xcode's otherwise.

```sh
make            # compile, bundle and sign
make test       # run the test harness
make install    # install and register the app
make package    # build a .deb
```

## Releasing

GitHub Actions does the rest (see `.github/workflows/release.yml`): every push to `main` is built, attached to a rolling "continuous" release, and published to the Sileo repository as `VERSION-rN`; pushing a tag like `v2.1` publishes a clean `2.1` release. Tagged versions always rank above continuous builds.

## License

MIT. See `LICENSE`.

The completion specs are derived from Fig's, also MIT, and ship with their license. The bundled font carries its own OFL license.
