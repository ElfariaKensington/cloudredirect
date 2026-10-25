import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../components"

Page {
    signal navigate(int destination)
    background: Rectangle { color: palette.window }
    Component.onCompleted: backend.fetchRemoteApps()
    ScrollView {
        anchors.fill: parent
        contentWidth: availableWidth
        clip: true
        ColumnLayout {
            width: parent.width
            spacing: 18
            Item { height: 10 }
            ColumnLayout {
                Layout.fillWidth: true
                Layout.leftMargin: 32
                Layout.rightMargin: 32
                spacing: 5
                Label { text: "Your saves, together."; font.pixelSize: 26; font.weight: Font.Bold; Layout.fillWidth: true; wrapMode: Text.WordWrap }
                Label { text: "Manage game saves and sync across your devices."; color: palette.placeholderText; Layout.fillWidth: true; wrapMode: Text.WordWrap }
            }
            SettingsGroup {
                Layout.fillWidth: true
                Layout.leftMargin: 32
                Layout.rightMargin: 32
                padding: 22
                RowLayout {
                    width: parent.width
                    spacing: 18
                    Image { source: "image://symbols/icloud/"+palette.highlight.toString().substring(1); sourceSize: Qt.size(96,96); Layout.preferredWidth: 48; Layout.preferredHeight: 48 }
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 5
                        Label { text: backend.providerName === "local" ? "Choose where your saves live" : backend.providerLabel(backend.providerName); font.pixelSize: 17; font.weight: Font.DemiBold; Layout.fillWidth: true; wrapMode: Text.WordWrap }
                        Label { text: backend.providerName === "local" ? "Connect a cloud provider or a folder to get started." : backend.providerAuthenticated ? "Connected and ready to sync" : "Sign in to finish connecting"; color: palette.placeholderText; Layout.fillWidth: true; wrapMode: Text.WordWrap }
                    }
                    Button { text: backend.providerName === "local" ? "Connect…" : "Manage…"; onClicked: navigate(3) }
                }
            }
            RowLayout {
                Layout.fillWidth: true
                Layout.leftMargin: 32
                Layout.rightMargin: 32
                spacing: 14
                Repeater {
                    model: [
                        {label: "On this Mac", value: backend.managedAppCount, detail: "games with local saves", symbol: "internaldrive", destination: 1},
                        {label: "In the cloud", value: backend.remoteOnlyAppCount, detail: "games available to restore", symbol: "cloud", destination: 1}
                    ]
                    SettingsGroup {
                        required property var modelData
                        Layout.fillWidth: true
                        padding: 20
                        ColumnLayout {
                            width: parent.width
                            spacing: 8
                            RowLayout {
                                Layout.fillWidth: true
                                Label { text: modelData.label; color: palette.placeholderText; Layout.fillWidth: true }
                                Image { source: "image://symbols/"+modelData.symbol+"/"+palette.highlight.toString().substring(1); sourceSize: Qt.size(36,36); Layout.preferredWidth: 18; Layout.preferredHeight: 18 }
                            }
                            Label { text: modelData.value; font.pixelSize: 32; font.weight: Font.Light }
                            Label { text: modelData.detail; color: palette.placeholderText; font.pixelSize: 12; Layout.fillWidth: true; wrapMode: Text.WordWrap }
                        }
                    }
                }
            }
            ColumnLayout {
                Layout.fillWidth: true
                Layout.leftMargin: 32
                Layout.rightMargin: 32
                spacing: 8
                SectionHeading { text: "Steam integration" }
                SettingsGroup {
                    Layout.fillWidth: true
                    SettingRow {
                        width: parent.width
                        title: backend.deployed ? "Installed in Steam" : "Set up CloudRedirect"
                        detail: backend.deployed ? "Manage the runtime and the games you want to sync." : "Install the runtime to use CloudRedirect with Steam."
                        Button { text: "Open Setup…"; onClicked: navigate(4) }
                    }
                }
                SectionHeading { text: "Preferences" }
                SettingsGroup {
                    Layout.fillWidth: true
                    SettingRow {
                        width: parent.width
                        title: "Launch notifications"
                        detail: "Notify when CloudRedirect loads in Steam."
                        AccentSwitch { Accessible.name: "Launch notifications"; checked: backend.notificationsEnabled; onToggled: backend.notificationsEnabled = checked }
                    }
                }
                RowLayout {
                    Layout.topMargin: 8
                    Button { text: "Open Log…"; onClicked: backend.openLogFile() }
                    Button { text: "Configuration Folder…"; onClicked: backend.openConfigFolder() }
                }
            }
            Item { height: 24 }
        }
    }
}
