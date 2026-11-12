// SPDX-License-Identifier: MIT
/**
 * @file MqttLogger.cpp
 * @brief MQTT 消息日志记录器实现
 * @author Clear
 * @date 2026-05-30
 * @copyright Copyright (c) 2026 Fudan University EGA Team (复旦大学星云 EGA 机器人战队).
 */

#include "MqttLogger.h"
#include <QCoreApplication>
#include <QDateTime>
#include <QDebug>
#include <QDir>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QThread>

// ============================================================================
// 单例
// ============================================================================

MqttLogger *MqttLogger::instance() {
  // 单例必须落在主线程上，原因见构造函数里 m_flushTimer 的说明。
  // 用函数内静态指针 + lambda 是为了让"构造"和"搬家"处在同一次线程安全初始化里：
  // 若拆成两步，别的线程可能在搬家之前抢先进入，出现跨线程 moveToThread（未定义行为）。
  static MqttLogger *s_instance = [] {
    auto *logger = new MqttLogger();
    if (QCoreApplication *app = QCoreApplication::instance()) {
      if (logger->thread() != app->thread()) {
        logger->moveToThread(app->thread());
      }
    }
    return logger;
  }();
  return s_instance;
}

// ============================================================================
// 构造 / 析构
// ============================================================================

MqttLogger::MqttLogger(QObject *parent)
    : QObject(parent) {
  // 这里原本有一个 QTimer 负责定时刷盘，已移除，原因留档：
  //   QTimer 是 QObject，线程归属跟着"谁第一个调 instance()"走，
  //   而首批调用来自 logRx() —— Paho 回调线程，它不是 QThread。
  //   于是该定时器既 start 不了也 stop 不掉（Qt 只告警），
  //   更严重的是**客户端第一次掉线重连时必崩**：
  //   起初崩在 QTimer::start()；用 moveToThread() 把宿主搬到主线程后，
  //   改为崩在 QTimer::timerEvent()（跨线程搬 QTimer 本身就不被 Qt 支持）。
  // 现在改成"缓冲区满就地刷盘"（见 appendLine）：一样是批量写，
  // 但不再依赖任何 Qt 定时器，也就无所谓线程归属。
}

MqttLogger::~MqttLogger() {
  stopSession();
}

// ============================================================================
// 会话管理
// ============================================================================

void MqttLogger::startSession() {
  if (thread() != QThread::currentThread()) {
    // 定时器与文件句柄都归主线程所有，跨线程直接操作就是段错误的成因。
    // 这里做一次编组，保证无论谁调都落在正确的线程上执行。
    QMetaObject::invokeMethod(this, [this] { startSession(); },
                              Qt::QueuedConnection);
    return;
  }
  if (m_isActive) {
    // 先停止已有会话（正常不应发生，防御性处理）
    stopSession();
  }

  // 日志目录：优先环境变量 RM_LOG_DIR，否则自动查找项目根目录
  const QString envLogDir =
      qEnvironmentVariable("RM_LOG_DIR").trimmed();
  QString logRoot;
  if (!envLogDir.isEmpty()) {
    logRoot = envLogDir;
  } else {
    // 从可执行文件所在目录向上查找项目根目录（兼容 macOS .app bundle 和 Ubuntu）
    QDir dir(QCoreApplication::applicationDirPath());
    bool found = false;
    for (int i = 0; i < 8; ++i) {
      if (QFileInfo::exists(dir.filePath(QStringLiteral("config.json"))) &&
          QFileInfo(dir.filePath(QStringLiteral("src"))).isDir()) {
        found = true;
        break;
      }
      if (!dir.cdUp()) break;
    }
    logRoot = found ? dir.absolutePath() : QCoreApplication::applicationDirPath();
    logRoot += QStringLiteral("/tmp/log");
  }
  QDir().mkpath(logRoot);

  const QString timestamp =
      QDateTime::currentDateTime().toString(QStringLiteral("yyyyMMdd_HHmmss"));
  m_logFilePath = logRoot + QStringLiteral("/mqtt_full_") + timestamp + QStringLiteral(".jsonl");

  m_file.setFileName(m_logFilePath);
  if (!m_file.open(QIODevice::WriteOnly | QIODevice::Append | QIODevice::Text)) {
    qWarning() << "MqttLogger: Failed to open log file:" << m_logFilePath;
    return;
  }

  m_isActive = true;
  qInfo() << "MqttLogger: Session started, log:" << m_logFilePath;
}

