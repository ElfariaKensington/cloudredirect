import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../components"

Page {
    background: Rectangle { color: palette.window }
    title: "Setup"

    Dialog {
        id: purgeDialog
        title: "Remove All Data"
        modal: true
        standardButtons: Dialog.NoButton
        anchors.centerIn: parent
        width: Math.min(parent.width - 80, 480)

        property int countdown: 5
        property bool canPurge: false

        Timer {
            id: purgeCountdownTimer
            interval: 1000
            repeat: true
            onTriggered: {
                purgeDialog.countdown--
                if (purgeDialog.countdown <= 0) {
                    purgeCountdownTimer.stop()
                    purgeDialog.canPurge = true
                }
            }
        }

        onOpened: {
            countdown = 5
            canPurge = false
            purgeCountdownTimer.start()
        }

        onClosed: {
            purgeCountdownTimer.stop()
        }

        ColumnLayout {
            anchors.fill: parent
            spacing: 10

            Label {
                text: "This will permanently remove:"
                font.bold: true
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
            }

            ColumnLayout {
                spacing: 2
                Layout.leftMargin: 12

                Label { text: (typeof macOSPort !== "undefined" ? "• CloudRedirect integration in Steam" : "• CloudRedirect from Steam (LD_AUDIT hook)"); opacity: 0.8; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                Label { text: (typeof macOSPort !== "undefined" ? "• The installed runtime and saved credentials" : "• cloud_redirect.so and CLI binary"); opacity: 0.8; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                Label { text: "• All configuration and settings"; opacity: 0.8; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                Label { text: "• OAuth tokens (Google Drive / OneDrive)"; opacity: 0.8; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                Label { text: "• All cached saves and cloud data"; opacity: 0.8; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                Label { text: "• Logs and backups"; opacity: 0.8; wrapMode: Text.WordWrap; Layout.fillWidth: true }
            }

            Label {
                text: "This cannot be undone. You will need to re-authenticate and re-deploy to use CloudRedirect again."
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
                opacity: 0.7
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: 4

                Item { Layout.fillWidth: true }

                Button {
                    text: "Cancel"
                    onClicked: purgeDialog.close()
                }

                Button {
                    text: purgeDialog.canPurge ? "Remove All Data" : "Remove (" + purgeDialog.countdown + ")"
                    enabled: purgeDialog.canPurge
                    onClicked: {
                        if (deployer) deployer.purgeAll()
                        purgeDialog.close()
                    }
                }
            }
        }
    }

    ScrollView {
        anchors.fill: parent
        contentWidth: availableWidth
        clip: true
        ColumnLayout {
            width: parent.width
            spacing: 12
            Item { height: 12 }
            Label { text: "Setup"; font.pixelSize: 24; font.weight: Font.Bold; Layout.leftMargin: 28 }
            Label { text: "Connect CloudRedirect to Steam and choose the games to sync."; color: palette.placeholderText; wrapMode: Text.WordWrap; Layout.fillWidth: true; Layout.leftMargin: 28; Layout.rightMargin: 28 }
            SectionHeading { text: "Steam integration"; Layout.leftMargin: 28 }
            SettingsGroup {
                Layout.fillWidth: true; Layout.leftMargin: 28; Layout.rightMargin: 28
                ColumnLayout {
                    width: parent.width; spacing: 16
                    SettingRow {
                        Layout.fillWidth: true; title: "Steam"
                        detail: deployer.slssteamInstalled ? "Installed on this Mac" : "Install Steam before continuing."
                        Image { source: "image://symbols/"+(deployer.slssteamInstalled ? "checkmark.circle.fill/34c759" : "exclamationmark.circle/ff9500"); sourceSize: Qt.size(36,36); Layout.preferredWidth: 18; Layout.preferredHeight: 18 }
                    }
                    Rectangle { Layout.fillWidth: true; height: 1; color: Qt.alpha(palette.text,0.08) }
                    SettingRow {
                        Layout.fillWidth: true; title: "CloudRedirect runtime"
                        detail: !deployer.alreadyDeployed ? "Install to enable syncing through Steam." : deployer.updateAvailable ? "An updated runtime is ready to install." : "Installed and up to date."
                        AccentButton { text: deployer.alreadyDeployed ? "Update" : "Install…"; visible: !deployer.alreadyDeployed || deployer.updateAvailable; enabled: deployer.slssteamInstalled; highlighted: true; onClicked: deployer.alreadyDeployed ? deployer.update() : deployer.deploy() }
                        Button { text: "Remove…"; visible: deployer.alreadyDeployed; onClicked: deployer.undeploy() }
                    }
                }
            }
            Label { text: deployer.statusMessage; visible: text.length > 0; color: palette.placeholderText; font.pixelSize: 12; Layout.fillWidth: true; Layout.leftMargin: 32; Layout.rightMargin: 32; wrapMode: Text.WordWrap }
            SectionHeading { text: "Managed games"; Layout.leftMargin: 28 }
            SettingsGroup {
                Layout.fillWidth: true; Layout.leftMargin: 28; Layout.rightMargin: 28
                ColumnLayout {
                    width: parent.width; spacing: 16
                    SettingRow {
                        Layout.fillWidth: true; title: "Cloud save redirection"; detail: "Use CloudRedirect for your managed games."
                        AccentSwitch { id: nativeEnabled; Accessible.name: "Cloud save redirection"; checked: backend.redirectEnabled() }
                    }
                    Rectangle { Layout.fillWidth: true; height: 1; color: Qt.alpha(palette.text,0.08) }
                    Label { text: "Additional game IDs"; font.weight: Font.Medium }
                    TextField { id: nativeGameIDs; Layout.fillWidth: true; placeholderText: "620, 848450, …"; text: backend.managedIDs(); Accessible.name: "Additional game IDs" }
                    Label { text: "Optional. Games in macSteam and self-unlocking Lua scripts are included automatically."; color: palette.placeholderText; font.pixelSize: 12; Layout.fillWidth: true; wrapMode: Text.WordWrap }
                    RowLayout {
                        Layout.fillWidth: true
                        Label { id: nativeResult; Layout.fillWidth: true; wrapMode: Text.WordWrap; color: palette.placeholderText; font.pixelSize: 12 }
                        AccentButton { text: "Save Changes"; onClicked: nativeResult.text = backend.saveManagedIDs(nativeGameIDs.text,nativeEnabled.checked) }
                    }
                }
            }
            Label { text: "Restart Steam after installing the runtime or changing managed games."; color: palette.placeholderText; font.pixelSize: 12; Layout.fillWidth: true; Layout.leftMargin: 32; Layout.rightMargin: 32; wrapMode: Text.WordWrap }
            SectionHeading { text: "Reset"; Layout.leftMargin: 28 }
            SettingsGroup {
                Layout.fillWidth: true; Layout.leftMargin: 28; Layout.rightMargin: 28
                SettingRow {
                    width: parent.width; title: "Remove CloudRedirect data"; detail: "Remove the runtime, credentials, settings, and local data."
                    Button { text: "Remove All Data…"; onClicked: purgeDialog.open() }
                }
            }
            Item { height: 24 }
        }
    }
}
