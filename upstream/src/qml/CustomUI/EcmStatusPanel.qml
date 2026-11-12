import QtQuick 2.15

/*
 * E3 机构状态（Byte 2/3 位域）。
 * 视觉沿用官方信号灯行：细线、绿/灰/红、一行一个状态，不用旧版的深色卡片。
 * 底盘模式不在这里重复，姿态盘下方已经有四模式文案。
 */
Item {
    id: root
    width: 250
    height: 164
    property var customData: ({})
    property bool hasData: false
    property bool stale: false

    readonly property color onColor: "#BBF189"
    readonly property color offColor: "#6D6D6D"
    readonly property color faultColor: "#EF3931"
    readonly property color labelColor: "#B8D6E6"
    readonly property color valueColor: "#E6F5FF"

    function flag(name) {
        return root.customData ? root.customData[name] === true : false
    }

    function stateText(value) {
        if (!root.hasData)
            return "--"
        return value ? "ON" : "OFF"
    }

    function stateColor(value, danger) {
        if (!root.hasData || root.stale)
            return offColor
        if (!value)
            return offColor
        return danger ? faultColor : onColor
    }

    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(0.02, 0.03, 0.05, 0.50)
        radius: 4
        border.width: 1
        border.color: Qt.rgba(1, 1, 1, 0.08)
    }

    Text {
        id: title
        x: 0; y: 2
        text: "机构状态"
        color: root.valueColor
        font.pixelSize: 13
        font.family: "Microsoft YaHei"
        font.bold: true
    }

    Text {
        anchors.right: parent.right
        y: 3
        text: !root.hasData ? "等待数据" : root.stale ? "失联" : ""
        color: !root.hasData ? "#788891" : "#E2B2B0"
        font.pixelSize: 11
        font.family: "Microsoft YaHei"
    }

    Column {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: title.bottom
        anchors.topMargin: 6
        spacing: 2

        Repeater {
            model: [
                { label: "摩擦轮",   key: "fricEnabled",      danger: false },
                { label: "拨弹轮",   key: "rammerEnabled",    danger: false },
                { label: "允许发射", key: "firePermitted",    danger: false },
                { label: "自动吊射", key: "autoLobActive",    danger: false },
                { label: "电控故障", key: "electricalFault",  danger: true  },
                { label: "底盘警告", key: "chassisWarning",   danger: true  }
            ]

            delegate: Row {
                required property var modelData
                width: parent.width
                height: 20
                spacing: 8

                Text {
                    width: 90
                    text: modelData.label
                    color: root.labelColor
                    font.pixelSize: 13
                    font.family: "Microsoft YaHei"
                    anchors.verticalCenter: parent.verticalCenter
                }

                Rectangle {
                    width: 5; height: 12; radius: 2
                    anchors.verticalCenter: parent.verticalCenter
                    color: root.stateColor(root.flag(modelData.key), modelData.danger)
                }

                Text {
                    text: root.stateText(root.flag(modelData.key))
                    color: root.stateColor(root.flag(modelData.key), modelData.danger)
                    font.pixelSize: 13
                    font.family: "Consolas"
                    font.bold: root.flag(modelData.key)
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
        }
    }
}
