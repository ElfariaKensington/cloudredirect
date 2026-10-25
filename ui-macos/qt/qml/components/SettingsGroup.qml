import QtQuick
import QtQuick.Templates as T
T.Frame {
    implicitWidth: implicitContentWidth + leftPadding + rightPadding
    implicitHeight: implicitContentHeight + topPadding + bottomPadding
    padding: 16
    background: Rectangle {
        color: palette.base
        radius: 10
        border.width: 1
        border.color: Qt.alpha(palette.text, 0.07)
    }
}
