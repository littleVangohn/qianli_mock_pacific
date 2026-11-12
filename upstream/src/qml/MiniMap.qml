import QtQuick 2.15

/* First-person minimap ported from Unity RuntimeMiniMap/OfficialHudBinder. */
Item {
    id: root
    width: 480
    height: 258
    readonly property var gameDataContext: typeof gameData !== "undefined" ? gameData : null
    property bool clickEnabled: false
    property int pendingMarkType: -1
    property string pendingMarkLabel: ""
    signal mapClicked(real x, real y)

    ListModel { id: markersModel }
    ListModel { id: commandMarkersModel }

    function reloadMarkersFromGameData() {
        markersModel.clear()
        if (!gameDataContext || !gameDataContext.miniMapMarkers) return
        var markers = gameDataContext.miniMapMarkers
        for (var i = 0; i < markers.length; ++i) markersModel.append(markers[i])
    }
    function setPendingMarkMode(markType, label) {
        pendingMarkType = Number(markType); pendingMarkLabel = String(label)
    }
    function clearPendingMarkMode() { pendingMarkType = -1; pendingMarkLabel = "" }
    function markerColor(t) {
        if (t === 1) return "#18D26E"
        if (t === 2) return "#15D7C7"
        if (t === 3) return "#FFB340"
        return "#F25B6A"
    }
    function addCommandMarker(x, y, markType, label) {
        commandMarkersModel.append({"normX": Math.max(0, Math.min(1, Number(x))),
            "normY": Math.max(0, Math.min(1, Number(y))), "markType": Number(markType)})
        commandMarkerTimer.restart()
    }

    Component.onCompleted: reloadMarkersFromGameData()
    Connections {
        target: root.gameDataContext
        function onRobotPositionUpdated() { root.reloadMarkersFromGameData() }
        function onRobotDataUpdated() { root.reloadMarkersFromGameData() }
    }

    Image {
        anchors.fill: parent
        source: "qrc:/images/mujoco-2026-map.png"
        fillMode: Image.Stretch
        smooth: true
    }
    Rectangle { anchors.fill: parent; color: "#D1F0FF"; opacity: 0.32 }

    Repeater {
        model: markersModel
        delegate: Item {
            id: marker
            required property int robotId
            required property real posX
            required property real posY
            required property real angle
            required property bool isDead
            required property int currentHP
            required property int maxHP
            readonly property real nx: Math.max(0, Math.min(1, (posX < 0 || posX > 1) ? posX / 28.0 : posX))
            readonly property real ny: Math.max(0, Math.min(1, (posY < 0 || posY > 1) ? 1.0 - posY / 15.0 : posY))
            readonly property real hpRatio: maxHP > 0 ? Math.max(0, Math.min(1, currentHP / maxHP)) : 0
            width: 32; height: 32
            x: nx * root.width - width / 2; y: ny * root.height - height / 2
            opacity: isDead ? 0.5 : 1.0

            Canvas {
                anchors.fill: parent; antialiasing: true
                onPaint: {
                    var ctx = getContext("2d"); ctx.reset(); ctx.clearRect(0, 0, width, height)
                    ctx.fillStyle = "#EFFAFF"; ctx.beginPath(); ctx.arc(16,16,16,0,Math.PI*2); ctx.fill()
                    ctx.fillStyle = "rgba(14,19,22,0.94)"; ctx.beginPath(); ctx.arc(16,16,13.5,0,Math.PI*2); ctx.fill()
                    if (marker.hpRatio > 0) {
                        ctx.fillStyle = "rgba(235,26,31,0.98)"; ctx.beginPath(); ctx.moveTo(16,16)
                        ctx.arc(16,16,13.5,-Math.PI/2,-Math.PI/2+Math.PI*2*marker.hpRatio); ctx.closePath(); ctx.fill()
                    }
                }
            }
            Text {
                anchors.centerIn: parent; text: marker.robotId; color: "white"
                font.pixelSize: 20; font.bold: true; font.family: "Arial"
            }
            Canvas {
                width: 14; height: 11; anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottom: parent.top; anchors.bottomMargin: -2; rotation: marker.angle
                onPaint: {
                    var ctx = getContext("2d"); ctx.reset(); ctx.fillStyle = "#00FFFF"
                    ctx.beginPath(); ctx.moveTo(7,0); ctx.lineTo(13,10); ctx.lineTo(7,7); ctx.lineTo(1,10); ctx.closePath(); ctx.fill()
                }
            }
        }
    }

    Repeater {
        model: commandMarkersModel
        delegate: Rectangle {
            required property real normX; required property real normY; required property int markType
            width: 18; height: 18; radius: 9
            x: normX * root.width - width / 2; y: normY * root.height - height / 2
            color: "transparent"; border.width: 2; border.color: root.markerColor(markType)
        }
    }
    Timer { id: commandMarkerTimer; interval: 1500; onTriggered: commandMarkersModel.clear() }
    MouseArea {
        anchors.fill: parent; enabled: root.clickEnabled
        onClicked: function(mouse) { root.mapClicked(mouse.x / width, mouse.y / height) }
    }
}
