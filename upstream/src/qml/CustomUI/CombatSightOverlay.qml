import QtQuick 2.15

/* Direct 1.5x port of Unity OfficialHudBinder.BuildLegacyCenterOverlay. */
Item {
    id: root
    width: 1920
    height: 1080
    property var customData: ({})
    property bool hasData: false
    property bool stale: false

    // E2 俯仰尺的静态标定上下限。现场按电控标定改这两个属性即可。
    property real pitchMinDeg: -10
    property real pitchMaxDeg: 70

    readonly property real rawPitch: customData && customData.barrelPitch !== undefined
                                     ? Number(customData.barrelPitch) : 0
    readonly property real clampedPitch: Math.max(root.pitchMinDeg,
                                                   Math.min(root.pitchMaxDeg, root.rawPitch))
    readonly property real pitchRange: Math.max(1.0, root.pitchMaxDeg - root.pitchMinDeg)
    readonly property bool pitchOutOfRange: root.hasData && !root.stale
                                            && (root.rawPitch < root.pitchMinDeg
                                                || root.rawPitch > root.pitchMaxDeg)
    readonly property bool pitchValid: customData ? !!customData.pitchValid : false
    readonly property bool pitchTrusted: root.hasData && !root.stale && root.pitchValid

    readonly property color green: Qt.rgba(0.62, 1.0, 0.16, 0.92)
    readonly property color whiteInk: root.pitchTrusted ? Qt.rgba(0.90, 0.96, 1.0, 0.96) : "#6D6D6D"
    readonly property color minorInk: root.pitchTrusted ? Qt.rgba(0.72, 0.84, 0.90, 0.82) : "#6D6D6D"
    readonly property color sliderInk: root.pitchTrusted ? Qt.rgba(1, 0.84, 0.10, 0.98) : "#6D6D6D"
    readonly property color valueInk: !root.pitchTrusted ? "#6D6D6D"
                                       : root.pitchOutOfRange ? "#EF3931"
                                       : Qt.rgba(1, 0.88, 0.18, 1)
    readonly property color limitInk: root.pitchTrusted ? "#EF3931" : "#6D6D6D"
    readonly property string pitchStateText: !root.hasData ? "等待数据"
                                            : root.stale ? "失联"
                                            : !root.pitchValid ? "俯仰无效"
                                            : ""
    readonly property color pitchStateColor: !root.hasData ? "#788891"
                                            : root.stale ? "#E2B2B0"
                                            : "#FFC740"

    // 5° 一格，从上限到下限。范围改了这里会自动重排。
    readonly property var tickDegrees: {
        var arr = []
        for (var d = root.pitchMaxDeg; d >= root.pitchMinDeg; d -= 5)
            arr.push(d)
        return arr
    }

    property real dispersionX: customData && customData.dispersionX !== undefined ? Number(customData.dispersionX) : 52
    property real dispersionY: customData && customData.dispersionY !== undefined ? Number(customData.dispersionY) : 38
    property real steering: customData && customData.steering !== undefined ? Number(customData.steering) : 0.18
    property bool gyroMode: customData && Number(customData.chassisMode) === 2

    /* Unity local coordinates are y-up; this canvas converts them once at 1.5x. */
    Canvas {
        id: fixedSight
        anchors.fill: parent
        antialiasing: true
        function sx(x) { return width / 2 + x * 1.5 }
        function sy(y) { return height / 2 - y * 1.5 }
        function line(ctx, x1, y1, x2, y2, w, color) {
            ctx.strokeStyle = color; ctx.lineWidth = w * 1.5
            ctx.beginPath(); ctx.moveTo(sx(x1), sy(y1)); ctx.lineTo(sx(x2), sy(y2)); ctx.stroke()
        }
        onPaint: {
            var ctx = getContext("2d"); ctx.reset(); ctx.clearRect(0, 0, width, height)
            var g = root.green
            line(ctx,-145,125,145,125,3,g); line(ctx,-145,-125,145,-125,3,g)
            line(ctx,-145,-125,-145,125,3,g); line(ctx,145,-125,145,125,3,g)
            line(ctx,-145,-125,-360,-285,3,g); line(ctx,145,-125,360,-285,3,g)
            line(ctx,-38,-150,-16,-150,2,g); line(ctx,-8,-150,8,-150,2,g); line(ctx,16,-150,38,-150,2,g)

            var w = Qt.rgba(1,1,1,0.96)
            line(ctx,-22,0,-7,0,2,w); line(ctx,7,0,22,0,2,w)
            line(ctx,0,7,0,22,2,w); line(ctx,0,-22,0,-7,2,w)
            ctx.fillStyle = w; ctx.beginPath(); ctx.arc(sx(0),sy(0),2.25,0,Math.PI*2); ctx.fill()
        }
    }

    /* Unity pitch-scale rect: center (-188,0), size 76x286, then root scale 1.5. */
    Item {
        id: pitchScale
        width: 114; height: 429
        x: root.width / 2 - 339
        y: root.height / 2 - height / 2

        Rectangle { x: 57; y: 37.5; width: 3; height: 354; color: root.whiteInk }

        Text {
            x: 0; y: 8; width: 114
            visible: text !== ""
            text: root.pitchStateText
            color: root.pitchStateColor
            font.pixelSize: 15; font.family: "Microsoft YaHei"
            horizontalAlignment: Text.AlignHCenter
        }

        Repeater {
            model: root.tickDegrees
            delegate: Item {
                required property var modelData
                readonly property real degree: Number(modelData)
                y: 37.5 + (root.pitchMaxDeg - degree) / root.pitchRange * 354
                Rectangle {
                    x: 57; anchors.verticalCenter: parent.verticalCenter
                    width: parent.degree % 10 === 0 ? 25.5 : 13.5
                    height: parent.degree % 10 === 0 ? 3 : 2.25
                    color: parent.degree % 10 === 0 ? root.whiteInk : root.minorInk
                }
                Text {
                    visible: parent.degree % 10 === 0
                    x: 0; width: 48; anchors.verticalCenter: parent.verticalCenter
                    text: parent.degree + "°"
                    color: (parent.degree === root.pitchMaxDeg || parent.degree === root.pitchMinDeg)
                           ? root.limitInk : root.whiteInk
                    font.pixelSize: 15; font.family: "Arial"
                    horizontalAlignment: Text.AlignRight
                }
            }
        }

        Rectangle {
            x: 52.5
            visible: root.hasData
            y: 37.5 + (root.pitchMaxDeg - root.clampedPitch) / root.pitchRange * 354 - height / 2
            width: 37.5; height: 19.5; color: root.sliderInk
        }

        Text {
            x: 100
            y: 37.5 + (root.pitchMaxDeg - root.clampedPitch) / root.pitchRange * 354 - height / 2
            text: root.hasData
                  ? (root.clampedPitch > 0 ? "+" : "") + root.clampedPitch.toFixed(1) + "°"
                  : "--"
            color: root.valueInk; font.pixelSize: 20; font.family: "Arial"
        }
    }

    /* Placeholder group box uses the same centered, white, two-pixel Unity strokes. */
    Rectangle {
        anchors.centerIn: parent
        width: Math.max(36, root.dispersionX * 1.5)
        height: Math.max(30, root.dispersionY * 1.5)
        color: "transparent"
        border.width: 3
        border.color: Qt.rgba(1,1,1,.9)
    }

    /* Fixed holdover ruler: ticks only; Unity intentionally renders no range numbers. */
    Repeater {
        model: [34, 60, 91, 128]
        delegate: Rectangle {
            required property int modelData
            width: 39; height: 1.8
            x: root.width / 2 - width / 2
            y: root.height / 2 + modelData * 1.5
            color: Qt.rgba(1,1,1,.55)
        }
    }

    Canvas {
        id: dynamicGuides
        anchors.fill: parent
        antialiasing: true
        onPaint: {
            var ctx=getContext("2d"); ctx.reset(); ctx.clearRect(0,0,width,height)
            var cx=width/2, cy=height/2

            /* Stable placeholder funnel in exactly the centre-overlay coordinate system. */
            ctx.lineWidth=3; ctx.strokeStyle=Qt.rgba(.88,.96,1,.45)
            ctx.beginPath(); ctx.moveTo(cx,cy+14); ctx.quadraticCurveTo(cx+8,cy+144,cx+27,cy+306); ctx.stroke()
            ctx.strokeStyle=Qt.rgba(.60,.90,1,.28)
            ctx.beginPath(); ctx.moveTo(cx-6,cy+18); ctx.quadraticCurveTo(cx-30,cy+156,cx-72,cy+306)
            ctx.moveTo(cx+6,cy+18); ctx.quadraticCurveTo(cx+45,cy+156,cx+126,cy+306); ctx.stroke()
            ctx.lineWidth=2.25; ctx.strokeStyle=Qt.rgba(.60,.90,1,.16)
            for(var yy=81;yy<=297;yy+=54){ var t=yy/306; ctx.beginPath(); ctx.moveTo(cx-72*t,cy+yy); ctx.lineTo(cx+126*t,cy+yy); ctx.stroke() }

            if (!root.gyroMode) {
                /* Unity left/right anchors (-235,-205)/(235,-205), y-up, scaled 1.5. */
                var bend=root.steering*90
                ctx.lineWidth=4.5; ctx.strokeStyle=Qt.rgba(1,.84,.10,.62)
                ctx.beginPath(); ctx.moveTo(cx-352.5,cy+307.5)
                ctx.quadraticCurveTo(cx-352.5+bend,cy+250,cx-352.5+bend,cy+225)
                ctx.moveTo(cx+352.5,cy+307.5)
                ctx.quadraticCurveTo(cx+352.5+bend,cy+250,cx+352.5+bend,cy+225); ctx.stroke()
            }
        }
        Connections {
            target: root
            function onSteeringChanged() { dynamicGuides.requestPaint() }
            function onGyroModeChanged() { dynamicGuides.requestPaint() }
        }
    }
}
