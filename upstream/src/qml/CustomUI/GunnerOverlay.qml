import QtQuick 2.15

Item {
    id: root
    anchors.fill: parent

    // gameData 由 MainWindow 注入 QML 上下文，统一在叠加层入口适配。
    // qmllint disable unqualified
    readonly property var gameDataContext: typeof gameData !== "undefined" ? gameData : null
    // qmllint enable unqualified
    property var customData: root.gameDataContext ? root.gameDataContext.myRobotCustomData : ({})
    property bool uiEnabled: root.gameDataContext ? root.gameDataContext.customUIEnabled : false
    visible: root.uiEnabled

    // 电控状态包新鲜度：300 ms 无新 seq 判失联（对接文档第 1 节）。
    // age < 0 表示从未收到过；age > 300 表示收到过但已超时。
    readonly property int staleTimeoutMs: 300
    readonly property int stalePollMs: 150
    property int customDataAgeMs: -1
    readonly property bool hasCustomData: customDataAgeMs >= 0
    readonly property bool customDataStale: hasCustomData && customDataAgeMs > staleTimeoutMs

    Timer {
        interval: root.stalePollMs
        repeat: true
        running: root.uiEnabled
        triggeredOnStart: true
        onTriggered: root.customDataAgeMs =
                     root.gameDataContext ? root.gameDataContext.myRobotCustomDataAgeMs() : -1
    }

    readonly property real designScale: Math.min(width / 1920, height / 1080)
    // MainWindow supplies the exact same centre used by the legacy aiming container.
    // m_centerArea is not necessarily concentric with m_centralWidget.
    property real sightCenterX: width / 2
    property real sightCenterY: height / 2

    CombatSightOverlay {
        x: root.sightCenterX - width / 2
        y: root.sightCenterY - height / 2
        scale: root.designScale
        customData: root.customData
        hasData: root.hasCustomData
        stale: root.customDataStale
    }

    // 底盘/云台姿态（E1）：底盘轮廓在云台坐标系里转动，右侧两行是
    // 云台世界角与本地推导的底盘世界角。
    ChassisGimbalAttitude {
        id: chassisPanel
        anchors.right: parent.right
        anchors.rightMargin: Math.round(30 * root.designScale)
        anchors.top: parent.top
        anchors.topMargin: Math.round(155 * root.designScale)
        scale: root.designScale
        customData: root.customData
        hasData: root.hasCustomData
        stale: root.customDataStale
    }

    // 机构状态（E3）：摩擦轮/拨弹/允许发射/自动吊射/故障/底盘警告。
    // 底盘模式已经由上方姿态盘的文案表达，这里不重复。
    //
    // 放在瞄准框右侧、射击初速度面板下方：
    //   - 避开左侧俯仰尺和它的绿色引线；
    //   - 避开右下小地图和右下角的模块灯行；
    //   - transformOrigin 用 TopLeft，x/y 就是视觉左上角，缩放不再引入偏移。
    EcmStatusPanel {
        id: ecmPanel
        transformOrigin: Item.TopLeft
        x: root.sightCenterX + Math.round(228 * root.designScale)
        y: root.sightCenterY + Math.round(178 * root.designScale)
           - Math.round(height * root.designScale)
        scale: root.designScale
        customData: root.customData
        hasData: root.hasCustomData
        stale: root.customDataStale
    }
}
