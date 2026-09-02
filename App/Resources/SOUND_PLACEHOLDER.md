# Custom Notification Sound

`needs-attention.caf` is already bundled in this directory. XcodeGen includes
the entire `App/Resources/` folder in the Attention target, so no manual
"Add to target" step is needed.

To replace it with your own sound, drop a new `needs-attention.caf` (≤30s) here
and re-run `xcodegen generate`. iOS requires sounds to be in `.caf`, `.aiff`,
or `.wav` format. Convert any source file with:

```sh
afconvert input.wav needs-attention.caf -d ima4 -f caff -v
```

If the file is removed while the Custom sound setting is enabled (Settings →
Custom sound), notifications will be silent rather than falling back to the
system default. To restore the system default sound, turn Custom sound off in
Settings.

## Source and attribution

The bundled sound is derived from **Chord2_Rev.wav** by Aarni Koskela (akx),
from <https://github.com/akx/Notifications/blob/master/WAV/Chord2_Rev.wav>,
licensed under [CC BY 3.0 Unported](https://creativecommons.org/licenses/by/3.0/).

Changes made: converted from WAV to IMA4 CAF using `afconvert -d ima4 -f caff`.
No trimming or normalization was applied.

CC BY requires this attribution to reach end users, not just live in the repo, so
it is mirrored in `App/Models/OpenSourceLicenses.swift` and shown under
Settings → Open Source. `OpenSourceLicensesTests` guards it. If you replace the
sound, update both places.

To re-derive `needs-attention.caf`:
1. Download `Chord2_Rev.wav` from the URL above.
2. Run: `afconvert Chord2_Rev.wav needs-attention.caf -d ima4 -f caff -v`
