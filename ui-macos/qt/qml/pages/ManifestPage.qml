import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../components"
Page {
    id: page
    background: Rectangle { color: palette.window }
    property bool loading: true
    property bool pinning: false
    property bool autoComment: true
    property var selected: ({})
    property var apps: []
    property string status: ""
    function persist() {
        if (loading) return
        var ids=[]; for(var id in selected) if(selected[id]) ids.push(Number(id))
        status=backend.saveManifestSettings(pinning,autoComment,ids)
    }
    function refresh() { apps=backend.manifestApps() }
    Component.onCompleted: {
        var settings=backend.manifestSettings(); pinning=settings.enabled; autoComment=settings.autoComment
        var ids={}; for(var i=0;i<settings.pinnedApps.length;i++) ids[String(settings.pinnedApps[i])]=true
        selected=ids; refresh(); loading=false
    }
    ColumnLayout {
        anchors.fill: parent; anchors.margins: 28; spacing: 12
        Label { text: "Manifest Pins"; font.pixelSize: 24; font.weight: Font.Bold }
        Label { text: "Keep selected games on the depot versions specified in their Lua scripts."; color: palette.placeholderText; wrapMode: Text.WordWrap; Layout.fillWidth: true }
        SettingsGroup {
            Layout.fillWidth: true
            ColumnLayout {
                width: parent.width; spacing: 16
                SettingRow {
                    Layout.fillWidth: true; title: "Pin depot versions"; detail: "Apply manifest IDs when Steam resolves game depots."
                    Switch { Accessible.name: "Pin depot versions"; checked: page.pinning; onToggled: {page.pinning=checked;persist()} }
                }
                Rectangle { Layout.fillWidth: true; height: 1; color: Qt.alpha(palette.text,0.08) }
                SettingRow {
                    Layout.fillWidth: true; title: "Selected games only"; detail: "Ignore manifest pins from unselected Lua scripts."
                    Switch { Accessible.name: "Selected games only"; checked: page.autoComment; onToggled: {page.autoComment=checked;persist()} }
                }
            }
        }
        RowLayout {
            Layout.fillWidth: true
            SectionHeading { text: "Games"; Layout.fillWidth: true }
            Button { text: "Lua Folder…"; onClicked: backend.openLuaFolder() }
            Button { text: "Refresh"; onClicked: refresh() }
        }
        SettingsGroup {
            Layout.fillWidth: true; Layout.fillHeight: true; padding: 4
            ScrollView {
                anchors.fill: parent; clip: true
                ListView {
                    model: page.apps
                    delegate: CheckDelegate {
                        required property var modelData
                        width: ListView.view.width
                        text: modelData.name+"  ·  "+modelData.appId+"  ·  "+modelData.pins+" depot pin(s)"
                        checked: page.selected[String(modelData.appId)]===true
                        onToggled: {var copy=Object.assign({},page.selected);copy[String(modelData.appId)]=checked;page.selected=copy;persist()}
                    }
                }
            }
            Label { anchors.centerIn: parent; visible: page.apps.length === 0; text: "No Lua scripts found"; color: palette.placeholderText }
        }
        Label { text: status.length > 0 ? status : "Changes are saved automatically. Restart Steam to apply them."; color: palette.placeholderText; font.pixelSize: 12; wrapMode: Text.WordWrap; Layout.fillWidth: true }
    }
}
