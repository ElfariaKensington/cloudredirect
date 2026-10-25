import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
RowLayout {
    property string title
    property string detail
    default property alias controls: trailing.data
    spacing: 20
    ColumnLayout {
        Layout.fillWidth: true
        spacing: 4
        Label { text: title; font.weight: Font.Medium; Layout.fillWidth: true; wrapMode: Text.WordWrap }
        Label { text: detail; visible: text.length > 0; color: palette.placeholderText; font.pixelSize: 12; wrapMode: Text.WordWrap; Layout.fillWidth: true }
    }
    RowLayout { id: trailing; spacing: 8 }
}
