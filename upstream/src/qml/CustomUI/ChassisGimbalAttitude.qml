import QtQuick 2.15

/*
 * E1 底盘/云台姿态盘。
 * 操作手坐在云台里，所以云台指针固定朝上，底盘轮廓按
 * “底盘相对云台”的角度转动（Unity 参考：heroYaw - turretWorldYaw = -offset）。
 * Canvas 的 y 轴向下、正角度为顺时针，因此这里直接旋转 +offset。
 */
Item {
    id: root
    width: 250
    height: 236
    property var customData: ({})
    property bool hasData: false
    property bool stale: false

    readonly property real offsetDeg: customData && customData.gimbalChassisAngle !== undefined
                                     ? Number(customData.gimbalChassisAngle) : 0
    readonly property real gimbalYaw: customData && customData.gimbalYaw !== undefined
                                      ? Number(customData.gimbalYaw) : 0
    readonly property real chassisYaw: customData && customData.chassisYaw !== undefined
                                       ? Number(customData.chassisYaw) : 0
    readonly property int mode: customData && customData.chassisMode !== undefined
                                ? Number(customData.chassisMode) : -1
    readonly property bool poseValid: customData ? !!customData.poseValid : false
    // 只有状态包未超时且 pose_valid=1 时，两个角度才可信。
    readonly property bool poseTrusted: root.hasData && !root.stale && root.poseValid

    readonly property color chassisColor: root.poseTrusted
                                          ? Qt.rgba(1.0, 0.20, 0.18, 0.96)
                                          : Qt.rgba(0.47, 0.53, 0.57, 0.70)
    readonly property color turretColor: root.poseTrusted
                                         ? Qt.rgba(0.20, 0.42, 1.0, 0.98)
                                         : Qt.rgba(0.47, 0.53, 0.57, 0.70)

    function modeName(m) {
        switch (m) {
        case 0: return "正常模式"
        case 1: return "跟随模式"
        case 2: return "小陀螺模式"
        case 3: return "保护模式"
        default: return "--"
        }
    }

    function modeColor(m) {
        switch (m) {
        case 0:
        case 1: return "#8CD9FF"
        case 2: return "#FFC740"
        case 3: return "#EF3931"
        default: return "#788891"
        }
    }

    function fmtDeg(v) {
        if (!root.hasData || v === undefined || isNaN(v))
            return "--"
        var n = Number(v)
        return (n >= 0 ? "+" : "") + n.toFixed(1) + "°"
    }

    Canvas {
        id: dial
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        width: 130
        height: 150

        onPaint: {
            var ctx = getContext("2d")
            ctx.reset()
            ctx.clearRect(0, 0, width, height)

            var cx = width / 2
            var cy = height / 2 - 5
            var pts = [[-50, 60], [-50, -25], [0, -60], [50, -25], [50, 60]]

            // 底盘轮廓：在云台坐标系里转动。offset 为正（云台在车体左侧）时，
            // 车体相对云台向右/顺时针偏，Canvas 正角度正是顺时针。
            ctx.save()
            ctx.translate(cx, cy)
            ctx.rotate(root.offsetDeg * Math.PI / 180)
            ctx.lineWidth = 4
            ctx.strokeStyle = root.chassisColor
            ctx.lineJoin = "round"
            ctx.beginPath()
            for (var i = 0; i < pts.length; ++i) {
                if (i === 0)
                    ctx.moveTo(pts[i][0], pts[i][1])
                else
                    ctx.lineTo(pts[i][0], pts[i][1])
            }
            ctx.closePath()
            ctx.stroke()
            ctx.restore()

            // 云台环与指针：固定在正上方，代表操作手视角。
            ctx.strokeStyle = root.turretColor
            ctx.lineWidth = 5
            ctx.lineCap = "round"
            ctx.beginPath()
            ctx.moveTo(cx, cy - 8)
            ctx.lineTo(cx, cy - 76)
            ctx.stroke()
            ctx.beginPath()
            ctx.arc(cx, cy, 26, 0, Math.PI * 2)
            ctx.stroke()
        }

        Connections {
            target: root
            function onOffsetDegChanged() { dial.requestPaint() }
            function onPoseTrustedChanged() { dial.requestPaint() }
        }
        Component.onCompleted: requestPaint()
    }

    Text {
        id: modeText
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: dial.bottom
        anchors.topMargin: 2
        text: root.hasData ? root.modeName(root.mode) : "--"
        color: (!root.hasData || root.stale) ? "#788891" : root.modeColor(root.mode)
        font.pixelSize: 15
        font.family: "Microsoft YaHei"
    }

    Row {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: modeText.bottom
        anchors.topMargin: 4
        spacing: 4
        Text {
            text: "云台"
            color: "#B8D6E6"
            font.pixelSize: 12
            font.family: "Microsoft YaHei"
        }
        Text {
            text: root.fmtDeg(root.gimbalYaw)
            color: root.poseTrusted ? "#E6F5FF" : "#788891"
            font.pixelSize: 12
            font.family: "Consolas"
        }
    }

    Row {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: modeText.bottom
        anchors.topMargin: 20
        spacing: 4
        Text {
            text: "底盘"
            color: "#B8D6E6"
            font.pixelSize: 12
            font.family: "Microsoft YaHei"
        }
        Text {
            text: root.fmtDeg(root.chassisYaw)
            color: root.poseTrusted ? "#E6F5FF" : "#788891"
            font.pixelSize: 12
            font.family: "Consolas"
        }
    }

    Text {
        id: stateText
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: modeText.bottom
        anchors.topMargin: 38
        font.pixelSize: 11
        font.family: "Microsoft YaHei"
        text: !root.hasData ? "等待数据"
              : root.stale ? "失联"
              : !root.poseValid ? "姿态无效"
              : ""
        color: !root.hasData ? "#788891"
               : root.stale ? "#E2B2B0"
               : "#FFC740"
    }
}
