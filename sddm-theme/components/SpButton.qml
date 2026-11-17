//
// [maya-hm] components/SpButton.qml
// Win11-style circular glass icon button (QtQuick 2.0 only, no Controls/Effects).

import QtQuick 2.0

Item {
  id: sp_button

  property bool enabled: true

  // Keyboard focus: KeyNavigation.tab/backtab puts activeFocus on this
  // item - the ring below shows focus like the input fields.
  focus: true

  property color focusRingColor: Qt.rgba(1, 1, 1, 0.55)

  property alias icon: sp_button_icon.source
  property alias label: sp_button_label.text
  property alias font: sp_button_label.font

  // Glass look: translucent fill + hairline border. Colors kept as API so
  // existing Main.qml keeps working; defaults are Win11-like.
  property color iconColor: Qt.rgba(1, 1, 1, 0.08)
  property color labelColor: "#ffffff"

  property color hoverIconColor: Qt.rgba(1, 1, 1, 0.16)
  property color hoverLabelColor: "#ffffff"

  property color pressIconColor: Qt.rgba(1, 1, 1, 0.05)
  property color pressLabelColor: "#dddddd"

  property color disableColor: Qt.rgba(1, 1, 1, 0.25)

  // Hover label (tooltip pill above the button, e.g. "Reboot"/"Shutdown").
  // Empty = no tooltip.
  property string tooltip: ""

  signal pressed()
  signal released()
  signal clicked()

  implicitWidth: button_row.implicitWidth
  implicitHeight: 44

  Row {
    id: button_row
    anchors.centerIn: parent
    spacing: 10

    Rectangle {
      id: sp_button_bg

      width: 44
      height: 44
      radius: 22

      color: iconColor
      border.color: Qt.rgba(1, 1, 1, 0.14)
      border.width: 1

      Behavior on color { ColorAnimation { duration: 180 } }

      Image {
        id: sp_button_icon

        anchors.centerIn: parent
        width: 22
        height: 22

        // No placeholder icon: this theme ships none.
        source: ""

        fillMode: Image.Pad
        horizontalAlignment: Image.AlignHCenter
        verticalAlignment: Image.AlignVCenter
        opacity: sp_button.enabled ? 0.92 : 0.35
      }
    }

    Text {
      id: sp_button_label

      height: 44

      text: ""
      color: labelColor
      opacity: sp_button.enabled ? 0.92 : 0.4

      font.pixelSize: 15

      verticalAlignment: Text.AlignVCenter

      Behavior on color { ColorAnimation { duration: 180 } }
    }
  }

  // Keyboard focus ring (like input fields): lights up on tab focus,
  // tooltip pill stays a hover thing.
  Rectangle {
    id: sp_focus_ring
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.bottom: parent.bottom
    anchors.bottomMargin: 0
    width: button_row.width
    height: 2
    radius: 1
    color: focusRingColor
    visible: sp_button.activeFocus && sp_button.enabled
  }

  // Hover tooltip pill above the button (only when tooltip set + hover).
  Rectangle {
    id: sp_tooltip
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.bottom: button_row.top
    anchors.bottomMargin: 8
    width: sp_tooltip_text.implicitWidth + 24
    height: 30
    radius: 15
    color: Qt.rgba(0, 0, 0, 0.85)
    border.color: Qt.rgba(1, 1, 1, 0.18)
    border.width: 1
    visible: sp_button.tooltip !== "" && sp_button.state === "hover"
    Text {
      id: sp_tooltip_text
      anchors.centerIn: parent
      text: sp_button.tooltip
      color: "white"
      font.pixelSize: 13
    }
  }

  states: [
    State {
      name: "disabled"
      when: (sp_button.enabled === false)

      PropertyChanges { target: sp_button_bg; color: Qt.rgba(1, 1, 1, 0.04) }
      PropertyChanges { target: sp_button_label; color: disableColor }
    },
    State {
      name: "hover"
      PropertyChanges { target: sp_button_label; color: hoverLabelColor }
      PropertyChanges { target: sp_button_bg; color: hoverIconColor }
    },
    State {
      name: "pressed"
      PropertyChanges { target: sp_button_label; color: pressLabelColor }
      PropertyChanges { target: sp_button_bg; color: pressIconColor }
    }
  ]

  transitions: [
    Transition {
      from: ""
      to: "hover"
      ColorAnimation { duration: 180 }
    },
    Transition {
      from: ""
      to: "pressed"
      ColorAnimation { duration: 60 }
    },
    Transition {
      from: "disabled"
      to: ""
      ColorAnimation { duration: 120 }
    }
  ]

  MouseArea {
    anchors.fill: sp_button
    enabled: sp_button.enabled

    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton
    onEntered: { if (sp_button.enabled) sp_button.state = "hover" }
    onExited: { sp_button.state = "" }
    onPressed: {
      if (!sp_button.enabled) return
      sp_button.state = "pressed"
      sp_button.pressed()
    }
    onClicked: { if (sp_button.enabled) sp_button.clicked() }
    onReleased: {
      if (!sp_button.enabled) {
        sp_button.state = "disabled"
        return
      }
      sp_button.state = containsMouse ? "hover" : ""
      sp_button.released()
    }
  }

  Keys.onPressed: {
    if (!sp_button.enabled)
      return
    if ((event.key === Qt.Key_Return) || (event.key === Qt.Key_Enter) || (event.key === Qt.Key_Space)) {
      sp_button.clicked()
      event.accepted = true
    }
  }
}
