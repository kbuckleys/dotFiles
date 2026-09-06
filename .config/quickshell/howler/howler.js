// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/

// mako sorted its visible stack with `sort=-priority`: urgency descending,
// and within one urgency the newest first. The server hands out rising ids,
// so id order IS arrival order. History is left in plain arrival order — a
// list you scroll back through wants time, not priority.
function byPriority(a, b) {
  if (a.urgency !== b.urgency) return b.urgency - a.urgency;
  return b.id - a.id;
}

// Does this notification come from something that is also an MPRIS player?
// Matching against the live player list rather than a hardcoded list of app
// names: any player that announces itself on MPRIS gets transport controls,
// and one that does not never shows buttons that would do nothing.
//
// A SENDER MAY ALSO SAY SO OUTRIGHT, in the `x-mpris-player` hint. Identity and
// subject are two different questions and the guessing above can only answer the
// first: an app that DRIVES a player -- a client whose daemon holds the bus name
// -- is correctly named as itself in app_name and desktop-entry, and matching
// those found nothing, so its toasts lost their transport row. The hint is the
// sender answering the second question directly; anything that does not send one
// falls through to exactly the matching that was here before.
function matchPlayer(players, appName, desktopEntry, mprisHint) {
  const app = String(appName || "").toLowerCase();
  const entry = String(desktopEntry || "").toLowerCase();
  const said = String(mprisHint || "").toLowerCase();
  if (said !== "") {
    for (const p of players) {
      for (const c of [p.identity, p.dbusName, p.desktopEntry]) {
        const v = String(c || "").toLowerCase();
        if (v !== "" && (v.indexOf(said) >= 0 || said.indexOf(v) >= 0)) return p;
      }
    }
  }
  if (app === "" && entry === "") return null;
  for (const p of players) {
    const cands = [p.identity, p.dbusName, p.desktopEntry]
      .map((s) => String(s || "").toLowerCase())
      .filter((s) => s !== "");
    for (const c of cands) {
      // either direction: "Spotify" vs "spotify", "spoot" vs "org.mpris…spoot"
      if (app !== "" && (c.indexOf(app) >= 0 || app.indexOf(c) >= 0)) return p;
      if (entry !== "" && (c.indexOf(entry) >= 0 || entry.indexOf(c) >= 0)) return p;
    }
  }
  return null;
}

// Coarse "when", the way a notification list wants it — exact clock times are
// noise for something that arrived ninety seconds ago.
function ago(then, now) {
  const s = Math.max(0, Math.floor((now - then) / 1000));
  if (s < 60) return "now";
  const m = Math.floor(s / 60);
  if (m < 60) return m + "m";
  const h = Math.floor(m / 60);
  if (h < 24) return h + "h";
  return Math.floor(h / 24) + "d";
}

// mako's `format=<b>%s</b>\n%b`: summary bolded, body under it. Kept as one
// function so the toast and the history row cannot render it differently.
//
// A NEWLINE IS A LINE BREAK, which StyledText does not believe on its own. The
// freedesktop spec says a body may contain them and every sender writes them
// that way -- but Qt treats StyledText as HTML-ish, and HTML collapses a literal
// newline into a space. So a two-line body arrived as one line with a gap in it,
// and anything a sender put on its own row -- a track's liked/lyrics/explicit
// marks, a second paragraph -- ran on into the end of the first.
//
// Only in the markup branch: the plain branch feeds a PlainText Text, where a
// newline already is what it says it is and a <br/> would show as five
// characters.
function formatBody(body, markup) {
  if (!markup) return Strings.escapeHtml(body ?? "");
  return String(body ?? "").replace(/\r\n|\r|\n/g, "<br/>");
}

// A NOTIFICATION'S IMAGE DOES NOT SURVIVE THE SESSION IT ARRIVED IN.
//
// `image` is whatever the sender put in the image-path hint, and for the
// notifications that carry one at all it is nearly always a file written for
// that one message — a screenshot, a downloaded cover, something under /tmp.
// The history outlives all of them. Saving the path meant every restart tried
// to load a file that had since been deleted and logged
//
//     Could not load icon "/home/buck/Pictures/Screenshots/…png" at size …
//
// once per row per size, for a picture nobody could ever see again.
//
// So a LOCAL PATH is dropped on the way to disk while the toast that is on
// screen keeps it. A bare themed icon NAME is not a path and is not dropped:
// those are stable, and they are what the row falls back to anyway.
//
// AND EVERY image:// URL GOES WITH THEM, which is the case this rule missed.
// A sender that supplies its icon as inline image-data rather than as a path —
// discord does — never gives a path at all: quickshell puts the pixels in its
// own provider and hands back a handle, `image://qsimage/13/1`. That is a
// token for one running instance, and the old rule did not recognise it: it
// does not start with "/", it is not "file://", and it is not "image://icon//",
// so it was written to disk verbatim. It is WORSE than the paths this function
// was built to drop — a deleted file might still be there, a handle from a
// process that has exited provably cannot be — and it came back on the next
// start as
//
//     Requested image from unknown handle "13/1"
//
// once per row, per size. Matching the whole `image://` scheme covers the
// handles and keeps the themed-icon case that was already here.
function localImage(img) {
  const s = String(img || "");
  return s.indexOf("/") === 0
    || s.indexOf("file://") === 0
    || s.indexOf("image://") === 0;
}

// One rule, applied in both directions. A row is cleaned on the way out so
// nothing volatile is written, and again on the way IN so a file that already
// holds one heals itself instead of complaining once per start forever. The
// history on disk predates this rule; it should not have to be deleted by hand
// for the rule to take effect.
function cleanImage(row) {
  if (!row || !localImage(row.image)) return row;
  const copy = Object.assign({}, row);
  copy.image = "";
  return copy;
}

function serialize(list) {
  return JSON.stringify(list.map(cleanImage));
}

function parse(text) {
  try {
    const v = JSON.parse(text || "[]");
    return Array.isArray(v) ? v.map(cleanImage) : [];
  } catch (e) {
    return [];
  }
}
