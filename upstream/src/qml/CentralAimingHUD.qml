// [Qt6.2 patch] pragma ComponentBehavior: Bound —— 需 Qt 6.5+，本机 Qt 6.2.4 不支持，暂时注释

import QtQuick 2.15

/**
 * @file CentralAimingHUD.qml
 * @brief 中央瞄准 HUD - 包含准心、热量环、射击信息
 * @details 准心始终位于屏幕几何中心，射击信息面板挂载在准心右侧
 */
Item {
    id: root
    width: 600
    height: 600

    // --- 数据绑定 ---
    // gameData 由 MainWindow 注入，这里统一收口，避免子组件依赖隐式上下文查找。
    // qmllint disable unqualified
    readonly property var gameDataContext: typeof gameData !== "undefined" ? gameData : null
    // qmllint enable unqualified
    property var myRobot: gameDataContext ? gameDataContext.myRobot : ({})

    // 受击方向：0=前 1=右 2=后 3=左，-1=无受击。
    // 数据源见 GameData::setHitDirection —— 协议不带装甲板 ID，
    // 由引擎 CSV 日志（"装甲N受击"）写入。
    readonly property int hitDirection: {
        if (!gameDataContext || gameDataContext.hitDirection === undefined)
            return -1
        var d = Number(gameDataContext.hitDirection)
        return (d >= 0 && d <= 3) ? d : -1
    }
    property int robotType: (myRobot && myRobot.type !== undefined) ? Number(myRobot.type) : 3
    property bool isAerialRobot: robotType === 6 || robotType === 4

    // --- 自定义 UI 数据绑定 ---
    property var customData: gameDataContext ? gameDataContext.myRobotCustomData : ({})

    property real currentHeat: (myRobot && myRobot.currentHeat !== undefined) ? Number(myRobot.currentHeat) : 0
    property real heatLimit: (myRobot && myRobot.heatLimit !== undefined && Number(myRobot.heatLimit) > 0) ? Number(myRobot.heatLimit) : 240
    property real heatRatioRaw: heatLimit > 0 ? currentHeat / heatLimit : 0
    property real heatRatio: Math.max(0, Math.min(1, heatRatioRaw))

    property bool isOverheated: (myRobot && myRobot.isHeatOverLimit !== undefined) ? myRobot.isHeatOverLimit : (heatRatioRaw >= 1.0)
    property color heatColor: {
        if (isOverheated)
            return "#FF3B3B";
        if (heatRatioRaw >= 0.75)
            return "#FF4B4B";
        if (heatRatioRaw >= 0.5)
            return "#F5E37B";
        if (heatRatioRaw > 0.0)
            return "#D8F8FF";
        return "#5C636A";
    }

    property real muzzleVelocity: (myRobot && myRobot.muzzleVelocity !== undefined) ? Number(myRobot.muzzleVelocity) : 0
    property real shootSpeedLimit: {
        if (myRobot && myRobot.shootSpeedLimit !== undefined)
            return Math.max(0, Number(myRobot.shootSpeedLimit));
        // GameData 尚未提供该字段时使用协议默认上限
        return 30.0;
    }

    property int speedLockState: (myRobot && myRobot.speedLockState !== undefined) ? Number(myRobot.speedLockState) : 0
    property bool speedOverLimit: speedLockState > 0

    property int configuredSpeedLockSeconds: {
        if (myRobot && myRobot.speedLockSeconds !== undefined)
            return Math.max(0, Number(myRobot.speedLockSeconds));
        return 0;
    }
    // 直接使用配置下发的锁定时长
    property int speedLockSeconds: configuredSpeedLockSeconds

    property bool centerSpeedWarning: speedOverLimit && !isAerialRobot
    property bool panelSpeedWarning: speedOverLimit && isAerialRobot

    property bool isHero: robotType === 1
    property int allowedAmmo17mmRaw: {
        if (myRobot && myRobot.allowedAmmo17mm !== undefined)
            return Math.max(0, Number(myRobot.allowedAmmo17mm));
        return 0;
    }
    property int allowedAmmo42mmRaw: {
        if (myRobot && myRobot.allowedAmmo42mm !== undefined)
            return Math.max(0, Number(myRobot.allowedAmmo42mm));
        return 0;
    }
    property int allowedAmmoRaw: isHero ? allowedAmmo42mmRaw : allowedAmmo17mmRaw
    property int fortressBonusAmmo: {
        if (!myRobot) return 0;
        if (myRobot.fortressBonusAmmo !== undefined && Number(myRobot.fortressBonusAmmo) > 0)
            return Number(myRobot.fortressBonusAmmo);
        return 0;
    }
    property color ammoColor: {
        if (allowedAmmoRaw <= 0)
            return "#FF3B3B";
        return "#E7EDF0";
    }

    // --- 视觉中心点 (固定在组件正中央) ---
    // --- 0. 官方风格瞄准框 + 四方向受击圆弧（绿色方框 + 45° 引线 + 受击弧）---
    AimFrameReticle {
        anchors.centerIn: parent
        z: -1
        reticleSize: 200
        frameSize: 440
        frameReach: 520
        hitDirection: root.hitDirection
        // 主发射框、引线和距离尺由验收版 CombatSightOverlay 统一绘制；
        // 此组件仅保留官方准心圆与受击方向圆弧，避免出现双层绿色框。
        aimFrameVisible: false
    }

    Item {
        id: visualCenter
        anchors.centerIn: parent
        width: 1
        height: 1

        // --- 1. 外圈背景 (超大淡灰圆环) ---
        // 官方主界面中心只有一圈圆弧（见 AimFrameReticle），这个 560px 的大灰环
        // 是早期实现留下的，叠在圆弧上会显得中央有两层圆，故不再显示。
        Image {
            id: outerRing
            anchors.centerIn: parent
            width: 560
            height: 560
            source: "qrc:/images/crosshair/crosshair_bg_single.png"
            fillMode: Image.PreserveAspectFit
            opacity: 0.35
            visible: false
        }

        // --- 横向基准线 ---
        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            anchors.right: heatRingContainer.left
            anchors.rightMargin: 4
            width: 178
            height: 1
            color: "#596067"
            opacity: 0.55
        }
        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: heatRingContainer.right
            anchors.leftMargin: 4
            width: 178
            height: 1
            color: "#596067"
            opacity: 0.55
        }

        // --- 2. 热量环 (紧贴准星的小圈) ---
        Item {
            id: heatRingContainer
            anchors.centerIn: parent
            width: 116
            height: 116

            // 热量环背景
            Image {
                id: heatRingBg
                anchors.fill: parent
                source: "qrc:/images/crosshair/crosshair_slid_circle_bg.png"
                fillMode: Image.PreserveAspectFit
                opacity: 0.92
            }

            Canvas {
                id: heatProgressCanvas
                anchors.fill: parent
                antialiasing: true

                onPaint: {
                    var context = getContext("2d");
                    context.clearRect(0, 0, width, height);

                    var displayRatio = root.isOverheated ? 1.0 : root.heatRatio;
                    if (displayRatio <= 0) {
                        return;
                    }

                    var lineWidth = 8;
                    var radius = Math.max(0, Math.min(width, height) * 0.5 - lineWidth * 0.7);
                    var centerX = width * 0.5;
                    var centerY = height * 0.5;
                    var startAngle = -Math.PI * 0.5;
                    var endAngle = startAngle + Math.PI * 2 * displayRatio;

                    context.beginPath();
                    context.lineWidth = lineWidth;
                    context.lineCap = "round";
                    context.strokeStyle = root.heatColor;
                    context.shadowColor = root.heatColor;
                    context.shadowBlur = root.isOverheated ? 18 : 10;
                    context.arc(centerX, centerY, radius, startAngle, endAngle, false);
                    context.stroke();
                }

                Component.onCompleted: requestPaint()
            }

            Rectangle {
                anchors.centerIn: parent
                width: 94
                height: 94
                radius: 47
                color: "transparent"
                border.width: 1
                border.color: "#4D545B"
                opacity: 0.7
            }

            Text {
                id: overheatWarningText
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottom: parent.top
                anchors.bottomMargin: 10
                text: "热量超限，图传断开"
                visible: root.isOverheated
                color: "#FF4747"
                font.pixelSize: 18
                font.bold: true
                font.family: "PingFang SC"
                opacity: 0.92

                SequentialAnimation {
                    running: root.isOverheated
                    loops: Animation.Infinite
                    NumberAnimation {
                        target: overheatWarningText
                        property: "opacity"
                        to: 0.35
                        duration: 280
                    }
                    NumberAnimation {
                        target: overheatWarningText
                        property: "opacity"
                        to: 0.92
                        duration: 280
                    }
                }
            }

            Text {
                visible: root.centerSpeedWarning
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.top: parent.bottom
                anchors.topMargin: 10
                text: {
                    if (root.centerSpeedWarning) {
                        if (root.speedLockState === 3) {
                            return "速度严重超限，永久锁定";
                        } else if (root.speedLockState === 2) {
                            return "速度已超限，锁定 20s";
                        } else if (root.speedLockState === 1) {
                            return "速度已超限，锁定 15s";
                        }
                        return "速度已超限，锁定 " + root.speedLockSeconds + "s";
                    }
                    return "";
                }
                color: "#FF3B3B"
                font.pixelSize: 14
                font.family: "PingFang SC"
                font.bold: true
            }
        }

        // --- 3. 准心 (中心十字) ---
        Image {
            id: crosshair
            anchors.centerIn: parent
            width: 36
            height: 36
            source: "qrc:/images/crosshair/crosshair_middle.png"
            fillMode: Image.PreserveAspectFit
            opacity: 1.0
            visible: !root.centerSpeedWarning
        }
    }

    onHeatRatioChanged: heatProgressCanvas.requestPaint()
    onHeatColorChanged: heatProgressCanvas.requestPaint()
    onIsOverheatedChanged: heatProgressCanvas.requestPaint()

    // --- 4. 射击信息面板 (固定挂载到最大外环右侧) ---
    Item {
        id: shootingInfo
        anchors.left: visualCenter.right
        anchors.leftMargin: 286
        anchors.verticalCenter: visualCenter.verticalCenter
        anchors.verticalCenterOffset: -8
        width: 146
        height: 184

        // 透明容器 - 无背景无边框
        Item {
            width: 146
            height: 178

            Column {
                anchors.fill: parent
                anchors.leftMargin: 17
                anchors.rightMargin: 10
                anchors.topMargin: 14
                anchors.bottomMargin: 11
                spacing: 10

                Column {
                    spacing: 2
                    Text {
                        text: "射击初速度"
                        color: "#8E959C"
                        font.pixelSize:10
                        font.family: "PingFang SC"
                    }
                    Text {
                        text: root.panelSpeedWarning ? (root.muzzleVelocity.toFixed(1) + " " + root.speedLockSeconds + "s") : root.muzzleVelocity.toFixed(1)
                        color: root.panelSpeedWarning ? "#FF3B3B" : "#EEF3F6"
                        font.pixelSize: root.panelSpeedWarning ? 28 : 28
                        font.family: "PingFang SC"
                        font.bold: true
                    }
                }

                Column {
                    spacing: 2
                    Text {
                        text: "允许发弹量"
                        color: "#8E959C"
                        font.pixelSize:10
                        font.family: "PingFang SC"
                    }
                    Text {
                        text: root.allowedAmmoRaw
                        color: root.ammoColor
                        font.pixelSize: 28
                        font.family: "PingFang SC"
                        font.bold: true
                    }
                    Text {
                        visible: root.fortressBonusAmmo > 0
                        text: "+" + root.fortressBonusAmmo
                        color: "#11F5A0"
                        font.pixelSize: 28
                        font.family: "PingFang SC"
                        font.bold: true
                    }
                }
            }
        }
    }

    // E1/E2/E3 的实时显示统一放在 CustomUI/GunnerOverlay.qml：
    // 姿态盘、俯仰尺、机构状态和 300 ms 失联都在那里，中央准心 HUD 不再重复。

    // --- 超级电容能量条 (右侧中部) ---
    Rectangle {
        id: superCapPanel
        anchors.right: parent.right
        anchors.rightMargin: 20
        anchors.verticalCenter: parent.verticalCenter
        anchors.verticalCenterOffset: 50
        width: 160
        height: 50
        color: "#1A1A1A"
        opacity: 0.85
        border.color: "#00CED1"
        border.width: 1
        radius: 4
        visible: root.customData.superCapEnergy !== undefined && root.customData.superCapEnergy > 0

        Column {
            anchors.fill: parent
            anchors.margins: 8
            spacing: 6

            Text {
                text: "SUPER CAPACITOR"
                color: "#00CED1"
                font.pixelSize: 10
                font.bold: true
            }

            // 能量条
            Rectangle {
                width: parent.width
                height: 16
                color: "#333333"
                radius: 8

                Rectangle {
                    width: parent.width * (Math.min(root.customData.superCapEnergy, 100) / 100.0)
                    height: parent.height
                    radius: 8
                    color: {
                        var pct = root.customData.superCapEnergy;
                        if (pct > 60) return "#00FF00";
                        if (pct > 30) return "#FFFF00";
                        return "#FF0000";
                    }

                    // 低电量闪烁
                    SequentialAnimation on opacity {
                        running: root.customData.superCapEnergy < 30
                        loops: Animation.Infinite
                        NumberAnimation { to: 0.5; duration: 300 }
                        NumberAnimation { to: 1.0; duration: 300 }
                    }
                }

                // 百分比文字
                Text {
                    anchors.centerIn: parent
                    text: Math.round(root.customData.superCapEnergy) + "%"
                    color: "white"
                    font.pixelSize: 10
                    font.bold: true
                }
            }
        }
    }


    // 旧的红色“目标距离落点框”已移除。距离保持量、散布和弹道均由
    // CustomUI/CombatSightOverlay.qml 按验收版网页的表现统一绘制。
}
