import QtQuick 2.15

/**
 * @file HeroVideo.qml
 * @brief 英雄吊射画面
 * @details 在小地图上方显示
 */

 Item {
    id: root
    width: 640
    height: 640

     // 当可见性变化时发出信号并打印日志
     signal heroVisibilityChanged(bool visible)

    // 外部传入数据
    property string heroFrameDataUrl: ""
    property int currentRobotId: -1
    // 允许外部控制可见性，还没做按键显示和消失
    property bool forceVisible: false

    Image {
        id: heroImage
        anchors.horizontalCenter: parent.horizontalCenter
        width: parent.width
        height: parent.height
        fillMode: Image.PreserveAspectCrop
        smooth: true
        z: 4
        // 只由 forceVisible 驱动（飞镖命中英雄/工程部署时的工业相机全屏）。
        // 曾经这里还会在"帧非空 && 自己是英雄或哨兵"时自动显示 —— 主图传接进
        // heroFrame 之后，英雄车一上线就会凭空多出一块 300x300 的画面，
        // 而那块位置留给底盘/云台姿态指示。自动显示条件因此去掉。
        visible: root.forceVisible
        source: root.heroFrameDataUrl !== undefined ? root.heroFrameDataUrl : ""
        onVisibleChanged: {
            if (visible) {
                console.log("[herovideo] HeroVideo shown, currentRobotId=", root.currentRobotId)
            } else {
                console.log("[herovideo] HeroVideo hidden, currentRobotId=", root.currentRobotId)
            }
            root.heroVisibilityChanged(visible)
        }
    }

    Rectangle {
        anchors.fill: heroImage
        color: "transparent"
        border.color: "#ffffff"
        border.width: 1
        radius: 4
        z: heroImage.z - 1
        opacity: 0.6
    }
 }
