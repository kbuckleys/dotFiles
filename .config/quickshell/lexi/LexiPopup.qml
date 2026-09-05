// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/

import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Widgets
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import "lexi.js" as Lexicon
import "../morpheus"

PanelWindow {
  id: popup

  WlrLayershell.layer: WlrLayer.Overlay

  property bool shown: false
  property bool morphMode: false
  // 0..1, driven by shell.qml, which owns the crossfade schedule: 0 until the
  // pill's own row has finished clearing, then rising to 1 as the pill
  // finishes taking this layer's shape
  property real morphFade: 1
  property real showFactor: 0
  property bool collapsing: false
  // Morphed, the panel IS the pill: derive the scale from the pill's own live
  // animated size so the two are locked frame-for-frame, instead of each
  // running its own entrance animation against the other. Standalone there is
  // no pill to carry the motion, so the scale-up entrance stays.
  readonly property real morphScaleX: (popup.morphMode && popup.statusbar && panel.width > 0)
    ? popup.statusbar.width / panel.width : 1
  readonly property real morphScaleY: (popup.morphMode && popup.statusbar && panel.height > 0)
    ? popup.statusbar.height / panel.height : 1
  readonly property real panelX: popup.morphMode ? popup.morphScaleX
    : (popup.collapsing ? 0.985 + 0.015 * popup.showFactor
                        : 0.94 + 0.06 * popup.showFactor)
  readonly property real panelY: popup.morphMode ? popup.morphScaleY
    : (popup.collapsing ? 0.82 + 0.18 * popup.showFactor
                        : 0.90 + 0.10 * popup.showFactor)
  // Morphed, the handover is timed off the PILL's progress, not this popup's
  // own showFactor: showFactor is OutCubic and front-loaded, so it crossed the
  // threshold ~25ms in and this layer's content faded up on top of a morpheus
  // row that was still 80% opaque.
  // Math.min, not morphFade alone. Handing the pill straight to another
  // layer leaves morphFade pinned at 1 — the pill never un-morphs, so there
  // is nothing to ease it down — and this layer stayed fully opaque until its
  // window simply blinked out. Its own closeAnim is already easing
  // showFactor to 0, so taking the lower of the two fades it out on the way
  // between layers while leaving the normal open schedule untouched.
  readonly property real contentFade: popup.morphMode
    ? Math.min(popup.morphFade, popup.showFactor) : popup.showFactor

  property var statusbar: null

  readonly property color bgColor: Zenon.layerBg
  readonly property color borderColor: Zenon.surface
  readonly property color msgColor: Zenon.headBg
  readonly property color msgBorder: Zenon.msgBorder
  readonly property color fgColor: Zenon.white
  readonly property color headColor: Zenon.cyan
  readonly property color keyColor: Zenon.keyInk
  readonly property color dimColor: Zenon.muted
  readonly property color exColor: Zenon.pink
  readonly property color errColor: Zenon.red
  readonly property color selColor: Zenon.selBg

  // appMode: which tool is active · view: screen within the tool
  property string appMode: "dict"
  property string view: "input"

  // dictionary state
  property string dictQuery: ""
  property string query: ""
  property bool dictLoading: false
  property int lookupSeq: 0
  property var dictResult: null
  property string dictError: ""
  property var dictRows: []
  property var dictHist: []

  // translate state
  property bool swapping: false
  property string transText: ""
  property var live: null            // { translation, roman, source } | { error }
  property int liveSeq: 0
  property var targetLang: ({ code: "en", name: "English" })
  property var transHist: []
  property var usageMap: ({})

  // shared list state
  property var langRows: []
  // what the picker actually shows. `query` is the same free-typing buffer
  // the history view filters with — the picker is another focus-less list,
  // so it gets the same treatment rather than a second input field.
  readonly property var langFiltered: Lexicon.filterLangs(popup.langRows, popup.query)
  property int sel: 0

  // environment probes
  property string playerCmd: ""
  property string clipCmd: ""

  readonly property bool wide: popup.view === "results"
  readonly property int maxBodyH: 520

  component HintBar: Item {
    id: hintBarRoot
    height: 30
    property var rows: popup.hints()
    Row {
      anchors.centerIn: parent
      spacing: 22
      Repeater {
        model: hintBarRoot.rows
        Text {
          required property var modelData
          text: "<b><span style=\"color:" + popup.keyColor + ";\">" +
            Strings.escapeHtml(modelData[0]) + "</span></b> <span style=\"color:" +
            popup.dimColor + ";\">" + Strings.escapeHtml(modelData[1]) + "</span>"
          textFormat: Text.RichText
          font.family: "JetBrainsMono Nerd Font Propo"
          font.pixelSize: 15
        }
      }
    }
  }

  visible: popup.showFactor > 0.01
  color: "transparent"

  anchors { left: true; right: true; top: true; bottom: true }
  focusable: true
  exclusionMode: ExclusionMode.Ignore

  NumberAnimation {
    id: openAnim
    target: popup; property: "showFactor"
    to: 1; duration: Zenon.slow; easing.type: Zenon.ease
  }

  NumberAnimation {
    id: closeAnim
    target: popup; property: "showFactor"
    to: 0; duration: Zenon.slow; easing.type: Zenon.ease
    onFinished: popup.shown = false
  }

  HyprlandFocusGrab {
    id: grab
    windows: [ popup ]
    active: popup.shown
    onCleared: popup.closePopup()
  }

  IpcHandler {
    target: "Lexi"
    function toggle() { popup.toggle(); }

    function translate() { popup.openPopup("trans"); }
  }

  // ------------------------------------------------------------- procs --

  Process {
    id: rDictHist
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: popup.onRead("dicthist", text)
    }
  }

  Process {
    id: rTransHist
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: popup.onRead("transhist", text)
    }
  }

  Process {
    id: rUsage
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: popup.onRead("usage", text)
    }
  }

  Process {
    id: writeProc
    onExited: popup.drainWrite()
  }
  property var writeQueue: []

  Process {
    id: probeProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        const parts = text.trim().split("\n---\n");
        if (parts.length === 2) {
          popup.playerCmd = parts[0].trim();
          popup.clipCmd = parts[1].trim();
        }
      }
    }
  }

  function readCaches() {
    rDictHist.command = ["cat", Lexicon.dictHistoryPath()];
    rDictHist.running = true;
    rTransHist.command = ["cat", Lexicon.transHistoryPath()];
    rTransHist.running = true;
    rUsage.command = ["cat", Lexicon.usagePath()];
    rUsage.running = true;
  }

  function onRead(purpose, text) {
    if (purpose === "dicthist") {
      popup.dictHist = Lexicon.parseDictHistory(text);
    } else if (purpose === "transhist") {
      popup.transHist = Lexicon.parseTransHistory(text);
    } else if (purpose === "usage") {
      popup.usageMap = Lexicon.parseUsage(text);
      popup.langRows = Lexicon.rankedLangs(popup.usageMap);
    }
  }

  function writeFile(path, content) {
    popup.writeQueue.push({ path: path, content: content });
    popup.drainWrite();
  }

  function drainWrite() {
    if (popup.writeQueue.length === 0 || writeProc.running) return;
    const job = popup.writeQueue.shift();
    writeProc.command = ["sh", "-c",
      "printf '%s' " + Strings.shellQuote(job.content) + " > " + Strings.shellQuote(job.path)];
    writeProc.running = true;
  }

  function detach(script) {
    if (script) Quickshell.execDetached(["bash", "-c", script]);
  }

  // ------------------------------------------------------------ open --

  function openPopup(mode) {
    popup.appMode = mode || "dict";
    popup.shown = true;
    popup.collapsing = false;
    popup.view = "input";
    popup.sel = 0;
    popup.stopAudio();

    // fresh session: nothing carried over from the previous run
    popup.dictQuery = "";
    wordInput.text = "";
    popup.dictResult = null;
    popup.dictRows = [];
    popup.dictError = "";
    popup.dictLoading = false;
    popup.lookupSeq++;          // invalidate any in-flight look-up
    liveTimer.stop();
    tArea.text = "";
    popup.transText = "";
    popup.live = null;
    popup.liveSeq++;

    readCaches();

    focusRetry.counter = 0;
    focusRetry.restart();
    closeAnim.stop();
    popup.showFactor = 0;
    openAnim.restart();
    popup.syncFocus();
  }

  function closePopup() {
    popup.stopAudio();
    popup.collapsing = true;
    openAnim.stop();
    closeAnim.restart();
  }

  function toggle() {
    if (popup.shown) popup.closePopup();
    else popup.openPopup();
  }

  function toggleMode() {
    popup.stopAudio();
    popup.appMode = popup.appMode === "dict" ? "trans" : "dict";
    popup.view = "input";
    popup.syncFocus();
  }

  function syncFocus() {
    Qt.callLater(() => {
      if (!popup.shown) return;
      if (popup.view === "input" && popup.appMode === "dict") wordInput.forceActiveFocus();
      else if (popup.view === "input") tArea.forceActiveFocus();
      else bgRoot.forceActiveFocus();
    });
  }

  // --------------------------------------------------------- hints --

  function hints() {
    if (popup.view === "picker")
      return [["type", "filter"], ["return", "pick"],
              ["backspace", "back"], ["esc", "close"]];
    if (popup.view === "history") {
      return [
        ["return", popup.appMode === "dict" ? "re-look up" : "re-translate"],
        ["delete", "remove"],
        ["tab", popup.appMode === "dict" ? "translate" : "dictionary"],
        ["esc", "back"],
      ];
    }
    if (popup.view === "results") {
      const h = [];
      if (popup.dictResult && popup.dictResult.audio && popup.playerCmd !== "")
        h.push(["space", "play"]);
      h.push(["tab", "translate"], ["backspace", "back"], ["esc", "close"]);
      return h;
    }
    return popup.appMode === "dict"
      ? [["return", "define / history"], ["esc", "clear · close"], ["tab", "translate"]]
      : [["return", "play"], ["shift return", "language"], ["esc", "clear · close"],
         ["alt s", "swap"], ["tab", "dictionary"]];
  }

  // ---------------------------------------------------- dictionary --

  function startLookup(word) {
    popup.dictQuery = word;
    popup.dictLoading = true;
    popup.dictError = "";
    popup.dictResult = null;
    popup.view = "results";
    popup.syncFocus();

    const seq = ++popup.lookupSeq;
    Lexicon.resolveWord(word).then(
      (res) => popup.onDictResolved(seq, res),
      (err) => popup.onDictFailed(seq, err)
    );
  }

  function onDictResolved(seq, res) {
    if (seq !== popup.lookupSeq || !popup.shown) return;
    popup.dictLoading = false;

    const result = Lexicon.entryToResult(res);
    popup.dictResult = result;
    popup.dictRows = popup.buildDictRows(result);
    if (result.corrected) popup.dictQuery = result.title;

    popup.dictHist = Lexicon.addDictHistory(popup.dictHist, result.title);
    popup.writeFile(Lexicon.dictHistoryPath(),
      Lexicon.serializeDictHistory(popup.dictHist));

    if (result.audio && popup.playerCmd !== "") {
      popup.prefetchDictAudio(result.audio.file);
    }
  }

  function onDictFailed(seq, err) {
    if (seq !== popup.lookupSeq || !popup.shown) return;
    popup.dictLoading = false;
    popup.dictError = err === "network"
      ? "Network error — couldn't reach Wiktionary"
      : "No definitions found for \"" + popup.dictQuery + "\". Check spelling?";
  }

  function buildDictRows(res) {
    const rows = [];
    for (const group of res.pos) {
      rows.push({ kind: "pos", text: Strings.escapeHtml(group.name) });
      for (const d of group.defs) {
        const label = d.label ? "(" + d.label + ") " : "";
        const lab = label
          ? "<span style=\"color:" + popup.dimColor + ";font-style:italic;\">" +
            Strings.escapeHtml(label) + "</span>"
          : "";
        rows.push({ kind: "def", text: lab + Strings.escapeHtml(d.def) });
        if (d.example)
          rows.push({ kind: "ex", text: Strings.escapeHtml(d.example) });
      }
    }
    if (res.synonyms && res.synonyms.length > 0) {
      rows.push({ kind: "syn", text: "<b>Synonyms:</b> " +
        Strings.escapeHtml(res.synonyms.join(", ")) });
    }
    return rows;
  }

  property string dictAudioPath: "/tmp/qslexicon-dict.audio"

  function prefetchDictAudio(file) {
    const url = Lexicon.WIKT_AUDIO_BASE + encodeURIComponent(file);
    popup.detach("rm -f " + Strings.shellQuote(popup.dictAudioPath) +
      " " + Strings.shellQuote(popup.dictAudioPath + ".part") + " && " +
      "curl -sL --max-time 10 -A " + Strings.shellQuote(Lexicon.UA) + " " +
      Strings.shellQuote(url) + " -o " +
      Strings.shellQuote(popup.dictAudioPath + ".part") + " && mv -f " +
      Strings.shellQuote(popup.dictAudioPath + ".part") + " " +
      Strings.shellQuote(popup.dictAudioPath));
  }

  function playDictAudio() {
    if (popup.playerCmd === "" || !popup.dictResult || !popup.dictResult.audio) return;
    popup.detach(Lexicon.audioPlayScript(popup.dictAudioPath, popup.playerCmd));
  }

  // ------------------------------------------------------ translate --

  Timer {
    id: liveTimer
    interval: 350
    onTriggered: popup.doLive()
  }

  function scheduleLive() {
    if (!popup.shown || popup.appMode !== "trans" || popup.view !== "input") return;
    liveTimer.restart();
  }

  function doLive() {
    const raw = popup.transText.trim();
    if (!Lexicon.hasContent(raw)) {
      popup.live = null;
      return;
    }
    const split = Lexicon.splitSourcePrefix(raw);
    const seq = ++popup.liveSeq;
    const rq = Lexicon.translateRequest(split.text, popup.targetLangCode(), split.source);

    let req = new XMLHttpRequest();
    req.open("POST", rq.url);
    req.setRequestHeader("Content-Type", "application/x-www-form-urlencoded");
    req.onreadystatechange = () => {
      if (req.readyState !== XMLHttpRequest.DONE) return;
      if (seq !== popup.liveSeq) return;
      if (req.status !== 200) {
        popup.live = { error: true };
        return;
      }
      const parsed = Lexicon.parseTranslateResponse(req.responseText);
      popup.live = parsed || { error: true };
    };
    req.send(rq.body);
  }

  function targetLangCode() {
    return popup.targetLang ? popup.targetLang.code : "en";
  }

  function openPicker() {
    popup.view = "picker";
    popup.query = "";
    popup.sel = 0;
    popup.followSelection();
    popup.syncFocus();
  }

  // Leaving the picker without picking. Deliberately not goBack(): that
  // clears the input you came from, and the picker is a detour off the
  // translate screen rather than an output screen you are finished with.
  function closePicker() {
    popup.query = "";
    popup.view = "input";
    popup.sel = 0;
    popup.syncFocus();
  }

  // Return with input: pick a language, then refresh the live output half
  // in that language. No separate results screen — auto-translate is always
  // visible under the input.
  function confirmLanguage() {
    if (popup.langFiltered.length === 0) return;
    const lang = popup.langFiltered[Math.min(popup.sel, popup.langFiltered.length - 1)];
    popup.targetLang = { code: lang.code, name: lang.name };
    popup.usageMap[lang.code] = (popup.usageMap[lang.code] || 0) + 1;
    popup.writeFile(Lexicon.usagePath(), Lexicon.serializeUsage(popup.usageMap));

    popup.query = "";
    popup.view = "input";
    popup.syncFocus();

    const raw = popup.transText.trim();
    if (!Lexicon.hasContent(raw)) {
      doLive();
      return;
    }
    const split = Lexicon.splitSourcePrefix(raw);
    doTranslate(split.text, lang.code, split.source);
  }

  function doTranslate(text, code, source) {
    const seq = ++popup.liveSeq;
    const rq = Lexicon.translateRequest(text, code, source);

    let req = new XMLHttpRequest();
    req.open("POST", rq.url);
    req.setRequestHeader("Content-Type", "application/x-www-form-urlencoded");
    req.onreadystatechange = () => {
      if (req.readyState !== XMLHttpRequest.DONE) return;
      if (seq !== popup.liveSeq) return;
      const parsed = req.status === 200
        ? Lexicon.parseTranslateResponse(req.responseText) : null;
      if (!parsed) {
        popup.live = { error: true };
        return;
      }
      popup.live = parsed;

      popup.transHist = Lexicon.addTransHistory(
        popup.transHist, code, source, text, parsed.translation);
      popup.writeFile(Lexicon.transHistoryPath(),
        Lexicon.serializeTransHistory(popup.transHist));
    };
    req.send(rq.body);
  }

  function retranslateHistory(entry) {
    popup.targetLang = { code: entry.code, name: Lexicon.sourceName(entry.code) };
    popup.transText = entry.text;
    tArea.text = entry.text;
    popup.view = "input";
    popup.syncFocus();
    doTranslate(entry.text, entry.code, entry.source);
  }

  property string activePrefix: ""

  function stopAudio() {
    // Kill only the running playback's own prefix; a broad "qslexicon-"
    // pattern races against freshly spawned scripts and kills them instead.
    if (popup.activePrefix !== "") {
      popup.detach("pkill -f " + Strings.shellQuote(popup.activePrefix) +
        " >/dev/null 2>&1");
    }
    popup.activePrefix = "";
  }

  // Return in translate: speak the live translation; press again to stop.

  // Reverse the language pair, like Google Translate's swap button:
  // english → arabic becomes arabic → english. The textarea takes the
  // translation, the detected source becomes the new target language, and
  // the old input becomes the new live output. Return then speaks whichever
  // side is the current output.
  function toggleSwap() {
    if (!popup.live || popup.live.error ||
        !Lexicon.hasContent(popup.live.translation) || !popup.live.source) {
      return;
    }

    popup.stopAudio();
    popup.swapping = true;

    const newInput = popup.live.translation;
    const newTarget = {
      code: popup.live.source,
      name: Lexicon.sourceName(popup.live.source),
    };
    const newLive = {
      translation: Lexicon.splitSourcePrefix(popup.transText.trim()).text,
      roman: null,
      source: popup.targetLang.code,
    };

    tArea.text = newInput;
    popup.transText = newInput;
    popup.targetLang = newTarget;
    popup.liveSeq++;
    popup.live = newLive;

    popup.usageMap[newTarget.code] = (popup.usageMap[newTarget.code] || 0) + 1;
    popup.writeFile(Lexicon.usagePath(), Lexicon.serializeUsage(popup.usageMap));
    popup.transHist = Lexicon.addTransHistory(
      popup.transHist, newTarget.code, null, newInput, newLive.translation);
    popup.writeFile(Lexicon.transHistoryPath(),
      Lexicon.serializeTransHistory(popup.transHist));

    popup.swapping = false;
  }

  function clearTranslate() {
    popup.stopAudio();
    tArea.text = "";
    popup.transText = "";
    popup.live = null;
  }

  function speakLive() {
    // One press always (re)starts: any playing pipeline is killed first.
    popup.stopAudio();
    const text = popup.live ? popup.live.translation : "";
    const code = popup.targetLang.code;
    if (!Lexicon.hasContent(text) || !code) return;
    if (popup.playerCmd === "") return;
    const prefix = "qslexicon-" + Date.now();
    popup.activePrefix = prefix;
    popup.detach(Lexicon.ttsScript(prefix, text, code, popup.playerCmd));
  }

  // -------------------------------------------------------- history --

  function historyModel() {
    if (popup.view !== "history") {
      // outside history return display strings so histList delegate (text: modelData)
      // never receives a QVariantMap -> QML warnings. Length still reflects
      // underlying history size.
      if (popup.appMode === "dict") return popup.dictHist.slice();
      return popup.transHist.map((e) => Lexicon.transHistoryRow(e));
    }
    const q = (popup.query || "").toLowerCase();
    if (popup.appMode === "dict") {
      if (!q) return popup.dictHist.filter((w) => typeof w === "string");
      return popup.dictHist.filter((w) =>
        typeof w === "string" && w.toLowerCase().indexOf(q) >= 0);
    }
    const rows = popup.transHist.map((e) => Lexicon.transHistoryRow(e));
    if (!q) return rows;
    return rows.filter((s) => s.toLowerCase().indexOf(q) >= 0);
  }

  function deleteSelected() {
    if (popup.view !== "history") return;
    if (popup.appMode === "dict") {
      const filtered = popup.historyModel();
      if (popup.sel >= filtered.length) return;
      const word = filtered[popup.sel];
      popup.dictHist = Lexicon.removeDictHistory(popup.dictHist, word);
      popup.writeFile(Lexicon.dictHistoryPath(),
        Lexicon.serializeDictHistory(popup.dictHist));
    } else {
      const q = (popup.query || "").toLowerCase();
      const filtered = q === ""
        ? popup.transHist.slice()
        : popup.transHist.filter((e) => Lexicon.transHistoryRow(e).toLowerCase().indexOf(q) >= 0);
      if (popup.sel >= filtered.length) return;
      const e = filtered[popup.sel];
      popup.transHist = Lexicon.removeTransHistory(popup.transHist, e.code, e.text);
      popup.writeFile(Lexicon.transHistoryPath(),
        Lexicon.serializeTransHistory(popup.transHist));
    }
    popup.clampSel();
  }

  function activateHistory() {
    if (popup.appMode === "dict") {
      const filtered = popup.historyModel();
      if (popup.sel >= filtered.length) return;
      popup.startLookup(filtered[popup.sel]);
    } else {
      const q = (popup.query || "").toLowerCase();
      const filtered = q === ""
        ? popup.transHist.slice()
        : popup.transHist.filter((e) => Lexicon.transHistoryRow(e).toLowerCase().indexOf(q) >= 0);
      if (popup.sel >= filtered.length) return;
      popup.retranslateHistory(filtered[popup.sel]);
    }
  }

  // How many rows the view on screen is showing. moveSel and clampSel both
  // need it, and they disagreed the moment the picker got a filter of its
  // own: clamping against the history model left the selection past the end
  // of a narrowed language list.
  function selLength() {
    return popup.view === "picker"
      ? popup.langFiltered.length : popup.historyModel().length;
  }

  function clampSel() {
    const len = popup.selLength();
    if (len === 0) popup.sel = 0;
    else popup.sel = Math.max(0, Math.min(popup.sel, len - 1));
    popup.followSelection();
  }

  function followSelection() {
    Qt.callLater(() => {
      pickerList.positionViewAtIndex(popup.sel, ListView.Contain);
      histList.positionViewAtIndex(popup.sel, ListView.Contain);
    });
  }

  // ----------------------------------------------------------- keys --

  function translateReturnKey(shift) {
    if (shift) popup.openPicker();
    else popup.handleReturn();
  }

  function handleReturn() {
    if (popup.view === "input") {
      if (popup.appMode === "dict") {
        const q = wordInput.text.trim();
        if (q === "") {
          popup.query = "";
          popup.view = "history";
          popup.sel = 0;
          popup.clampSel();
          popup.syncFocus();
        } else {
          popup.startLookup(q);
        }
      } else {
        const t = popup.transText.trim();
        if (!Lexicon.hasContent(t)) {
          popup.query = "";
          popup.view = "history";
          popup.sel = 0;
          popup.clampSel();
          popup.syncFocus();
        } else {
          popup.speakLive();
        }
      }
    } else if (popup.view === "picker") {
      popup.confirmLanguage();
    } else if (popup.view === "history") {
      popup.activateHistory();
    } else {
      // dict results: Return opens the look-up history
      popup.stopAudio();
      popup.query = "";
      popup.view = "history";
      popup.sel = 0;
      popup.clampSel();
      popup.syncFocus();
    }
  }

  function goBack() {
    popup.stopAudio();
    // leaving an output screen starts a fresh query
    popup.query = "";
    popup.dictQuery = "";
    wordInput.text = "";
    popup.dictResult = null;
    popup.dictRows = [];
    popup.dictError = "";
    popup.dictLoading = false;
    liveTimer.stop();
    tArea.text = "";
    popup.transText = "";
    popup.live = null;
    popup.view = "input";
    popup.syncFocus();
  }

  function moveSel(delta) {
    const len = popup.selLength();
    if (len === 0) return;
    popup.sel = ((popup.sel + delta) % len + len) % len;
    popup.followSelection();
  }

  // ---------------------------------------------------------- panel --

  MouseArea {
    anchors.fill: parent
    z: 0
    onClicked: popup.closePopup()
  }

  Item {
    id: panel
    width: popup.wide ? 1000 : 800
    height: popup.calcHeight()
    // Zenon.slow is the pill's own width/height easing in shell.qml
    Behavior on width { NumberAnimation { duration: Zenon.slow; easing.type: Zenon.ease } }
    Behavior on height { NumberAnimation { duration: Zenon.slow; easing.type: Zenon.ease } }
    anchors {
      horizontalCenter: parent.horizontalCenter
      bottom: parent.bottom
      bottomMargin: Zenon.bottomLift(popup.morphMode, popup.screen, popup.statusbar)
    }
    z: 1
    opacity: popup.contentFade
    transform: Scale {
      origin.x: panel.width / 2
      origin.y: panel.height
      xScale: popup.panelX
      yScale: popup.panelY
    }

    MouseArea { anchors.fill: parent }

    LayerShadow {
      panel: bgRoot
      cornerRadius: Zenon.pillRadius
      morphed: popup.morphMode
    }

    // ClippingRectangle, not Rectangle + clip: true. Qt's own clip is
    // RECTANGULAR — it clips to the bounding box and knows nothing about the
    // radius — so every square child painted to the panel's edge (the bottom
    // strip most visibly) filled in the rounded corners behind it. This one
    // clips to the rounded shape itself.
    ClippingRectangle {
      id: bgRoot
      anchors.fill: parent
      // Grown by its own border: a ClippingRectangle insets its children by
      // border.width on every side, so the content box came out 2px smaller
      // than the panel and any layout measured against the panel's size fell
      // one row or one column short. This hands the content its full box back.
      anchors.margins: -bgRoot.border.width
      color: popup.morphMode ? "transparent" : popup.bgColor
      radius: Zenon.pillRadius
      topLeftRadius: Zenon.pillRadius
      topRightRadius: Zenon.pillRadius
      bottomLeftRadius: Zenon.pillRadius
      bottomRightRadius: Zenon.pillRadius
      border.color: popup.morphMode ? "transparent" : popup.borderColor
      border.width: 1
      focus: true

      // -------------------------------------------------- dict input --

      Item {
        id: dictInputView
        anchors.fill: parent
        visible: opacity > 0.01
        opacity: popup.view === "input" && popup.appMode === "dict" ? 1 : 0
        x: popup.view === "input" && popup.appMode === "dict" ? 0 : -24
        Behavior on opacity { NumberAnimation { duration: Zenon.normal; easing.type: Zenon.ease } }
        Behavior on x { NumberAnimation { duration: Zenon.normal; easing.type: Zenon.ease } }

        Column {
          anchors.fill: parent

          Item {
            width: parent.width
            height: 38
            Text {
              anchors.top: parent.top
              anchors.topMargin: 14
              anchors.horizontalCenter: parent.horizontalCenter
              text: Lexicon.ICON_HEAD
              color: popup.headColor
              font.family: "JetBrainsMono Nerd Font Propo"
              font.pixelSize: 18
            }
          }

          HintBar { width: parent.width }

          Item {
            width: parent.width
            height: 54

            TextInput {
              id: wordInput
              anchors.fill: parent
              horizontalAlignment: TextInput.AlignHCenter
              onTextChanged: popup.query = text
              verticalAlignment: TextInput.AlignVCenter
              color: popup.headColor
              selectionColor: popup.headColor
              selectedTextColor: "#000000"
              font.family: "JetBrainsMono Nerd Font Propo"
              font.weight: 600
              font.pixelSize: 18
              cursorVisible: activeFocus
              cursorDelegate: Item {}
              clip: true
              Keys.forwardTo: bgRoot

              Rectangle {
                id: dictPulse
                anchors.left: parent.left
                anchors.leftMargin: Math.min((parent.width + parent.contentWidth) / 2 + 2,
                                             parent.width - 5)
                anchors.verticalCenter: parent.verticalCenter
                width: 3
                height: 20
                radius: 1
                color: popup.headColor
                opacity: 0.25
                visible: wordInput.activeFocus
                SequentialAnimation on opacity {
                  running: wordInput.activeFocus
                  loops: Animation.Infinite
                  NumberAnimation { to: 1; duration: 550; easing.type: Easing.InOutSine }
                  NumberAnimation { to: 0.25; duration: 550; easing.type: Easing.InOutSine }
                }
              }
            }
          }
        }
      }

      // ------------------------------------------------- trans input --

      Item {
        id: transInputView
        anchors.fill: parent
        visible: opacity > 0.01
        opacity: popup.view === "input" && popup.appMode === "trans" ? 1 : 0
        x: popup.view === "input" && popup.appMode === "trans" ? 0 : 24
        Behavior on opacity { NumberAnimation { duration: Zenon.normal; easing.type: Zenon.ease } }
        Behavior on x { NumberAnimation { duration: Zenon.normal; easing.type: Zenon.ease } }

        Column {
          anchors.fill: parent

          Item {
            width: parent.width
            height: 38
            Text {
              anchors.top: parent.top
              anchors.topMargin: 14
              anchors.horizontalCenter: parent.horizontalCenter
              text: Lexicon.ICON_TRANSLATE
              color: popup.headColor
              font.family: "JetBrainsMono Nerd Font Propo"
              font.pixelSize: 18
            }
          }

          HintBar { width: parent.width }

          Item {
            width: parent.width
            height: popup.tAreaH()

            TextArea {
              id: tArea
              anchors.fill: parent
              anchors.leftMargin: 30
              anchors.rightMargin: 30
              wrapMode: TextArea.Wrap
              color: popup.headColor
              selectionColor: popup.headColor
              selectedTextColor: "#000000"
              placeholderText: "text to translate…"
              placeholderTextColor: popup.dimColor
              font.family: "JetBrainsMono Nerd Font Propo"
              font.weight: 600
              font.pixelSize: 18
              background: null
              cursorVisible: activeFocus
              cursorDelegate: Item {}
              clip: true
              Keys.forwardTo: bgRoot

              Rectangle {
                id: transPulse
                x: parent.cursorRectangle.x
                y: parent.cursorRectangle.y
                width: 3
                height: parent.cursorRectangle.height > 0 ? parent.cursorRectangle.height : 18
                radius: 1
                color: popup.headColor
                opacity: 0.25
                visible: tArea.activeFocus
                SequentialAnimation on opacity {
                  running: tArea.activeFocus
                  loops: Animation.Infinite
                  NumberAnimation { to: 1; duration: 550; easing.type: Easing.InOutSine }
                  NumberAnimation { to: 0.25; duration: 550; easing.type: Easing.InOutSine }
                }
              }
              Keys.priority: Keys.BeforeItem
              Keys.onPressed: (event) => {
                if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) {
                  event.accepted = true;
                  popup.translateReturnKey(event.modifiers & Qt.ShiftModifier);
                  return;
                }
                if (event.key === Qt.Key_Backspace &&
                    popup.view === "history" && !tArea.text) {
                  event.accepted = true;
                  popup.goBack();
                }
              }
              Keys.onTabPressed: (event) => {
                event.accepted = true;
                popup.toggleMode();
              }
              onTextChanged: {
                popup.transText = tArea.text;
                if (!popup.swapping) popup.scheduleLive();
              }
            }
          }

          Rectangle {
            width: parent.width
            height: 1
            color: popup.msgBorder
            visible: liveBlock.visible
          }

          Item {
            id: liveBlock
            width: parent.width
            height: visible ? liveCol.height : 0
            visible: popup.view === "input" && popup.live !== null && popup.appMode === "trans"

            Column {
              id: liveCol
              width: parent.width
              topPadding: 10
              bottomPadding: 20
              spacing: 4

              Text {
                width: parent.width
                visible: popup.live !== null && !popup.live.error
                horizontalAlignment: Text.AlignHCenter
                text: {
                  const det = popup.live && popup.live.source
                    ? Lexicon.sourceName(popup.live.source) : "auto";
                  return det + "  →  " + popup.targetLang.name;
                }
                color: popup.dimColor
                font.family: "JetBrainsMono Nerd Font Propo"
                font.weight: 500
                font.pixelSize: 16

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: popup.toggleSwap()
                }
              }

              Text {
                width: parent.width
                visible: popup.live !== null && popup.live.error === true
                horizontalAlignment: Text.AlignHCenter
                text: popup.live && popup.live.error
                  ? "no translation — check connection" : ""
                color: popup.errColor
                font.family: "JetBrainsMono Nerd Font Propo"
                font.weight: 500
                font.pixelSize: 16
              }

              Text {
                width: parent.width
                leftPadding: 30
                rightPadding: 30
                visible: popup.live !== null && !popup.live.error
                text: popup.live && !popup.live.error
                  ? "<b>" + Strings.escapeHtml(popup.live.translation) + "</b>" : ""
                color: popup.fgColor
                wrapMode: Text.WordWrap
                horizontalAlignment: Text.AlignHCenter
                textFormat: Text.RichText
                font.family: "JetBrainsMono Nerd Font Propo"
                font.weight: 500
                font.pixelSize: 17
              }

              Text {
                width: parent.width
                leftPadding: 30
                rightPadding: 30
                visible: popup.live !== null && !popup.live.error &&
                         popup.live.roman
                text: popup.live && popup.live.roman
                  ? "<i>" + Strings.escapeHtml(popup.live.roman) + "</i>" : ""
                color: popup.exColor
                wrapMode: Text.WordWrap
                horizontalAlignment: Text.AlignHCenter
                textFormat: Text.RichText
                font.family: "JetBrainsMono Nerd Font Propo"
                font.weight: 500
                font.pixelSize: 17
              }
            }
          }
        }
      }

      // -------------------------------------------------- dict results --

      Item {
        id: dictResView
        anchors.fill: parent
        visible: opacity > 0.01
        opacity: popup.view === "results" && popup.appMode === "dict" ? 1 : 0
        x: popup.view === "results" && popup.appMode === "dict" ? 0 : -24
        Behavior on opacity { NumberAnimation { duration: Zenon.normal; easing.type: Zenon.ease } }
        Behavior on x { NumberAnimation { duration: Zenon.normal; easing.type: Zenon.ease } }

        Column {
          anchors.fill: parent

          Rectangle {
            width: parent.width
            height: 74
            color: popup.msgColor

            Rectangle {
              anchors.bottom: parent.bottom
              anchors.left: parent.left
              anchors.right: parent.right
              height: 1
              color: popup.msgBorder
            }

            Column {
              anchors.fill: parent
              topPadding: 8

              Item {
                width: parent.width
                height: 32

                Row {
                  anchors.centerIn: parent
                  spacing: 10

                  Text {
                    text: Lexicon.ICON_HEAD
                    color: popup.headColor
                    anchors.verticalCenter: parent.verticalCenter
                    font.family: "JetBrainsMono Nerd Font Propo"
                    font.pixelSize: 19
                  }

                  Text {
                    text: popup.dictLoading
                      ? Strings.escapeHtml(popup.dictQuery) + " …"
                      : Strings.escapeHtml(popup.dictQuery)
                    color: popup.headColor
                    anchors.verticalCenter: parent.verticalCenter
                    font.family: "JetBrainsMono Nerd Font Propo"
                    font.weight: 600
                    font.pixelSize: 18
                  }

                  Item { width: 14; height: 1 }

                  Text {
                    visible: !popup.dictLoading && popup.dictResult &&
                             popup.dictResult.ipa
                    text: popup.dictResult ? popup.dictResult.ipa || "" : ""
                    color: popup.headColor
                    anchors.verticalCenter: parent.verticalCenter
                    font.family: "JetBrainsMono Nerd Font Propo"
                    font.weight: 600
                    font.pixelSize: 18
                  }

                  Text {
                    visible: !popup.dictLoading && popup.dictResult &&
                             popup.dictResult.audio && popup.playerCmd !== ""
                    text: Lexicon.ICON_AUDIO + " " +
                          (popup.dictResult && popup.dictResult.audio
                            ? popup.dictResult.audio.code || "" : "")
                    color: popup.headColor
                    anchors.verticalCenter: parent.verticalCenter
                    font.family: "JetBrainsMono Nerd Font Propo"
                    font.weight: 600
                    font.pixelSize: 18

                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: popup.playDictAudio()
                    }
                  }

                  Item { width: 16; height: 1 }

                  Text {
                    visible: !popup.dictLoading && popup.dictResult &&
                             popup.dictResult.corrected
                    text: Lexicon.ICON_CORRECTED + " CORRECTED"
                    color: popup.dimColor
                    font.italic: true
                    anchors.verticalCenter: parent.verticalCenter
                    font.family: "JetBrainsMono Nerd Font Propo"
                    font.pixelSize: 15
                  }
                }
              }

              HintBar { width: parent.width }
            }
          }

          Flickable {
            id: dictScroll
            width: parent.width
            height: popup.dictBodyH()
            clip: true
            contentWidth: width
            contentHeight: dictCol.height + 12

            Column {
              id: dictCol
              // wider side inset than the translate panes: definitions wrap to
              // several lines, and at 30 the text ran too close to the edge to
              // read as a body of prose
              x: 42
              y: 10
              width: parent.width - 84
              spacing: 3

              Text {
                visible: popup.dictError !== ""
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                topPadding: 20
                text: popup.dictError
                color: popup.errColor
                wrapMode: Text.WordWrap
                font.family: "JetBrainsMono Nerd Font Propo"
                font.pixelSize: 17
              }

              Repeater {
                model: popup.dictRows

                delegate: Text {
                  required property var modelData
                  required property int index
                  width: dictCol.width
                  topPadding: {
                    if (modelData.kind === "pos") return index === 0 ? 2 : 12;
                    if (modelData.kind === "syn") return 10;
                    return 0;
                  }
                  text: {
                    if (modelData.kind === "pos" || modelData.kind === "ex")
                      return "<i>" + modelData.text + "</i>";
                    return modelData.text;
                  }
                  color: modelData.kind === "pos" ? popup.dimColor :
                         modelData.kind === "ex" ? popup.exColor :
                         modelData.kind === "syn" ? popup.headColor :
                         popup.fgColor
                  horizontalAlignment: Text.AlignHCenter
                  wrapMode: Text.WordWrap
                  textFormat: Text.RichText
                  font.family: "JetBrainsMono Nerd Font Propo"
                  font.weight: 500
                  font.pixelSize: 17
                }
              }
            }
          }
        }
      }

      // ------------------------------------------------------- picker --

      Item {
        id: pickerView
        anchors.fill: parent
        visible: opacity > 0.01
        opacity: popup.view === "picker" ? 1 : 0
        x: popup.view === "picker" ? 0 : -24
        Behavior on opacity { NumberAnimation { duration: Zenon.normal; easing.type: Zenon.ease } }
        Behavior on x { NumberAnimation { duration: Zenon.normal; easing.type: Zenon.ease } }

        Column {
          anchors.fill: parent

          Rectangle {
            width: parent.width
            height: 72
            color: popup.msgColor

            Rectangle {
              anchors.bottom: parent.bottom
              anchors.left: parent.left
              anchors.right: parent.right
              height: 1
              color: popup.msgBorder
            }

            Column {
              anchors.fill: parent
              topPadding: 6

              Item {
                width: parent.width
                height: 32
                Text {
                  anchors.centerIn: parent
                  // the picker has no input field, so the title doubles as
                  // one — without it, typing filters an apparently static list
                  text: popup.query === "" ? "Translate to" : popup.query
                  color: popup.headColor
                  font.family: "JetBrainsMono Nerd Font Propo"
                  font.weight: 600
                  font.pixelSize: 18
                }
              }

              HintBar { width: parent.width }
            }
          }

          ListView {
            id: pickerList
            width: parent.width
            height: popup.listBodyH(popup.langFiltered.length)
            clip: true
            model: popup.langFiltered
            highlightMoveDuration: 120

            delegate: Item {
              required property var modelData
              required property int index
              width: pickerList.width
              height: 32

              Rectangle {
                anchors.fill: parent
                color: index === popup.sel ? popup.selColor : "transparent"
              }

              Text {
                anchors.centerIn: parent
                text: (modelData.used ? Lexicon.ICON_STAR + " " : "") +
                      modelData.name + " (" + modelData.code + ")"
                color: popup.fgColor
                opacity: index === popup.sel ? 1 : 0.85
                font.family: "JetBrainsMono Nerd Font Propo"
                font.weight: 500
                font.pixelSize: 17
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  popup.sel = index;
                  popup.confirmLanguage();
                }
              }
            }
          }
        }
      }

      // ------------------------------------------------------- history --

      Item {
        id: histView
        anchors.fill: parent
        visible: opacity > 0.01
        opacity: popup.view === "history" ? 1 : 0
        x: popup.view === "history" ? 0 : 24
        Behavior on opacity { NumberAnimation { duration: Zenon.normal; easing.type: Zenon.ease } }
        Behavior on x { NumberAnimation { duration: Zenon.normal; easing.type: Zenon.ease } }

        Column {
          anchors.fill: parent

          Rectangle {
            width: parent.width
            height: 72
            color: popup.msgColor

            Rectangle {
              anchors.bottom: parent.bottom
              anchors.left: parent.left
              anchors.right: parent.right
              height: 1
              color: popup.msgBorder
            }

            Column {
              anchors.fill: parent
              topPadding: 6

              Item {
                width: parent.width
                height: 26
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.verticalCenterOffset: 4
                  anchors.horizontalCenter: parent.horizontalCenter
                  text: popup.appMode === "dict" ? "Look-up history" : "Translation history"
                  color: popup.headColor
                  font.family: "JetBrainsMono Nerd Font Propo"
                  font.weight: 600
                  font.pixelSize: 18
                }
              }

              HintBar { width: parent.width }
            }
          }

          ListView {
            id: histList
            width: parent.width
            height: popup.listBodyH(popup.historyModel().length)
            clip: true
            model: popup.historyModel()
            highlightMoveDuration: 120

            delegate: Item {
              required property var modelData
              required property int index
              width: histList.width
              height: 32

              Rectangle {
                anchors.fill: parent
                color: index === popup.sel ? popup.selColor : "transparent"
              }

              Text {
                anchors.centerIn: parent
                text: modelData
                color: popup.fgColor
                opacity: index === popup.sel ? 1 : 0.85
                elide: Text.ElideMiddle
                width: Math.min(implicitWidth + 8, histList.width - 60)
                font.family: "JetBrainsMono Nerd Font Propo"
                font.weight: 500
                font.pixelSize: 17
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  popup.sel = index;
                  popup.activateHistory();
                }
              }
            }
          }
        }
      }



      // ------------------------------------------------------ keys --

    Keys.onEscapePressed: (event) => {
      event.accepted = true;
      if (popup.view === "picker") {
        // backspace is what steps back out of the picker; esc clears the
        // filter and then closes, the same cascade as every other layer
        if (popup.query !== "") popup.query = "";
        else popup.closePopup();
      } else if (popup.view === "history" || popup.view === "results") {
        popup.goBack();
      } else if (popup.view === "input" && popup.appMode === "dict" && wordInput.text !== "") {
        wordInput.text = "";
      } else if (popup.view === "input" && popup.appMode === "trans" && tArea.text !== "") {
        popup.clearTranslate();
      } else {
        popup.closePopup();
      }
    }


    Keys.onPressed: (event) => {
      if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) &&
          !((event.modifiers & Qt.ShiftModifier) &&
            popup.view === "results" && popup.appMode === "trans")) {
        event.accepted = true;
        if (popup.view === "input" && popup.appMode === "trans") {
          // shift picks the output language, plain speaks it
          if (!Lexicon.hasContent(popup.transText)) {
            popup.query = "";
            popup.view = "history";
            popup.sel = 0;
            popup.clampSel();
            popup.syncFocus();
          } else if (event.modifiers & Qt.ShiftModifier) {
            popup.openPicker();
          } else {
            popup.speakLive();
          }
        } else if (event.modifiers & Qt.ShiftModifier) {
          // shift+return anywhere else: language menu from translate results
          if (popup.appMode === "trans") popup.openPicker();
        } else {
          popup.handleReturn();
        }
      } else if (event.key === Qt.Key_S && (event.modifiers & Qt.AltModifier) &&
          popup.view === "input" && popup.appMode === "trans") {
        event.accepted = true;
        popup.toggleSwap();
      } else if (event.key === Qt.Key_Tab) {
        event.accepted = true;
        popup.toggleMode();
      } else if (event.key === Qt.Key_Space && popup.view === "results" && popup.appMode === "dict") {
        event.accepted = true;
        popup.playDictAudio();
      } else if (event.key === Qt.Key_Backspace &&
                 (popup.view === "results" || popup.view === "history" ||
                  popup.view === "picker")) {
        event.accepted = true;
        if (popup.view !== "results" && popup.query.length > 0) {
          const chars = Array.from(popup.query);
          chars.pop();
          popup.query = chars.join("");
          popup.clampSel();
        } else if (popup.view === "picker") {
          popup.closePicker();
        } else {
          popup.goBack();
        }
      } else if (event.key === Qt.Key_Delete && popup.view === "history") {
        event.accepted = true;
        popup.deleteSelected();
      } else if (event.key === Qt.Key_Up && (popup.view === "picker" || popup.view === "history")) {
        event.accepted = true;
        popup.moveSel(-1);
      } else if (event.key === Qt.Key_Down && (popup.view === "picker" || popup.view === "history")) {
        event.accepted = true;
        popup.moveSel(1);
      } else if (event.key === Qt.Key_PageUp &&
                 (popup.view === "picker" || popup.view === "history")) {
        event.accepted = true;
        popup.moveSel(-8);
      } else if (event.key === Qt.Key_PageDown &&
                 (popup.view === "picker" || popup.view === "history")) {
        event.accepted = true;
        popup.moveSel(8);
      } else if ((popup.view === "history" || popup.view === "picker") &&
                 event.text && event.text.length > 0 &&
                 !(event.modifiers & Qt.ControlModifier) &&
                 !(event.modifiers & Qt.AltModifier) &&
                 !(event.modifiers & Qt.MetaModifier) &&
                 event.key !== Qt.Key_Escape && event.key !== Qt.Key_Return &&
                 event.key !== Qt.Key_Enter && event.key !== Qt.Key_Tab &&
                 event.key !== Qt.Key_Backspace && event.key !== Qt.Key_Delete) {
        event.accepted = true;
        popup.query += event.text;
        popup.clampSel();
      }
    }
  }
  }

  // -------------------------------------------------------- helpers --

  function calcHeight() {
    if (popup.view === "input") {
      if (popup.appMode === "dict") return 134;
      let h = 36 + 30 + popup.tAreaH();
      if (popup.live !== null) h += liveCol.height + 9;
      return Math.min(h + 30, 500);
    }
    if (popup.view === "results")
      return 74 + popup.dictBodyH();
    if (popup.view === "picker")
      return 72 + popup.listBodyH(popup.langFiltered.length);
    return 72 + popup.listBodyH(popup.historyModel().length);
  }

  function tAreaH() {
    const lines = Math.max(1, Math.min(tArea.lineCount, 8));
    return lines * 26 + 22;
  }

  function dictBodyH() {
    if (popup.dictError !== "" && !popup.dictLoading) return 70;
    if (popup.dictLoading) return 48;
    return Math.min(dictCol.height + 22, popup.maxBodyH);
  }

  function listBodyH(count) {
    return count === 0 ? 44 : Math.min(count * 32, 480);
  }

  Timer {
    id: focusRetry
    interval: 60
    repeat: true
    onTriggered: {
      if (!popup.shown) {
        stop();
        return;
      }
      popup.syncFocus();
      if (wordInput.activeFocus || tArea.activeFocus ||
          (popup.view !== "input" && bgRoot.activeFocus)) stop();
      if (focusRetry.counter++ > 12) stop();
    }
    property int counter: 0
  }

  Component.onCompleted: {
    probeProc.command = ["sh", "-c",
      Lexicon.playerProbeCommand() + "; echo ---; " + Lexicon.clipboardProbeCommand()];
    probeProc.running = true;
  }
}
