// ┌─┐┌─┐┌┐┌┬ ┬┌─┐┬─┐┬┌─┌─┐
// ┌─┘├┤ │││││││ │├┬┘├┴┐└─┐
// └─┘└─┘┘└┘└┴┘└─┘┴└─┴ ┴└─┘
// https://github.com/kbuckleys/

import QtQuick
import Quickshell.Io
import "../morpheus"

Item {
  id: root

  required property string path
  property bool running: false
  signal done(string text)

  Process {
    id: proc
    stdout: StdioCollector {
      id: out
      waitForEnd: true
      onStreamFinished: {
        root.done(out.text);
        root.running = false;
      }
    }
  }

  onRunningChanged: {
    if (root.running && !proc.running) {
      proc.command = ["cat", root.path];
      proc.running = true;
    } else if (!root.running && proc.running) {
      proc.running = false;
    }
  }
}
