import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../components"
Page {
    background: Rectangle { color: palette.window }
    id: page
    property var files: []
    property var selected: ({})
    property bool busy: false
    property string status: "Start Steam and sign in, then connect to an AppID. Default 760 is Steam Community cloud storage."
    function refresh() { busy=true; backend.steamCloudList(Number(appId.text)) }
    function selectedNames() { var names=[];for(var key in selected)if(selected[key])names.push(key);return names }
    Connections {
        target: backend
        function onSteamCloudFinished(result,error) {
            busy=false
            if(error!=""){status=error;return}
            if(result.deleted){status="Deletion completed.";refresh();return}
            files=result.files;selected={}
            status=files.length+" file(s). Account cloud: "+(result.accountEnabled?"enabled":"disabled")+". App cloud: "+(result.appEnabled?"enabled":"disabled")+". Available: "+backend.formatSize(result.availableBytes)+" / "+backend.formatSize(result.totalBytes)
        }
    }
    Dialog {
        id: confirmDelete
        title: "Delete Steam Cloud Files"
        modal: true
        anchors.centerIn: parent
        standardButtons: Dialog.Yes|Dialog.No
        Label {text: "Permanently delete "+page.selectedNames().length+" selected file(s) from AppID "+appId.text+"?";wrapMode: Text.WordWrap;width: 400}
        onAccepted: {busy=true;backend.steamCloudDelete(Number(appId.text),page.selectedNames())}
    }
    ColumnLayout {
        anchors.fill: parent;anchors.margins: 28;spacing: 12
        Label {text: "Steam Cloud File Manager";font.pixelSize: 24;font.weight: Font.Bold}
        RowLayout {
            Label {text: "AppID"}
            TextField {id: appId;text: "760";validator: IntValidator {bottom: 1;top: 2147483647} enabled: !busy;Layout.preferredWidth: 100}
            Button {text: "Connect";enabled: !busy&&appId.acceptableInput;onClicked: refresh()}
            Button {text: "Open Console…";onClicked: Qt.openUrlExternally("steam://open/console")}
        }
        RowLayout {
            Button {text: "Select All";enabled: !busy;onClicked: {var copy={};for(var i=0;i<files.length;i++)copy[files[i].name]=true;selected=copy}}
            Button {text: "Clear Selection";enabled: !busy;onClicked: selected={}}
            Button {text: "Delete Selected";enabled: !busy&&selectedNames().length>0;onClicked: confirmDelete.open()}
            BusyIndicator {running: busy;visible: busy;Layout.preferredHeight: 24;Layout.preferredWidth: 24}
        }
        SettingsGroup {
            Layout.fillHeight: true;Layout.fillWidth: true;padding: 4
            ScrollView {
                anchors.fill: parent;clip: true
            ListView {
                model: page.files
                delegate: CheckDelegate {
                    required property var modelData
                    width: ListView.view.width
                    text: modelData.name+"  ·  "+backend.formatSize(modelData.size)+(modelData.persisted?"  ·  persisted":"")
                    checked: page.selected[modelData.name]===true
                    enabled: !page.busy
                    onToggled: {var copy=Object.assign({},page.selected);copy[modelData.name]=checked;page.selected=copy}
                }
            }
        }
        }
        Label {text: status; font.pixelSize: 12; color: palette.placeholderText;textFormat: Text.PlainText;wrapMode: Text.WordWrap;Layout.fillWidth: true}
    }
}
