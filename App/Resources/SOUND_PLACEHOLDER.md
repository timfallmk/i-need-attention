# Custom Notification Sound

Drop a `needs-attention.caf` file in this directory and add it to the
**Attention** target as a bundle resource. iOS requires sounds to be in
`.caf`, `.aiff`, or `.wav` format and shorter than 30 seconds. Convert
any source file with:

```sh
afconvert input.wav needs-attention.caf -d ima4 -f caff -v
```

Until you add the file, CloudKit pushes will fall back to the default
notification sound.

## Source and attribution

The bundled sound is derived from **Chord2_Rev.wav** by Aarni Koskela (akx),
from <https://github.com/akx/Notifications>, licensed under
[CC BY 3.0 Unported](https://creativecommons.org/licenses/by/3.0/).

To re-derive `needs-attention.caf`:
1. Download `Chord2_Rev.wav` from the URL above.
2. Run: `afconvert Chord2_Rev.wav needs-attention.caf -d ima4 -f caff -v`
