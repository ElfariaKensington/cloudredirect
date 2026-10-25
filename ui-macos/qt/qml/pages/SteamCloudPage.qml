import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../components"
Page {
    id: page
    background: Rectangle { color: palette.window }
    property var files: []
    property var selected: ({})
    property bool busy: false
    property string status: "Choose a game to view the saves in your cloud provider."
    property var games: backend.cloudGames()
    readonly property bool community: sourcePicker.currentIndex === 1
    readonly property int selectedAppId: community ? 760 : (gamePicker.currentIndex >= 0 && gamePicker.currentIndex < games.length ? games[gamePicker.currentIndex].appId : 0)
    onSelectedAppIdChanged: { files=[];selected={};status="Select a game, then click Refresh." }
    onCommunityChanged: {files=[];selected={};status=community ? "Steam Community storage is separate from your CloudRedirect saves." : "Choose a game with cloud saves."}
    function refresh() {
        if(!selectedAppId)return
        busy=true
        if(community)backend.steamCloudList(760)
        else backend.cloudSaveList(selectedAppId)
    }
    function selectedNames() { var names=[];for(var key in selected)if(selected[key])names.push(key);return names }
    Connections {
        target: backend
        function onAppsChanged() { page.games=backend.cloudGames() }
        function onRemoteAppsFetched() { page.games=backend.cloudGames() }
        function onAppNamesResolved() { page.games=backend.cloudGames() }
        function onSteamCloudFinished(result,error) {
            busy=false
            if(error!==""){status=error;return}
            if(result.appId!==page.selectedAppId || (result.source==="provider")===page.community)return
            if(result.deleted){status="Deletion completed.";refresh();return}
            files=result.files;selected={}
            status=result.source==="provider" ? files.length+" file(s) · "+backend.formatSize(result.totalSize)+" in "+backend.providerLabel(backend.providerName) : files.length+" file(s) in Steam Community storage."
        }
    }
    Dialog {
        id: confirmDelete
        title: "Delete Steam Community Files"
        modal: true
        anchors.centerIn: parent
        standardButtons: Dialog.Yes|Dialog.No
        onAboutToShow: deleteMessage.text="Permanently delete "+page.selectedNames().length+" selected file(s) from Steam Community storage?"
        Label {id: deleteMessage;wrapMode: Text.WordWrap;width: 400}
        onAccepted: {busy=true;backend.steamCloudDelete(760,page.selectedNames())}
    }
    ColumnLayout {
        anchors.fill: parent;anchors.margins: 28;spacing: 12
        Label {text: "Cloud Files";font.pixelSize: 24;font.weight: Font.Bold}
        Label {text: community ? "Manage files stored directly in Steam Community." : "Save files stored in "+backend.providerLabel(backend.providerName)+" by CloudRedirect.";color: palette.placeholderText;wrapMode: Text.WordWrap;Layout.fillWidth: true}
        RowLayout {
            Layout.fillWidth: true
            ComboBox {
                id: sourcePicker;enabled: !busy;Layout.preferredWidth: 180
                model: [backend.providerLabel(backend.providerName),"Steam Community"]
                Accessible.name: "Cloud storage"
            }
            ComboBox {
                id: gamePicker;visible: !community;Layout.fillWidth: true;enabled: !busy
                model: page.games;textRole: "label";Accessible.name: "Game"
                displayText: games.length ? currentText : "No cloud games found"
                onActivated: {files=[];selected={};refresh()}
            }
            Button {text: "Refresh";enabled: !busy&&selectedAppId>0;onClicked: refresh()}
        }
        RowLayout {
            visible: community
            Button {text: "Select All";enabled: !busy;onClicked: {var copy={};for(var i=0;i<files.length;i++)copy[files[i].name]=true;selected=copy}}
            Button {text: "Clear Selection";enabled: !busy;onClicked: selected={}}
            Button {text: "Delete Selected…";enabled: !busy&&selectedNames().length>0;onClicked: confirmDelete.open()}
            Button {text: "Steam Console…";onClicked: Qt.openUrlExternally("steam://open/console")}
        }
        SettingsGroup {
            Layout.fillHeight: true;Layout.fillWidth: true;padding: 4
            ScrollView {
                anchors.fill: parent;clip: true
                ListView {
                    model: page.files
                    delegate: ItemDelegate {
                        required property var modelData
                        width: ListView.view.width
                        text: modelData.name+"  ·  "+backend.formatSize(modelData.size)
                        highlighted: page.community&&page.selected[modelData.name]===true
                        enabled: !page.busy
                        onClicked: {if(page.community){var copy=Object.assign({},page.selected);copy[modelData.name]=!copy[modelData.name];page.selected=copy}}
                    }
                }
            }
            BusyIndicator {anchors.centerIn: parent;running: page.busy;visible: running}
            Label {anchors.centerIn: parent;visible: !page.busy&&page.files.length===0;text: "No files loaded";color: palette.placeholderText}
        }
        Label {text: status;font.pixelSize: 12;color: palette.placeholderText;textFormat: Text.PlainText;wrapMode: Text.WordWrap;Layout.fillWidth: true}
    }
}
