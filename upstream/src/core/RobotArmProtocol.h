// SPDX-License-Identifier: MIT
/**
 * @file RobotArmProtocol.h
 * @brief 机械臂自定义控制协议（0x0311 + RS-232）
 * @details 两个方向：
 *          - 客户端 → 下位机主控：MQTT CustomControl → 0x0311，data 为 18 字节 position。
 *          - 自定义控制器 → 客户端：RS-232 串口，34 字节整帧，
 *            [0:16) 为通信头（客户端忽略），[16:34) 为 position。
 *          - 客户端 → 自定义控制器：RS-232 串口，裸 18 字节 position，
 *            仅用于 Z 切换后的模式确认（关节角 0，relative_time 表示模式）。
 *
 *          position（packed、小端）：
 *            7 × uint16 joint_angle + uint32 relative_time。
 *          relative_time = 0          → 自定义控制
 *          relative_time = 0x7FFFFFFF → 视觉自动控制
 *          自定义控制状态下该字段由自定义控制器填写，客户端原样转发。
 */

#ifndef ROBOTARMPROTOCOL_H
#define ROBOTARMPROTOCOL_H

#include <QByteArray>
#include <QtEndian>
#include <QtGlobal>

namespace RM::ArmProtocol {

constexpr int kJointCount = 7;                 ///< 关节数量
constexpr int kPositionSize = 18;              ///< position 结构体字节数
constexpr int kCustomControllerFrameSize = 34; ///< 自定义控制器帧字节数
constexpr int kCustomControllerHeaderSize = 16; ///< 帧头字节数
constexpr int kCustomControllerPositionOffset = kCustomControllerHeaderSize;
constexpr quint32 kRelativeTimeCustom = 0;     ///< 自定义控制状态
constexpr quint32 kRelativeTimeVisionAuto = 0x7FFFFFFFu; ///< 视觉自动控制状态
constexpr int kForwardHz = 50;                 ///< 0x0311 持续发送频率
constexpr int kForwardIntervalMs = 1000 / kForwardHz;

/// 机械臂姿态（内存布局与协议一致，但不依赖编译器 packing）
struct Position {
  quint16 jointAngle[kJointCount] = {};
  quint32 relativeTime = kRelativeTimeVisionAuto;
};

/// 从 18 字节协议数据解包；长度不对时返回默认值。
inline Position unpackPosition(const QByteArray &data) {
  Position position;
  if (data.size() != kPositionSize) {
    return position;
  }
  const auto *bytes = reinterpret_cast<const uchar *>(data.constData());
  for (int i = 0; i < kJointCount; ++i) {
    position.jointAngle[i] = qFromLittleEndian<quint16>(bytes + i * 2);
  }
  position.relativeTime = qFromLittleEndian<quint32>(bytes + 14);
  return position;
}

/// 打包为 18 字节协议数据（小端）。
inline QByteArray packPosition(const Position &position) {
  QByteArray data(kPositionSize, Qt::Uninitialized);
  auto *bytes = reinterpret_cast<uchar *>(data.data());
  for (int i = 0; i < kJointCount; ++i) {
    qToLittleEndian<quint16>(position.jointAngle[i], bytes + i * 2);
  }
  qToLittleEndian<quint32>(position.relativeTime, bytes + 14);
  return data;
}

/// 从 34 字节串口帧中提取 18 字节 position（取 [16:34)）。仅用于控制器 → 客户端方向。
inline QByteArray extractPosition(const QByteArray &frame) {
  if (frame.size() != kCustomControllerFrameSize) {
    return {};
  }
  return frame.mid(kCustomControllerPositionOffset, kPositionSize);
}

} // namespace RM::ArmProtocol

#endif // ROBOTARMPROTOCOL_H