void MqttLogger::stopSession() {
  if (thread() != QThread::currentThread()) {
    QMetaObject::invokeMethod(this, [this] { stopSession(); },
                              Qt::QueuedConnection);
    return;
  }
  flushBuffer();

  if (m_file.isOpen()) {
    m_file.close();
  }

  if (m_isActive) {
    qInfo() << "MqttLogger: Session stopped, logged to:" << m_logFilePath;
    m_isActive = false;
  }
}

bool MqttLogger::isActive() const {
  return m_isActive;
}

// ============================================================================
// 日志方法（线程安全）
// ============================================================================

void MqttLogger::logRx(const QString &topic, const QByteArray &payload) {
  if (!m_isActive) return;
  if (shouldSkip(topic, payload)) return;

  QJsonObject obj;
  obj.insert(QStringLiteral("ts"),
             QDateTime::currentDateTime().toString(Qt::ISODateWithMs));
  obj.insert(QStringLiteral("dir"), QStringLiteral("rx"));
  obj.insert(QStringLiteral("topic"), topic);
  obj.insert(QStringLiteral("bytes"), payload.size());
  obj.insert(QStringLiteral("hex"),
             QString::fromLatin1(payload.toHex()));

  appendLine(QString::fromUtf8(
      QJsonDocument(obj).toJson(QJsonDocument::Compact)));
}

void MqttLogger::logTx(const QString &topic, const QByteArray &payload) {
  if (!m_isActive) return;

  QJsonObject obj;
  obj.insert(QStringLiteral("ts"),
             QDateTime::currentDateTime().toString(Qt::ISODateWithMs));
  obj.insert(QStringLiteral("dir"), QStringLiteral("tx"));
  obj.insert(QStringLiteral("topic"), topic);
  obj.insert(QStringLiteral("bytes"), payload.size());
  obj.insert(QStringLiteral("hex"),
             QString::fromLatin1(payload.toHex()));

  appendLine(QString::fromUtf8(
      QJsonDocument(obj).toJson(QJsonDocument::Compact)));
}

// ============================================================================
// 私有方法
// ============================================================================

bool MqttLogger::shouldSkip(const QString &topic, const QByteArray &payload) {
  Q_UNUSED(payload)
  // 跳过 CustomByteBlock 中的 H.264 视频帧（>100 字节视为视频数据）
  // 28~100 字节的 CustomByteBlock 是机器人自定义状态数据，需要保留
  if (topic == QLatin1String("CustomByteBlock") && payload.size() > 100) {
    return true;
  }
  return false;
}

void MqttLogger::appendLine(const QString &line) {
  QMutexLocker locker(&m_mutex);
  m_buffer.append(line);

  // 满了就地刷盘。这一步确实会做文件 I/O，且可能发生在 MQTT 回调线程上，
  // 但每 MAX_BUFFER_SIZE 行才一次、写的又是已打开的文件，
  // 这点代价远小于"为了躲它而让整个客户端崩掉"。
  if (m_buffer.size() >= MAX_BUFFER_SIZE) {
    flushLocked();
  }
}

void MqttLogger::flushBuffer() {
  QMutexLocker locker(&m_mutex);
  flushLocked();
}

void MqttLogger::flushLocked() {
  if (m_buffer.isEmpty()) {
    return;
  }
  if (!m_file.isOpen()) {
    // 文件没打开就别继续攒，否则缓冲区只增不减
    m_buffer.clear();
    return;
  }

  for (const QString &line : std::as_const(m_buffer)) {
    m_file.write(line.toUtf8());
    m_file.write("\n");
  }
  m_buffer.clear();
  m_file.flush();
}
