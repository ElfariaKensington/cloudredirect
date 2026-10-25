import QtQuick
import QtQuick.Controls
import QtQml.Models
import QtQuick.Layouts
import QtQuick.Templates as T
import "pages"

ApplicationWindow {
    id: root
    width: 1040
    height: 720
    minimumWidth: 780
    minimumHeight: 560
    visible: true
    color: "transparent"
    font.pixelSize: 13
    property int currentPage: 0
    property bool sidebarVisible: true
    readonly property var destinations: [
        {name: "Overview", symbol: "square.grid.2x2", section: "Library"},
        {name: "Games", symbol: "gamecontroller", section: ""},
        {name: "Backups", symbol: "clock.arrow.circlepath", section: ""},
        {name: "Cloud Provider", symbol: "cloud", section: "Sync"},
        {name: "Setup", symbol: "gearshape", section: ""},
        {name: "Stats & Scripts", symbol: "chart.bar", section: ""},
        {name: "Migration", symbol: "arrow.left.arrow.right", section: "Tools"},
        {name: "Manifest Pins", symbol: "pin", section: ""},
        {name: "Cloud Files", symbol: "externaldrive", section: ""}
    ]
    title: destinations[currentPage].name
    onSidebarVisibleChanged: nativeAppearance.setSidebarWidth(sidebarVisible ? 224 : 0)
    function refresh() {
        backend.refreshStatus()
        if (currentPage === 0 || currentPage === 1) backend.fetchRemoteApps()
        var page = pages.children[currentPage]
        if (page && typeof page.refresh === "function") page.refresh()
        if (page && typeof page.reloadApps === "function") page.reloadApps()
        if (page && typeof page.reloadBackups === "function") page.reloadBackups()
        if (currentPage === 4) deployer.checkPrerequisites()
    }
    Connections {
        target: nativeAppearance
        function onToggleSidebar() { root.sidebarVisible = !root.sidebarVisible }
        function onRefresh() { root.refresh() }
    }
    menuBar: MenuBar {
        Menu {
            id: viewMenu
            title: "View"
            Action { text: root.sidebarVisible ? "Hide Sidebar" : "Show Sidebar"; shortcut: "Ctrl+Meta+S"; onTriggered: root.sidebarVisible = !root.sidebarVisible }
            Action { text: "Refresh"; shortcut: StandardKey.Refresh; onTriggered: root.refresh() }
            MenuSeparator {}
            Instantiator {
                model: root.destinations
                delegate: Action { required property var modelData; required property int index; text: modelData.name; checkable: true; checked: root.currentPage === index; onTriggered: root.currentPage = index }
                onObjectAdded: (index, object) => viewMenu.insertAction(index + 3, object)
                onObjectRemoved: (index, object) => viewMenu.removeAction(object)
            }
        }
        Menu {
            title: "Help"
            Action { text: "Open Log"; onTriggered: backend.openLogFile() }
            Action { text: "Open Configuration Folder"; onTriggered: backend.openConfigFolder() }
        }
    }
    RowLayout {
        anchors.fill: parent
        spacing: 0
        Item {
            visible: root.sidebarVisible
            Layout.preferredWidth: 224
            Layout.fillHeight: true
            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 12
                spacing: 2
                Repeater {
                    model: root.destinations
                    ColumnLayout {
                        required property var modelData
                        required property int index
                        Layout.fillWidth: true
                        spacing: 4
                        Label {
                            visible: modelData.section !== ""
                            text: modelData.section
                            font.pixelSize: 11
                            font.weight: Font.DemiBold
                            color: palette.placeholderText
                            leftPadding: 10
                            topPadding: index === 0 ? 6 : 20
                            bottomPadding: 3
                        }
                        T.ItemDelegate {
                            hoverEnabled: true
                            activeFocusOnTab: true
                            id: row
                            Layout.fillWidth: true
                            implicitHeight: 34
                            highlighted: root.currentPage === index
                            text: modelData.name
                            Accessible.role: Accessible.Button
                            Accessible.name: modelData.name
                            Accessible.onPressAction: root.currentPage = index
                            onClicked: root.currentPage = index
                            background: Rectangle {
                                radius: 7
                                color: row.highlighted ? Qt.alpha(palette.highlight, 0.18) : row.hovered ? Qt.alpha(palette.text, 0.055) : "transparent"
                            }
                            contentItem: RowLayout {
                                spacing: 10
                                Image { source: "image://symbols/"+modelData.symbol+"/"+palette.highlight.toString().substring(1); sourceSize: Qt.size(36,36); Layout.preferredWidth: 18; Layout.preferredHeight: 18 }
                                Label { text: modelData.name; font.weight: row.highlighted ? Font.DemiBold : Font.Normal; Layout.fillWidth: true }
                            }
                        }
                    }
                }
                Item { Layout.fillHeight: true }
                Label { text: "CloudRedirect"; font.weight: Font.Medium; leftPadding: 10; color: palette.placeholderText; font.pixelSize: 11 }
                Label { text: "v"+backend.version; leftPadding: 10; color: palette.placeholderText; font.pixelSize: 10; bottomPadding: 4 }
            }
        }
        Rectangle { visible: root.sidebarVisible; Layout.fillHeight: true; implicitWidth: 1; color: Qt.alpha(palette.text,0.09) }
        Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            color: palette.window
            StackLayout {
                id: pages
                anchors.fill: parent
                currentIndex: root.currentPage
                DashboardPage { onNavigate: (destination) => root.currentPage = destination }
                AppsPage {}
                BackupsPage {}
                CloudProviderPage {}
                SetupPage {}
                StatsPage {}
                MigrationPage {}
                ManifestPage {}
                SteamCloudPage {}
            }
        }
    }
}
