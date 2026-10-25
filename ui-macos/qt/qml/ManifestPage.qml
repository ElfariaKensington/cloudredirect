import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
Page {
    id: page
    property bool loading: true
    property bool pinning: false
    property bool autoComment: true
    property var selected: ({})
    property var apps: []
    property string status: ""
    function persist() {
        if(loading)return
        var ids=[];for(var id in selected)if(selected[id])ids.push(Number(id))
        status=backend.saveManifestSettings(pinning,autoComment,ids)
    }
    function refresh(){apps=backend.manifestApps()}
    Component.onCompleted: {
        var settings=backend.manifestSettings();pinning=settings.enabled;autoComment=settings.autoComment
        var ids={};for(var i=0;i<settings.pinnedApps.length;i++)ids[String(settings.pinnedApps[i])]=true
        selected=ids;refresh();loading=false
    }
    ColumnLayout {
        anchors.fill: parent;anchors.margins: 20;spacing: 12
        Label {text: "Manifest Pinning";font.pointSize: 16;font.bold: true}
        Switch {text: "Enable manifest pinning";checked: page.pinning;onToggled: {page.pinning=checked;persist()}}
        Switch {text: "Ignore Lua manifest pins unless the app is selected below";checked: page.autoComment;onToggled: {page.autoComment=checked;persist()}}
        Label {text: "Pins come from setManifestid lines in Steam/config/stplug-in/*.lua. Manifest IDs remain exact 64-bit values. Restart Steam after changing these settings.";wrapMode: Text.WordWrap;Layout.fillWidth: true}
        RowLayout {Button {text: "Open Lua Folder";onClicked: backend.openLuaFolder()} Button {text: "Refresh";onClicked: refresh()}}
        ScrollView {
            Layout.fillWidth: true;Layout.fillHeight: true;clip: true
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
        Label {text: status;wrapMode: Text.WordWrap;Layout.fillWidth: true}
    }
}
