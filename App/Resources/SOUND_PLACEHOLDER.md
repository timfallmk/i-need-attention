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
