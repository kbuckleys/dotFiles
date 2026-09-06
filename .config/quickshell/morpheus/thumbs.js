// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/
//
// ONE POOL OF THUMBNAILS, for everything in this shell that needs one.
//
// Terminus and Picasso both look at the same pictures — Picasso's whole directory
// of wallpapers is a directory Terminus browses — and both used to cache their own
// copy of every one of them, at two sizes, under two names, in two places. The
// same 8MB PNG was decoded and written twice and cleared once.
//
// The KEY IS COMPUTED IN SHELL AND NOWHERE ELSE, and that is the design.
//
// The obvious arrangement — each side works out the filename itself — needs one
// hash function written twice, once in JavaScript and once in something a shell
// can run, producing byte-identical output forever. Terminus had a FNV-style hash
// in JS that no awk can reproduce: `(h ^ c) * 16777619` passes 2^53 and doubles
// stop counting. So instead the generator REPORTS what it made — one
// `source<TAB>thumbnail` line per file — and the caller keeps the mapping. The
// formula then only has to agree with itself.
//
// Existing files are reported without being regenerated, so asking for a
// directory that is already cached costs one `stat` and one `md5sum` per file
// and no decoding at all.

// Under quickshell's own cache root rather than either component's, because it
// belongs to neither of them now.
function dir() {
  return Paths.cacheDir() + "/quickshell/thumbs";
}

// The size both sides settled on. 256 was Terminus' and looked soft in a zoomed
// grid; 480 was Picasso's and is generous for a 190px tile — but a thumbnail
// that is too big costs one decode and a thumbnail that is too small costs a
// fallback to an 8MB original, so the larger number is the cheaper mistake.
const SIZE = 480;

// path | size | mtime, hashed. Size and mtime together are what makes replacing
// a picture with a different one of the same name a different cache entry —
// which is what lets both sides leave Qt's image cache on, since a changed file
// is never the same URL.
//
// mtime is the INTEGER second: `find -printf %T@` prints a fraction whose
// digits depend on the filesystem, and two callers that disagree about the tail
// of it disagree about every filename.
// path | size | mtime, hashed. Size and mtime together are what makes replacing
// a picture with a different one of the same name a different cache entry —
// which is what lets both sides leave Qt's image cache on, since a changed file
// is never the same URL.
//
// mtime is the INTEGER second: `find -printf %T@` prints a fraction whose
// digits depend on the filesystem, and two callers that disagree about the tail
// of it disagree about every filename.
//
// Written as one line per step with `;` rather than a here-document: the whole
// script is the single-quoted argument of `sh -c`, and a here-doc inside it is
// read by the OUTER shell, which ends the quoting where nobody meant it to.
function keyScript() {
  return 'sz=$(stat -c %s -- "$1" 2>/dev/null); '
    + 'mt=$(stat -c %Y -- "$1" 2>/dev/null); '
    + 'key=$(printf "%s|%s|%s" "$1" "$sz" "$mt" | md5sum | cut -d" " -f1); ';
}

// `i` a picture, `v` a frame out of a video, `a` a track's cover art. xargs
// hands the first token to the script as $0 and the second as $1, which is the
// same shape terminus' own batch used.
//
// A file that yields nothing — a track with no artwork, a video ffmpeg cannot
// seek — writes nothing and is not reported, which is how the caller knows to
// keep showing its glyph rather than pointing an Image at a path that was never
// written.
function generate(jobs) {
  if (!jobs || jobs.length === 0) return "";
  const d = Strings.shellQuote(dir());
  const args = jobs.map((j) => j.kind + " " + Strings.shellQuote(j.src)).join("\n");
  return "mkdir -p " + d + "; printf '%s\n' " + Strings.shellQuote(args)
    + " | xargs -P 4 -L 1 sh -c '"
    + keyScript()
    + 'out=' + d + '/$key.png; '
    + 'if [ ! -s "$out" ]; then '
    + 'if [ "$0" = v ]; then '
    + 'ffmpeg -nostdin -loglevel quiet -ss 1 -i "$1" -frames:v 1 '
    + '-vf scale=' + SIZE + ':-1 -y "$out"; '
    + 'elif [ "$0" = a ]; then '
    + 'ffmpeg -nostdin -loglevel quiet -i "$1" -an -frames:v 1 '
    + '-vf scale=' + SIZE + ':-1 -y "$out"; '
    + 'else '
    + 'magick "$1"[0] -auto-orient -thumbnail ' + SIZE + 'x' + SIZE + ' -strip "$out"; '
    + 'fi; fi; '
    + 'test -s "$out" && printf "%s\t%s\n" "$1" "$out"'
    + "' 2>/dev/null";
}

// The same key, for a caller that already has its own `find` running and wants
// the thumbnail named inside it — Picasso scans and thumbnails in one pass.
// `$1` must be the path when this is spliced in.
function keyExpr() {
  return keyScript() + 'out=' + Strings.shellQuote(dir()) + '/$key.png; ';
}

// source -> thumbnail, from what generate() reported.
function size() { return SIZE; }

function parseMade(text) {
  const out = {};
  for (const line of String(text || "").split("\n")) {
    const cut = line.indexOf("\t");
    if (cut > 0) out[line.slice(0, cut)] = line.slice(cut + 1);
  }
  return out;
}

// The pool is SHARED, so nothing may prune it by asking "does any wallpaper
// claim this file" — the answer is no for every thumbnail Terminus made, and
// Picasso's old sweep would have deleted the lot on its next scan. Age is the
// only question either side can answer about the other's entries: a thumbnail
// nothing has regenerated in a month is one whose source is gone or changed.
function sweep(days) {
  const d = Math.max(1, Math.floor(Number(days) || 30));
  return "find " + Strings.shellQuote(dir())
    + " -maxdepth 1 -type f -name '*.png' -mtime +" + d + " -delete 2>/dev/null";
}
