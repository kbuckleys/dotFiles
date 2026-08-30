// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┘┴└─┘
// https://github.com/kbuckleys/
//
// WEATHER — the forecast, from open-meteo. A singleton for the same reason
// Chronos is one: the fetch is on a schedule of its own and must not restart
// every time the panel that shows it opens.
//
// No API key anywhere, and no location written into the config. The coordinate
// pair comes from the environment if it is set there, otherwise from a one-off
// IP lookup that is then cached — so this file is the same on every machine.

pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import "weather.js" as Wx

Singleton {
  id: root

  // ── where ────────────────────────────────────────────────────────────
  // NaN rather than 0 for "not known yet": 0,0 is a real coordinate in the
  // Atlantic and open-meteo will happily forecast for it.
  property real lat: NaN
  property real lon: NaN
  property string place: ""
  readonly property bool located: !isNaN(root.lat) && !isNaN(root.lon)

  // ── what ─────────────────────────────────────────────────────────────
  // null until the first reply lands, which is what `ready` is asking
  property var current: null
  property var days: []
  property var hours: []
  property double fetched: 0
  property bool loading: false
  // empty when the last attempt worked; a short line to put on the pane when
  // it did not
  property string error: ""
  readonly property bool ready: root.current !== null

  // °F is a display choice, toggled from the pane and remembered
  property bool fahrenheit: false
  readonly property string unit: root.fahrenheit ? "°F" : "°C"

  // how stale the forecast is allowed to get before an open re-fetches it
  readonly property int staleAfter: 10 * 60 * 1000

  // ── derived ──────────────────────────────────────────────────────────
  readonly property var today: root.days.length > 0 ? root.days[0] : null

  function dayFor(iso) {
    for (let i = 0; i < root.days.length; ++i)
      if (root.days[i].date === iso) return root.days[i];
    return null;
  }

  // the next half day, starting from the hour the current reading is in
  readonly property var nextHours:
    root.current === null ? [] : Wx.hoursFrom(root.hours, root.current.stamp, 12)
  readonly property var hourlyCurve:
    Wx.normalize(root.nextHours.map((h) => h.temp))

  function fmt(c) { return Wx.temp(c, root.fahrenheit); }

  function toggleUnits() {
    root.fahrenheit = !root.fahrenheit;
    root.savePlace();
  }

  // ── the requests ─────────────────────────────────────────────────────
  // curl rather than XMLHttpRequest: it is the same shape every other network
  // call in this shell already has, it takes a timeout, and a QML http stack
  // failure is much harder to see than a non-zero exit.
  function refresh() {
    if (root.loading) return;
    if (!root.located) { root.locate(); return; }
    root.loading = true;
    fetchProc.command = ["curl", "-s", "--max-time", "12",
      Wx.forecastUrl(root.lat, root.lon)];
    fetchProc.running = true;
  }

  function refreshIfStale() {
    if (root.loading) return;
    if (!root.located) { root.locate(); return; }
    if (root.fetched === 0 || Date.now() - root.fetched > root.staleAfter)
      root.refresh();
  }

  function locate() {
    if (root.loading) return;
    root.loading = true;
    locateProc.command = ["curl", "-s", "--max-time", "10", Wx.locateUrl()];
    locateProc.running = true;
  }

  function onLocated(text) {
    root.loading = false;
    try {
      const j = JSON.parse(text);
      if (j.status !== "success") throw new Error("lookup declined");
      root.lat = j.lat;
      root.lon = j.lon;
      root.place = j.city && j.city !== "" ? j.city : "here";
      root.error = "";
      root.savePlace();
      root.refresh();
    } catch (e) {
      // Not fatal and not retried on a tight loop: the retry timer below has
      // it, and until then the pane offers the button rather than a spinner
      // that will never stop.
      root.error = "no location";
      retry.restart();
    }
  }

  function onForecast(text) {
    root.loading = false;
    try {
      const f = Wx.parseForecast(text);
      root.current = f.current;
      root.days = f.days;
      root.hours = f.hours;
      root.fetched = f.fetched;
      root.error = "";
      cacheFile.setText(text);
    } catch (e) {
      root.error = "no forecast";
      retry.restart();
    }
  }

  // Restoring the last reply rather than starting blank. A panel that opens
  // onto yesterday's numbers with "updated 9h ago" under them is honest and
  // useful; one that opens onto nothing while a fetch runs is neither.
  function loadCache() {
    const text = cacheFile.text();
    if (!text || text === "") return;
    try {
      const f = Wx.parseForecast(text);
      root.current = f.current;
      root.days = f.days;
      root.hours = f.hours;
      // the age of the FILE, not of this parse — otherwise a restart would
      // present a stale forecast as a fresh one and never re-fetch
      root.fetched = 0;
    } catch (e) {}
  }

  Process {
    id: fetchProc
    stdout: StdioCollector {
      id: fetchOut
      waitForEnd: true
      // curl exiting non-zero leaves this empty, which onForecast reads as the
      // failure it is — so there is one path out of a fetch, not two
      onStreamFinished: root.onForecast(fetchOut.text)
    }
  }

  Process {
    id: locateProc
    stdout: StdioCollector {
      id: locateOut
      waitForEnd: true
      onStreamFinished: root.onLocated(locateOut.text)
    }
  }

  // ── the schedule ─────────────────────────────────────────────────────
  Timer {
    id: poll
    interval: 15 * 60 * 1000
    repeat: true
    running: true
    onTriggered: root.refresh()
  }

  // one attempt a minute after a failure, rather than every fifteen — a
  // suspend/resume or a wifi drop should not cost a quarter of an hour of
  // blank pane
  Timer {
    id: retry
    interval: 60 * 1000
    onTriggered: root.refresh()
  }

  // ── persistence ──────────────────────────────────────────────────────
  FileView {
    id: placeFile
    path: Quickshell.statePath("weather-place.json")
    blockLoading: true
    printErrors: false
  }

  FileView {
    id: cacheFile
    path: Quickshell.statePath("weather-cache.json")
    blockLoading: true
    printErrors: false
  }

  function savePlace() {
    placeFile.setText(JSON.stringify({
      lat: root.lat, lon: root.lon, place: root.place,
      fahrenheit: root.fahrenheit
    }));
  }

  // Environment first, so a machine that knows where it is never asks the
  // network; then the cache; then the lookup.
  function resolvePlace() {
    const envLat = parseFloat(Quickshell.env("QS_WEATHER_LAT"));
    const envLon = parseFloat(Quickshell.env("QS_WEATHER_LON"));
    if (!isNaN(envLat) && !isNaN(envLon)) {
      root.lat = envLat;
      root.lon = envLon;
      root.place = Quickshell.env("QS_WEATHER_PLACE") || "here";
      return;
    }
    try {
      const j = JSON.parse(placeFile.text() || "{}");
      if (typeof j.lat === "number" && typeof j.lon === "number") {
        root.lat = j.lat;
        root.lon = j.lon;
        root.place = j.place ?? "here";
        root.fahrenheit = j.fahrenheit === true;
      }
    } catch (e) {}
  }

  Component.onCompleted: {
    root.resolvePlace();
    root.loadCache();
    // located or not, this does the right thing: it fetches, or it goes and
    // finds out where we are and then fetches
    root.refresh();
  }
}
