# External-oracle fuzzing report

The package-source commits added downloads, redirects, a core-Tcl SHA-256,
archive reading and `add`. The `archives` group only installed archives
written by the harness's own writers. The groups in `tests/fuzz_external.tcl`
judge these features against implementations outside tclvenv:

| Group | Generates | Oracle |
| --- | --- | --- |
| `sha256` | data of 0-300 bytes, around 64-byte blocks, around the 64 KiB read size, and up to 300 KB (random, zeros, `0xff`, repeated patterns), hashed whole and in random pieces; `--sha256` in every case, too short, too long, with a space, `0x` or a non-hex digit | `sha256sum`; any case accepted, anything else refused with the `--sha256 must be` message |
| `urljoin` | base URLs with dot, empty and `;`/`:`/`%2e` segments and queries; relative, absolute-path, network-path, query-only and fragment-only references | RFC 3986 section 5.2 written out here (strict 5.2.2, 5.2.3 merge, 5.2.4 by its buffer rules A-E); it gives every example of section 5.4 |
| `toolarchives` | packages with hostile names (newlines and tabs for tar, `~`, leading `-` and `.`, glob characters, `;`, `$`, `'`, 90-200-byte components, Unicode), executables, empty directories, hard and symbolic links; archived by GNU tar (`gnu`, `oldgnu`, `pax`, `posix`, `ustar`; plain, gzip, `gzip -n -9`, several members), Info-ZIP (`-0/-6/-9`, `-D`, `-y`, written to a pipe so it uses data descriptors), 7-Zip, Python `zipfile` (stored or deflated, with or without directory entries) and `tarfile` (`gnu`, `pax`, `ustar`, gzip); top-level, single and nested layouts | a sound archive installs exactly the packed directory (names, bytes, empty directories unless the tool drops them, executable bits), `doctor` agrees, and removal restores the environment; an archive holding a link is refused with nothing changed |
| `downloads` | a `.tar.gz`, `.zip` or `.tm` served by a local HTTP server in the harness: 0-7 redirects (301/302/303/307/308, `Location` in three cases; absolute, absolute-path, relative, dot-segment, query-only and network-path locations, some with fragments; some without a location); then a plain, close-delimited or chunked body (with chunk extensions), compression only when the client asks for it, a `.tar.gz` labelled `Content-Encoding: gzip`/`x-gzip` as Apache's `AddEncoding` sends it, bytes after `Content-Length`, a body cut short, 300/404/500, a body over the size limit, an endless body, a gzip bomb; sometimes a wrong `--sha256` | what is installed is the resource's bytes (what curl and wget save); every request is the target RFC 3986 resolves; the client stops after five redirects; refusals leave the environment unchanged; the temporary directory never holds more than the size limit plus 144 KiB, and ends empty |
| `systemadd` | 1-6 packages with dependency DAGs and version constraints, as package directories, modules (some namespaced), members of a collection whose index sources theirs (as Tcllib's does), the same version in two directories, or registered from the path's root; some with `libfoo.so -> libfoo.so.1` links | native `tclsh` with the same path: the environment, without the path, loads the same versions and copies, from files inside itself; the receipts come from exactly the providers native Tcl used; a package registered from the root is refused |

Campaign: Tcl 8.6.18 and 9.0.4, 150 cases per group, seeds 1, 7 and 11.
Each Tcl version found the same failures in the same cases:

| Group | Failures (seeds 1/7/11), per Tcl version | Findings |
| --- | --- | --- |
| `sha256` | 0/0/0 | none |
| `urljoin` | 6/9/13 | 6 (17 fragment-only, 11 network-path) |
| `toolarchives` | 1/2/2 | 3 (pax newline), 4 (CP 437) |
| `toolarchives` with `-G` added | 8/10/8 | 3, 4, 5 (31 `-G` archives refused) |
| `downloads` | 10/6/15 | 1 (8 labelled), 2 (23 bytes after `Content-Length`) |
| `systemadd` | 0/0/0 | none |

(The `-G` rerun on Tcl 9 with seed 11 stopped when this machine's `/tmp`
quota ran out; it ran in full after the fixes, below.)

## Findings

`ENV` is an environment created with the manager. Each finding has a
reduced reproduction.

### 1. A `.tar.gz` served with `Content-Encoding: gzip` fails its SHA-256 check

Tcl's `http` sends `Accept-Encoding: gzip,deflate` and, with `-channel`,
always decodes a `Content-Encoding` it knows. Apache's `AddEncoding x-gzip
.gz .tgz` (and other servers set up like it) labels a `.tar.gz` file with its
own compression and sends it as it is. tclvenv then saves the
decompressed tar, which has a different hash from the published archive:

```text
tclvenv: SHA-256 mismatch: expected 19f8cec3…, got 32a22fa5…
```

curl and wget, which tclvenv uses for https without `tls`, save the file as
sent. So the same URL works over https and fails over http. Found by
`downloads` (`labelled`) in every seed on both Tcl versions. Asking for
`Accept-Encoding: identity` isn't enough, because `AddEncoding` adds the
header whatever the client asks for, and `http` decodes it anyway. Saving
the body undecoded (or, failing that, also accepting the hash of the
re-read raw body) is what matches curl.

### 2. Bytes after `Content-Length` are saved as part of the download

With `-channel`, Tcl's `http` copies to the channel until the connection
closes, not until `Content-Length` bytes have arrived. `http::data` (without
`-channel`) and curl both stop at the length:

```text
# server: Content-Length: 10, then 21 bytes, then close
8.6.18 -channel: status=ok file=21 bytes     (curl: 10)
9.0.4  -channel: status=ok file=21 bytes
```

The SHA-256 check catches this, so nothing wrong is ever installed, but a
download that curl would accept is refused as a mismatch. Found by
`downloads` (`trailing`). A fix stops at `Content-Length`: truncate the file
to `[http::size]` when the server sent a length, or count bytes in
`-progress`.

### 3. A pax `path` containing a newline is cut at the newline

`tarScan` splits a pax header into records on `\n`. Records are
length-prefixed, and values may contain newlines. GNU tar and Python write
a pax `path` record for any long or non-ASCII name, so a package file named
`été/end⏎` (or any name over 100 bytes holding a newline) is read as
`été/end`. Two such names become one, and the archive is refused as a
duplicate:

```text
tclvenv: duplicate archive entry: ./été/end
```

With only one such name, it installs under the wrong name. Found by
`toolarchives` (GNU tar `pax` and `posix`). Reduced:

```sh
python3 -c "import tarfile,io
t=tarfile.open('nl.tar','w',format=tarfile.PAX_FORMAT)
for n in ['pkg/pkgIndex.tcl','pkg/'+'a'*120+'\nb']:
    i=tarfile.TarInfo(n); t.addfile(i,io.BytesIO())
t.close()"
tar tf nl.tar                       # pkg/aaa…\nb
tclsh tclvenv.tcl install ENV nl.tar --no-deps --no-check   # installs pkg/aaa…
```

The fix reads each record by its length (`LEN key=value\n`, where LEN
counts the whole record).

### 4. Zip names without the UTF-8 flag are read as Latin-1, not CP 437

APPNOTE (appendix D) says a name without general-purpose bit 11 is CP 437.
Python's `zipfile` writes names that way when CP 437 can hold them (here
its directory entries). Windows' built-in zip writes names in the OEM code
page. Python and 7-Zip read them as CP 437. tclvenv tries UTF-8 and then
falls back to Latin-1. `é` (CP 437 `0x82`) becomes U+0082: the directory
`été/` is created as `\u0082t\u0082/`, beside the real `été/`, and its
contents are lost from the package:

```text
installed package differs from what python zip/deflated-dirs packed: missing x.tcl
```

Found by `toolarchives` (Python `zipfile` with directory entries). Info-ZIP
on Linux writes UTF-8 bytes without the flag, so the fix keeps the UTF-8
attempt and falls back to CP 437 (Tcl has the `cp437` encoding), not
Latin-1.

### 5. GNU incremental tars: atime/ctime read as a ustar prefix

`tarScan` takes bytes 345-499 as the ustar `prefix` whenever the magic
starts with `ustar`. In the old GNU format (magic `ustar␠␠\0`) those bytes
hold the atime, ctime and sparse data. `tar -G` fills in the times, so every
name gets a bogus directory in front:

```text
$ tar -C src -G -cf incr.tar pkg
tclvenv: unsupported tar entry (links and special files are refused): 15271251173/pkg/
```

GNU tar lists `pkg/`. Python's `tarfile` makes the same mistake. The archive
is refused anyway (its directories are type `D`, dump directories), so
nothing is installed in the wrong place, but the message is misleading and
any old-GNU archive with times set would be misread. Found by hand while
writing `toolarchives`, which now has a `gnu-incremental` variant that finds
it in every such case. The fix uses the prefix only for magic
`ustar\0` (POSIX). Dump directories could be read as directories, as GNU
tar extracts them.

### 6. Fragment-only redirects drop the query; network-path ones keep dot segments

`resolveUrl` against RFC 3986:

```text
base http://a/b/c/d;p?q   Location #s         -> http://a/b/c/d;p#s     (RFC: http://a/b/c/d;p?q#s)
base http://h/            Location //g/./x/../y -> http://g/./x/../y    (RFC: http://g/y)
```

A `Location: #s` redirect then requests the base path without its query,
which may be a different resource. The second case only sends dot segments
that the server normally removes. Found by `urljoin` (fragment 76, network
54 of 1500 cases, seed 7). Both are small: keep the base query for a
fragment-only reference, and remove dot segments from a network-path
reference's path.

### Minor: v7 tar archives are not recognised

`kind` needs the `ustar` magic, so a pre-POSIX tar (`tar --format=v7`) is
reported as `not a zip, tar or gzip-compressed tar archive`. That's
consistent with the README's list of formats; noted, not counted.

## Fixes

| # | Fix | Regression tests (`tests/external.test`) |
| --- | --- | --- |
| 1, 2 | `download` reads the body with an `http` `-handler` (`downloadBody`) instead of `-channel`. `http` then asks for `Accept-Encoding: identity`, decodes nothing and speaks HTTP/1.0 (no chunked bodies). The handler reads at most what `Content-Length` leaves and writes the bytes as sent; over the size limit (announced or counted) it stops the transfer. An error from the handler comes out of `geturl` itself, so `download` catches it and reports the limit or the failure. | `download-1.labelled`, `download-2.trailing`, `download-2.download`, `download-limit` |
| 3 | `paxPath` reads pax records by their length (`LEN key=value\n`), so a value keeps its newlines; NUL padding is allowed, and a record whose length doesn't end at a newline is refused as a corrupt header. | `pax-3.newline`, `pax-3.install`, `pax-3.records` |
| 4 | `decodeName` takes a fallback encoding: for a zip entry without the UTF-8 flag it's CP 437, after trying UTF-8 (which Info-ZIP on Unix writes without the flag); tar keeps Latin-1. | `zip-4.cp437`, `zip-4.install` |
| 5 | The prefix field is used only for the POSIX magic `ustar\0`; GNU dump directories (type `D`) are read as directories, so `tar -G` archives install. | `gnu-5.times`, `gnu-5.incremental` |
| 6 | `resolveUrl` keeps the base query for a fragment-only location, and removes dot segments from a network-path location's path (an empty path stays empty). | `url-6.rfc` (every example of RFC 3986 section 5.4), `url-6.network` |

Each regression test fails on the code before the fixes and passes after.
The fuzz server now answers an HTTP/1.0 request asking for a chunked body
with a close-delimited one, as real servers do; the client is HTTP/1.0 now.
After the fixes, `urljoin`, `toolarchives` (with `-G`), `downloads`,
`archives` and `systemadd` were rerun with 150 cases per group, seeds 1, 7
and 11, on Tcl 8.6.18 and 9.0.4: no failures, and the regular suite passes
on both.

## Not found

- `sha256`: no difference from `sha256sum` at any length, piece split or
  read boundary; every `--sha256` spelling handled as documented.
- `downloads`: redirect chains of every form are requested as RFC 3986
  resolves them; exactly five redirects are followed; size limits hold for
  `Content-Length`, close-delimited and chunked bodies, endless bodies and
  gzip bombs (the temporary directory stayed within the limit plus one
  read); chunked bodies with extensions, compression the client asked for,
  status errors and short bodies are handled; refusals change nothing and
  leave no temporary files.
- `toolarchives`: apart from findings 3 and 4, every archive from every
  tool and format, layout and compression installed exactly, with
  executable bits, empty directories and long and hostile names; Info-ZIP
  data descriptors and multi-member gzip read correctly; tar links and
  `zip -y` links are refused.
- `systemadd`: the environment always loaded what native Tcl loads, the
  same copy where a version is in two directories, from its own files;
  collection indexes, namespaced modules and `.so` links are copied
  correctly; root registrations are refused with nothing changed.
