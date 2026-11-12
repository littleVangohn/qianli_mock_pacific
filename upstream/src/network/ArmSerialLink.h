// SPDX-License-Identifier: MIT
/**
 * @file ArmSerialLink.h
 * @brief 自定义控制器 RS-485 串口链路
 * @details 自定义控制器通过 USB-RS485 直连上位机，按 34 字节定长帧收发：
 *            [0:16)  通信头（客户端忽略，发送时填 0）
 *            [16:34) 机械臂 position（7×uint16 + uint32，小端）
 *          接收到的 position 由 MainWindow 持续转发到 CustomControl（0x0311）；
 *          模式切换帧（relative_time = 0 / INT_MAX）同时写回串口。
 */

#ifndef ARMSERIALLINK_H
#define ARMSERIALLINK_H

#include "../core/RobotArmProtocol.h"
#include <QByteArray>
#include <QObject>

class QSerialPort;

namespace RM {

class ArmSerialLink : public QObject {
  Q_OBJECT

public:
  explicit ArmSerialLink(QObject *parent = nullptr);
  ~ArmSerialLink() override;

  /// 打开串口（8N1，无流控）。portName 为空或打开失败时返回 false。
  /// magicByte >= 0 时按该字节做帧头重新同步（16 字节通信头的第 0 字节）。
  bool start(const QString &portName, qint32 baudRate, int magicByte = -1);
  void stop();

  bool isOpen() const;
  QString portName() const;

  /// 把 34 字节模式帧写回自定义控制器（16 字节头填 0）。
  bool writeModeFrame(const ArmProtocol::Position &position);

signals:
  /// 从串口收到一帧，载荷为 18 字节 position。
  void positionReceived(const QByteArray &position);
  void errorOccurred(const QString &error);

private slots:
  void onReadyRead();

private:
  QSerialPort *m_port = nullptr;
  QByteArray m_buffer;
  int m_magicByte = -1;
};

} // namespace RM

#endif // ARMSERIALLINK_H
