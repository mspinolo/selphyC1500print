# Vendored LittleCMS

- Upstream: https://github.com/mm2/Little-CMS
- Version: lcms2.20 (tag `lcms2.20`, commit `7717fce0d85447ef3b2df0cca2e99207c15eeecd`)
- Licence: MIT (see `LICENSE`)
- Files: `src/*.c`, `src/lcms2_internal.h`, `src/lcms2_plugin.h` and `include/lcms2.h` are unmodified copies.
  `lcms2_plugin.h` lives in `src/` (private) so that only `lcms2.h` is part of the public module.

Why vendored: identical numerical behaviour on Linux and macOS, no Homebrew dependency,
and a self-contained application bundle. Update by replacing the files from a new upstream tag
and recording the tag and commit here.
