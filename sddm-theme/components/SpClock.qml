//
// [maya-hm] components/SpClock.qml
// Win11-style date/clock: big light date + live time. QtQuick 2.0 only.
// API kept compatible: value, tColor, tFont alias + use24Hour switch.

import QtQuick 2.0


Item {
  id: sp_clock

  property date value: new Date()
  property bool use24Hour: false

  property color tColor: "white"
  property alias tFont: sp_clock_text.font

  property string timeText: ""
  property string dateText: ""

  implicitWidth: Math.max(sp_clock_date.implicitWidth, sp_clock_text.implicitWidth)
  implicitHeight: sp_clock_date.implicitHeight + sp_clock_text.implicitHeight + 6

  function refresh() {
    var d = sp_clock.value
    var hours = d.getHours()
    var minutes = d.getMinutes()
    var suffix = ""
    if (!sp_clock.use24Hour) {
      suffix = (hours >= 12) ? " PM" : " AM"
      hours = hours % 12
      if (hours === 0)
        hours = 12
    }
    var mm = (minutes < 10 ? "0" : "") + minutes
    sp_clock.timeText = hours + ":" + mm + suffix
    try {
      sp_clock.dateText = Qt.formatDate(d, "dddd, d MMMM")
    } catch (e) {
      sp_clock.dateText = Qt.formatDateTime(d, "dddd, dd MMMM")
    }
  }

  onValueChanged: refresh()
  onUse24HourChanged: refresh()
  Component.onCompleted: refresh()

  Timer {
    interval: 1000
    running: true
    repeat: true
    onTriggered: sp_clock.value = new Date()
  }

  Column {
    anchors.centerIn: parent
    spacing: 2

    Text {
      id: sp_clock_date

      anchors.horizontalCenter: parent.horizontalCenter
      text: sp_clock.dateText
      color: sp_clock.tColor
      opacity: 0.92

      font.pixelSize: 20
      font.weight: Font.Light

      horizontalAlignment: Text.AlignHCenter
    }

    Text {
      id: sp_clock_text

      anchors.horizontalCenter: parent.horizontalCenter
      text: sp_clock.timeText
      color: sp_clock.tColor

      font.pixelSize: 84
      font.weight: Font.Light

      horizontalAlignment: Text.AlignHCenter
      verticalAlignment: Text.AlignVCenter
    }
  }
}
