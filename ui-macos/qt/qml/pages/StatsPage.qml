import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../components"
Page {
    background: Rectangle { color: palette.window }
    ScrollView {
        anchors.fill: parent
        contentWidth: availableWidth
        clip: true
        ColumnLayout {
            width: parent.width
            spacing: 12
            Item { height: 12 }
            Label { text: "Stats & Scripts"; font.pixelSize: 24; font.weight: Font.Bold; Layout.leftMargin: 28 }
            Label { text: "Bring achievements, playtime, and Lua scripts across devices."; color: palette.placeholderText; wrapMode: Text.WordWrap; Layout.fillWidth: true; Layout.leftMargin: 28; Layout.rightMargin: 28 }
            SectionHeading { text: "Game activity"; Layout.leftMargin: 28 }
            SettingsGroup {
                Layout.fillWidth: true; Layout.leftMargin: 28; Layout.rightMargin: 28
                ColumnLayout {
                    width: parent.width; spacing: 16
                    SettingRow {
                        Layout.fillWidth: true; title: "Sync game activity"; detail: "Use your configured cloud provider."
                        Switch { Accessible.name: "Sync game activity"; checked: backend.statsSyncEnabled; onToggled: backend.statsSyncEnabled = checked }
                    }
                    Rectangle { Layout.fillWidth: true; height: 1; color: Qt.alpha(palette.text,0.08) }
                    SettingRow {
                        Layout.fillWidth: true; title: "Achievements"; detail: "Sync unlocked achievements for managed games."; enabled: backend.statsSyncEnabled
                        Switch { Accessible.name: "Achievements"; checked: backend.syncAchievements; onToggled: backend.syncAchievements = checked }
                    }
                    Rectangle { Layout.fillWidth: true; height: 1; color: Qt.alpha(palette.text,0.08) }
                    SettingRow {
                        Layout.fillWidth: true; title: "Playtime"; detail: "Merge game sessions across devices."; enabled: backend.statsSyncEnabled
                        Switch { Accessible.name: "Playtime"; checked: backend.syncPlaytime; onToggled: backend.syncPlaytime = checked }
                    }
                }
            }
            Label { text: "Achievement and playtime sync are experimental. Keep a backup of your data."; color: palette.placeholderText; font.pixelSize: 12; wrapMode: Text.WordWrap; Layout.fillWidth: true; Layout.leftMargin: 32; Layout.rightMargin: 32 }
            SectionHeading { text: "Lua scripts"; Layout.leftMargin: 28 }
            SettingsGroup {
                Layout.fillWidth: true; Layout.leftMargin: 28; Layout.rightMargin: 28
                SettingRow {
                    width: parent.width; title: "Sync scripts"; detail: "Merge Lua scripts with the cloud archive. Existing scripts are kept."
                    Switch { Accessible.name: "Sync scripts"; checked: backend.syncLuas; onToggled: backend.syncLuas = checked }
                }
            }
            Label { text: "Restart Steam after changing sync settings."; color: palette.placeholderText; font.pixelSize: 12; Layout.leftMargin: 32; Layout.rightMargin: 32; Layout.fillWidth: true; wrapMode: Text.WordWrap }
            Item { height: 24 }
        }
    }
}
