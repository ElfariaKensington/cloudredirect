import QtQuick
import QtQuick.Controls
import QtQuick.Templates as T

T.Button {
    id: control
    Accessible.name: text
    implicitWidth: Math.max(80, contentItem.implicitWidth + leftPadding + rightPadding)
    implicitHeight: 24
    leftPadding: 16
    rightPadding: 16

    background: Rectangle {
        radius: 8
        color: control.down ? "#98a88c" : control.hovered ? "#bac8b1" : "#afbfa4"
        border.color: "#899781"
        opacity: control.enabled ? 1 : 0.48
    }

    contentItem: Label {
        text: control.text
        font: control.font
        color: "#20251d"
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
    }
}
