// SPDX-License-Identifier: MIT
#include "ArmSerialLink.h"

#include <QDebug>
#include <QSerialPort>

namespace RM {

ArmSerialLink::ArmSerialLink(QObject *parent) : QObject(parent) {
  m_port = new QSerialPort(this);
  connect(m_port, &QSerialPort::readyRead, this, &ArmSerialLink::onReadyRead);
  connect(m_port, &QSerialPort::errorOccurred, this,
          [this](QSerialPort::SerialPortError error) {
            if (error == QSerialPort::NoError) {
              return;
            }
            emit errorOccurred(m_port->errorString());
          });
}

ArmSerialLink::~ArmSerialLink() { stop(); }

bool ArmSerialLink::start(const QString &portName, qint32 baudRate,
                          int magicByte) {
  if (portName.trimmed().isEmpty()) {
    return false;
  }
  if (m_port->isOpen()) {
    stop();
  }

  m_magicByte = (magicByte >= 0 && magicByte <= 0xFF) ? magicByte : -1;
  m_port->setPortName(portName);
  m_port->setBaudRate(baudRate);
  m_port->setDataBits(QSerialPort::Data8);
  m_port->setParity(QSerialPort::NoParity);
  m_port->setStopBits(QSerialPort::OneStop);
  m_port->setFlowControl(QSerialPort::NoFlowControl);

  if (!m_port->open(QIODevice::ReadWrite)) {
    qWarning().noquote()
        << QStringLiteral("RM26_ARM_SERIAL open failed port=%1 baud=%2 error=%3")
               .arg(portName)
               .arg(baudRate)
               .arg(m_port->errorString());
    return false;
  }

  m_buffer.clear();
  const QString magicText =
      m_magicByte >= 0
          ? QStringLiteral("0x") +
                QString::number(m_magicByte, 16).toUpper().rightJustified(2, '0')
          : QStringLiteral("none");
  qInfo().noquote()
      << QStringLiteral("RM26_ARM_SERIAL open port=%1 baud=%2 magic=%3")
             .arg(portName)
             .arg(baudRate)
             .arg(magicText);
  return true;
}

void ArmSerialLink::stop() {
  if (m_port && m_port->isOpen()) {
    m_port->close();
  }
  m_buffer.clear();
}

bool ArmSerialLink::isOpen() const { return m_port && m_port->isOpen(); }

QString ArmSerialLink::portName() const {
  return m_port ? m_port->portName() : QString();
}

bool ArmSerialLink::writeModeFrame(const ArmProtocol::Position &position) {
  if (!isOpen()) {
    return false;
  }
  const QByteArray frame = ArmProtocol::packCustomControllerFrame(position);
  const qint64 written = m_port->write(frame);
  if (written != frame.size()) {
    qWarning() << "ArmSerialLink: short write" << written << "/" << frame.size();
    return false;
  }
  return true;
}

void ArmSerialLink::onReadyRead() {
  if (!m_port) {
    return;
  }
  m_buffer.append(m_port->readAll());

  // 定长 34 字节帧。配了魔数时先对齐到帧头，避免打开串口时从半帧开始后
  // 永久错位；没配魔数就只能假设控制器一直整帧对齐发送。
  while (true) {
    if (m_magicByte >= 0) {
      if (m_buffer.isEmpty()) {
        break;
      }
      if (static_cast<quint8>(m_buffer.at(0)) != m_magicByte) {
        const int next = m_buffer.indexOf(static_cast<char>(m_magicByte), 1);
        if (next < 0) {
          m_buffer.clear();
          break;
        }
        m_buffer.remove(0, next);
      }
    }
    if (m_buffer.size() < ArmProtocol::kCustomControllerFrameSize) {
      break;
    }
    const QByteArray frame =
        m_buffer.left(ArmProtocol::kCustomControllerFrameSize);
    m_buffer.remove(0, ArmProtocol::kCustomControllerFrameSize);
    const QByteArray position = ArmProtocol::extractPosition(frame);
    if (!position.isEmpty()) {
      emit positionReceived(position);
    }
  }

  // 防御：异常积压时丢弃旧数据，避免延迟无限增长。
  constexpr int kMaxBufferBytes = ArmProtocol::kCustomControllerFrameSize * 100;
  if (m_buffer.size() > kMaxBufferBytes) {
    m_buffer.remove(0, m_buffer.size() - kMaxBufferBytes);
  }
}

} // namespace RM
