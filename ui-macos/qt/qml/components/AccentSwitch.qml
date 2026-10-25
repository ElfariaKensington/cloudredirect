import QtQuick
import QtQuick.Controls
import QtQuick.Templates as T

T.Switch {
    id: control
    implicitWidth: 54
    implicitHeight: 32

    indicator: Rectangle {
        implicitWidth: 52
        implicitHeight: 30
        x: control.leftPadding
        y: (control.height - height) / 2
        radius: height / 2
        color: control.checked ? "#afbfa4" : "#d5d5d5"
        border.color: control.checked ? "#899781" : "#c6c6c6"

        Rectangle {
            width: 24
            height: 24
            y: 3
            x: control.checked ? parent.width - width - 3 : 3
            radius: width / 2
            color: "#ffffff"
            border.color: "#25000000"
        }
    }
}
