import QtQuick 2.15

/**
 * 官方风格瞄准框 + 四方向受击圆弧。
 *
 * 视觉取自官方客户端主界面：中心一个绿色方框，方框左右下角各引出一条 45° 斜线，
 * 方框正中是圆形准心，中弹时对应方向的圆弧亮红。
 *
 * 受击弧素材的几何（决定了下面的对齐系数）：
 *   上下方向 250x385，左右方向 385x250；素材内圆半径都是 125，
 *   圆心落在长边的 54.5%（=210/250）处、短边的 50% 处。
 *   所以把弧贴到准心圆上时，长边要按 0.84 补偿偏移，不能按 0.5。
 *
 * 组件以自身中心为原点，使用方请 anchors.centerIn。
 */
Item {
    id: root

    // --- 可调几何 ---
    property real reticleSize: 200        // 准心圆直径
    property real frameSize: 440          // 绿色方框边长
    property real frameReach: 520         // 斜线延伸长度
    property color frameColor: "#8CD211"  // 官方瞄准框绿
    property bool aimFrameVisible: true

    // --- 受击方向 ---
    // 0 = 前方(上) 1 = 右侧 2 = 后方(下) 3 = 左侧, -1 = 无受击
    property int hitDirection: -1

    // 素材内圆直径 250，按准心圆直径换算缩放
    readonly property real _scale: reticleSize / 250.0
    readonly property real _arcLong: 385.0 * _scale   // 弧素材长边渲染长度
    readonly property real _arcMid: 210.0 * _scale    // 圆心到长边端点的距离

    // ================= 绿色瞄准框 =================
    Item {
        id: aimFrame
        anchors.centerIn: parent
        visible: root.aimFrameVisible

        // 方框（仅描边）
        Rectangle {
            x: -root.frameSize / 2
            y: -root.frameSize / 2
            width: root.frameSize
            height: root.frameSize
            color: "transparent"
            border.color: root.frameColor
            border.width: 3
        }

        // 左下斜线：自方框左下角向斜下方
        Rectangle {
            x: -root.frameSize / 2
            y: root.frameSize / 2
            width: root.frameReach
            height: 3
            color: root.frameColor
            transformOrigin: Item.TopLeft
            rotation: 135
        }

        // 右下斜线
        Rectangle {
            x: root.frameSize / 2
            y: root.frameSize / 2
            width: root.frameReach
            height: 3
            color: root.frameColor
            transformOrigin: Item.TopLeft
            rotation: 45
        }

        // 方框正下方的短虚线
        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            y: root.frameSize / 2 + 26
            spacing: 8
            Repeater {
                model: 3
                Rectangle {
                    width: 26
                    height: 3
                    color: root.frameColor
                }
            }
        }
    }

    // ================= 准心圆 =================
    Image {
        id: reticleRing
        anchors.centerIn: parent
        width: root.reticleSize
        height: root.reticleSize
        source: "qrc:/images/crosshair/crosshair_slid_circle_white.png"
        fillMode: Image.PreserveAspectFit
        smooth: true
    }

    // ================= 四方向受击弧 =================
    // 前方：弧在素材顶部，圆心距顶端 0.84 个准心直径
    Image {
        visible: root.hitDirection === 0
        width: root.reticleSize
        height: root._arcLong
        x: -root.reticleSize / 2
        y: -root._arcMid
        source: "qrc:/images/crosshair/crosshair_attacked_up.png"
        fillMode: Image.PreserveAspectFit
        smooth: true
    }

    // 后方
    Image {
        visible: root.hitDirection === 2
        width: root.reticleSize
        height: root._arcLong
        x: -root.reticleSize / 2
        y: -root._arcMid
        source: "qrc:/images/crosshair/crosshair_attacked_down.png"
        fillMode: Image.PreserveAspectFit
        smooth: true
    }

    // 左侧：横向素材，圆心在水平方向 0.84 处
    Image {
        visible: root.hitDirection === 3
        width: root._arcLong
        height: root.reticleSize
        x: -root._arcMid
        y: -root.reticleSize / 2
        source: "qrc:/images/crosshair/crosshair_attacked_left.png"
        fillMode: Image.PreserveAspectFit
        smooth: true
    }

    // 右侧
    Image {
        visible: root.hitDirection === 1
        width: root._arcLong
        height: root.reticleSize
        x: -root._arcMid
        y: -root.reticleSize / 2
        source: "qrc:/images/crosshair/crosshair_attacked_right.png"
        fillMode: Image.PreserveAspectFit
        smooth: true
    }
}
