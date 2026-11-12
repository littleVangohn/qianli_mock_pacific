// SPDX-License-Identifier: MIT
/**
 * @file MqttManager.cpp
 * @brief MQTT 客户端管理器实现
 * @details 封装 Eclipse Paho MQTT C 客户端，实现与裁判系统服务器的 MQTT 通信。
 * @author Clear
 * @date 2026-02-08
 * @copyright Copyright (c) 2026 Fudan University EGA Team (复旦大学星云 EGA 机器人战队).
 */

#include "MqttManager.h"
#include "MqttLogger.h"
#include <QCryptographicHash>
#include <QDebug>
#include <QDateTime>
#include <QMetaObject>
#include <QRandomGenerator>
#include <QTcpSocket>
#include <QThreadPool>
#include <QUrl>
#include <algorithm>

namespace {

bool verboseVideoLogEnabled() {
  static const bool enabled = qEnvironmentVariableIsSet("RM_VERBOSE_VIDEO_LOG");
  return enabled;
}

bool isHighRateVideoMessage(const QString &topic, const QByteArray &payload) {
  return topic == QLatin1String("CustomByteBlock") && payload.size() > 100;
}

} // namespace

// ============================================================================
// 构造函数 / 析构函数
// ============================================================================

MqttManager::MqttManager(QObject *parent) : QObject(parent) {
  m_client = nullptr;
  // 初始化重连定时器
  m_reconnectTimer = new QTimer(this);
  m_reconnectTimer->setInterval(m_reconnectInterval);
  connect(m_reconnectTimer, &QTimer::timeout, this, &MqttManager::tryReconnect);
}

MqttManager::~MqttManager() { disconnect(); }

// ============================================================================
// 连接管理
// ============================================================================

void MqttManager::connectToBrokerAsync(const QString &serverUri,
                                       const QString &clientId) {
#ifdef RM_HAS_MQTT
  if (m_connecting) {
    qWarning() << "MqttManager: connectToBroker already in progress, skipping";
    emit connectCompleted(false, QStringLiteral("Connection already in progress"));
    return;
  }
  m_connecting = true;
  emit connectingStarted();

  m_serverUri = serverUri;
  m_clientId = clientId;
  // 本次连接的观测从零开始：没收到消息之前，看门狗不应该判定"停滞"。
  m_lastMessageArrivedMs.store(0, std::memory_order_relaxed);

  // 创建 MQTT 客户端（指定 MQTT 3.1.1 版本）
  MQTTClient_createOptions opts = MQTTClient_createOptions_initializer;
  opts.MQTTVersion = MQTTVERSION_3_1_1;
  int rc = MQTTClient_createWithOptions(&m_client, m_serverUri.toUtf8().constData(),
                                        m_clientId.toUtf8().constData(),
                                        MQTTCLIENT_PERSISTENCE_NONE, nullptr, &opts);
  if (rc != MQTTCLIENT_SUCCESS) {
    qWarning() << "MqttManager: Failed to create MQTT client, rc=" << rc;
    emit errorOccurred(QString("Failed to create MQTT client: %1").arg(rc));
    m_connecting = false;
    emit connectCompleted(false, QString("Failed to create MQTT client: %1").arg(rc));
    return;
  }

  // 设置回调函数
  rc =
      MQTTClient_setCallbacks(m_client, this, connectionLostCallback,
                              messageArrivedCallback, deliveryCompleteCallback);
  if (rc != MQTTCLIENT_SUCCESS) {
    qWarning() << "MqttManager: Failed to set callbacks, rc=" << rc;
    emit errorOccurred(QString("Failed to set callbacks: %1").arg(rc));
    m_connecting = false;
    emit connectCompleted(false, QString("Failed to set callbacks: %1").arg(rc));
    return;
  }

  // 配置连接选项
  MQTTClient_connectOptions connOpts = MQTTClient_connectOptions_initializer;
  // 心跳 10 秒。原来 20 秒意味着"连接真死"最长要 30 秒才被发现。
  // 缩短的代价只是空闲时多两个字节的 PINGREQ，局域网可忽略。
  // 注意：客户端持续上行发包时 Paho 不会发 PINGREQ，心跳帮不上忙——
  // 那种假死由 NetworkManager 的业务层看门狗负责。
  connOpts.keepAliveInterval = 10;
  connOpts.cleansession = 1;       // 每次连接清除会话
  connOpts.connectTimeout = 2;     // 连接超时 2秒，避免 UI 在切换机器人时长时间卡顿
  connOpts.MQTTVersion = MQTTVERSION_3_1_1;  // 使用 MQTT 3.1.1（大多数 broker 要求）

  // 连接到 Broker
  qDebug() << "MqttManager: Connecting to" << m_serverUri;
  qInfo() << "MqttManager: Using clientId=" << m_clientId;

  // 预检：尝试解析 URI 并测试 TCP 连通性
  QUrl url(m_serverUri);
  if (!url.isValid()) {
    qWarning() << "MqttManager: [DIAGNOSIS] Invalid URI format:" << m_serverUri;
  } else {
    qDebug() << "MqttManager: Parsed host=" << url.host() << "port=" << url.port();

    // 切换机器人时会频繁切换 clientId，这里避免做 5s 的同步 TCP 预检，
    // 否则 UI 线程会明显卡顿；实际连通性由 MQTTClient_connect 返回值兜底。
    qDebug() << "MqttManager: Skip blocking TCP preflight check";
  }

  // 真正异步执行 MQTTClient_connect：后台线程执行 TCP 连接，
  // 主线程通过 onConnectCompleted 接收结果，完全无阻塞。
  QThreadPool::globalInstance()->start([this, connOpts]() mutable {
    int result = MQTTClient_connect(m_client, &connOpts);
    QMetaObject::invokeMethod(this, [this, result]() {
      onConnectCompleted(result);
    }, Qt::QueuedConnection);
  });
#else
  Q_UNUSED(serverUri);
  Q_UNUSED(clientId);
  qWarning() << "MqttManager: MQTT disabled at compile time";
  emit connectCompleted(false, QStringLiteral("MQTT disabled at compile time"));
#endif
}

void MqttManager::disconnect() {
  m_reconnectTimer->stop();

#ifdef RM_HAS_MQTT
  if (m_client && m_connected) {
    // 缩短断开等待，降低切换机器人时 UI 卡顿感
    MQTTClient_disconnect(m_client, 100);
    m_connected = false;
    emit connectionStateChanged(false);
  }

  if (m_client) {
    MQTTClient_destroy(&m_client);
    m_client = nullptr;
  }
#endif

  qDebug() << "MqttManager: Disconnected";
}

void MqttManager::destroyClient() {
#ifdef RM_HAS_MQTT
  if (!m_client) {
    return;
  }
  // 关键顺序：先 DISCONNECT 再 destroy。只 destroy 不会通知 broker，
  // 旧会话会一直占着 ClientId，下一次 connect 就会被判"重复登录"。
  if (MQTTClient_isConnected(m_client)) {
    MQTTClient_disconnect(m_client, 200);
  }
  MQTTClient_destroy(&m_client);
  m_client = nullptr;
#endif
}

bool MqttManager::isConnected() const {
#ifdef RM_HAS_MQTT
  return m_connected && m_client && MQTTClient_isConnected(m_client);
#else
  return false;
#endif
}

qint64 MqttManager::lastMessageArrivedMs() const {
  return m_lastMessageArrivedMs.load(std::memory_order_relaxed);
}

// ============================================================================
// 订阅 / 发布
// ============================================================================

bool MqttManager::subscribe(const QString &topic, int qos) {
  if (!isConnected()) {
    qWarning() << "MqttManager: Cannot subscribe, not connected";
    return false;
  }

#ifdef RM_HAS_MQTT
  int rc = MQTTClient_subscribe(m_client, topic.toUtf8().constData(), qos);
  if (rc != MQTTCLIENT_SUCCESS) {
    qWarning() << "MqttManager: Failed to subscribe to" << topic
               << ", rc=" << rc;
    emit errorOccurred(
        QString("Failed to subscribe to %1: %2").arg(topic).arg(rc));
    return false;
  }

  qDebug() << "MqttManager: Subscribed to" << topic;
  return true;
#else
  Q_UNUSED(topic);
  Q_UNUSED(qos);
  return false;
#endif
}

bool MqttManager::publish(const QString &topic, const QByteArray &payload,
                          int qos, int waitForCompletionMs) {
  const qint64 publishStartMs = QDateTime::currentMSecsSinceEpoch();
  if (!isConnected()) {
    qWarning() << "MqttManager: Cannot publish, not connected";
    const qint64 publishDoneMs = QDateTime::currentMSecsSinceEpoch();
    qInfo().noquote()
        << QStringLiteral(
               "RM26_COMMAND_TIMING direction=tx topic=%1 start_ms=%2 "
               "queued_ms=%3 done_ms=%4 publish_call_ms=%5 wait_ms=%6 "
               "qos=%7 bytes=%8 ok=0 error=not_connected")
               .arg(topic)
               .arg(publishStartMs)
               .arg(-1)
               .arg(publishDoneMs)
               .arg(-1)
               .arg(-1)
               .arg(qos)
               .arg(payload.size());
    return false;
  }

#ifdef RM_HAS_MQTT
  MQTTClient_message pubmsg = MQTTClient_message_initializer;
  pubmsg.payload = (void *)payload.constData();
  pubmsg.payloadlen = payload.size();
  pubmsg.qos = qos;
  pubmsg.retained = 0;

  MQTTClient_deliveryToken token;
  int rc = MQTTClient_publishMessage(m_client, topic.toUtf8().constData(),
                                     &pubmsg, &token);
  const qint64 publishQueuedMs = QDateTime::currentMSecsSinceEpoch();
  if (rc != MQTTCLIENT_SUCCESS) {
    qWarning() << "MqttManager: Failed to publish to" << topic << ", rc=" << rc;
    const qint64 publishDoneMs = QDateTime::currentMSecsSinceEpoch();
    qInfo().noquote()
        << QStringLiteral(
               "RM26_COMMAND_TIMING direction=tx topic=%1 start_ms=%2 "
               "queued_ms=%3 done_ms=%4 publish_call_ms=%5 wait_ms=%6 "
               "qos=%7 bytes=%8 ok=0 rc=%9")
               .arg(topic)
               .arg(publishStartMs)
               .arg(publishQueuedMs)
               .arg(publishDoneMs)
               .arg(publishQueuedMs - publishStartMs)
               .arg(-1)
               .arg(qos)
               .arg(payload.size())
               .arg(rc);
    return false;
  }

  qint64 waitMs = 0;
  if (waitForCompletionMs > 0) {
    const qint64 waitStartMs = QDateTime::currentMSecsSinceEpoch();
    rc = MQTTClient_waitForCompletion(m_client, token,
                                      static_cast<unsigned long>(waitForCompletionMs));
    waitMs = QDateTime::currentMSecsSinceEpoch() - waitStartMs;
    if (rc != MQTTCLIENT_SUCCESS) {
      qWarning() << "MqttManager: Message delivery timeout for" << topic;
      const qint64 publishDoneMs = QDateTime::currentMSecsSinceEpoch();
      qInfo().noquote()
          << QStringLiteral(
                 "RM26_COMMAND_TIMING direction=tx topic=%1 start_ms=%2 "
                 "queued_ms=%3 done_ms=%4 publish_call_ms=%5 wait_ms=%6 "
                 "qos=%7 bytes=%8 ok=0 rc=%9")
                 .arg(topic)
                 .arg(publishStartMs)
                 .arg(publishQueuedMs)
                 .arg(publishDoneMs)
                 .arg(publishQueuedMs - publishStartMs)
                 .arg(waitMs)
                 .arg(qos)
                 .arg(payload.size())
                 .arg(rc);
      return false;
    }
  }

  const qint64 publishDoneMs = QDateTime::currentMSecsSinceEpoch();
  qInfo().noquote()
      << QStringLiteral(
             "RM26_COMMAND_TIMING direction=tx topic=%1 start_ms=%2 "
             "queued_ms=%3 done_ms=%4 publish_call_ms=%5 wait_ms=%6 "
             "qos=%7 bytes=%8 ok=1 rc=0")
             .arg(topic)
             .arg(publishStartMs)
             .arg(publishQueuedMs)
             .arg(publishDoneMs)
             .arg(publishQueuedMs - publishStartMs)
             .arg(waitMs)
             .arg(qos)
             .arg(payload.size());

  MqttLogger::instance()->logTx(topic, payload);
  return true;
#else
  Q_UNUSED(topic);
  Q_UNUSED(payload);
  Q_UNUSED(qos);
  Q_UNUSED(waitForCompletionMs);
  return false;
#endif
}

// ============================================================================
// 回调函数
// ============================================================================

#ifdef RM_HAS_MQTT

int MqttManager::messageArrivedCallback(void *context, char *topicName,
                                        int topicLen,
                                        MQTTClient_message *message) {
  Q_UNUSED(topicLen);
  MqttManager *self = static_cast<MqttManager *>(context);
  if (!self) {
    MQTTClient_freeMessage(&message);
    MQTTClient_free(topicName);
    return 1;
  }

  QString topic = QString::fromUtf8(topicName);
  QByteArray payload((const char *)message->payload, message->payloadlen);
  const qint64 receivedMs = QDateTime::currentMSecsSinceEpoch();
  // 看门狗的时间基准：这里在 Paho 接收线程执行，不受 UI/视频渲染卡顿影响。
  self->m_lastMessageArrivedMs.store(receivedMs, std::memory_order_relaxed);
  const bool detailedTrace =
      !isHighRateVideoMessage(topic, payload) || verboseVideoLogEnabled();
  bool sampledVideoObservation = false;
  if (!detailedTrace) {
    qint64 lastObservedMs =
        self->m_lastVideoObservationMs.load(std::memory_order_relaxed);
    if (receivedMs - lastObservedMs >= 1000 &&
        self->m_lastVideoObservationMs.compare_exchange_strong(
            lastObservedMs, receivedMs, std::memory_order_relaxed)) {
      sampledVideoObservation = true;
    }
  }
  const bool observeMessage = detailedTrace || sampledVideoObservation;
  QString payloadSha1;
  if (observeMessage) {
    payloadSha1 = QString::fromLatin1(
        QCryptographicHash::hash(payload, QCryptographicHash::Sha1).toHex());
    if (detailedTrace) {
      qDebug() << "MqttManager: Message received on topic:" << topic
               << ", size:" << payload.size();
    }
    qInfo().noquote()
        << QStringLiteral(
               "RM26_MQTT_RX_TIMING direction=rx topic=%1 received_ms=%2 "
               "bytes=%3 sha1=%4")
               .arg(topic)
               .arg(receivedMs)
               .arg(payload.size())
               .arg(payloadSha1);
  }

  // 记录完整的 MQTT 消息到日志文件（排除视频帧）
  MqttLogger::instance()->logRx(topic, payload);

  QMetaObject::invokeMethod(
      self,
      [self, topic, payload, payloadSha1, receivedMs, observeMessage]() {
        if (observeMessage) {
          emit self->messageObserved(topic, payload.size(), payloadSha1,
                                     receivedMs);
        }
        emit self->messageReceived(topic, payload);
      },
      Qt::QueuedConnection);

  MQTTClient_freeMessage(&message);
  MQTTClient_free(topicName);
  return 1;
}

void MqttManager::connectionLostCallback(void *context, char *cause) {
  MqttManager *self = static_cast<MqttManager *>(context);
  if (!self)
    return;

  QString reason = cause ? QString::fromUtf8(cause) : "Unknown";
  QMetaObject::invokeMethod(
      self,
      [self, reason]() {
        self->m_connected = false;
        qWarning() << "MqttManager: Connection lost, reason:" << reason;

        emit self->connectionStateChanged(false);
        emit self->errorOccurred(QString("Connection lost: %1").arg(reason));

        // 通过 QObject 所在线程启动重连定时器，避免 Paho 回调线程直接碰 Qt timer。
        // 首次重连走最短退避——原来的固定 5 秒意味着每掉一次线都白等 5 秒。
        self->m_retryCount = 0;
        self->m_reconnectTimer->setInterval(self->nextReconnectDelayMs());
        self->m_reconnectTimer->start();
      },
      Qt::QueuedConnection);
}

void MqttManager::deliveryCompleteCallback(void *context,
                                           MQTTClient_deliveryToken token) {
  Q_UNUSED(context);
  Q_UNUSED(token);
  // 消息发送完成，可用于日志或调试
}

// ============================================================================
// 异步连接完成处理（在主线程执行）
// ============================================================================

void MqttManager::onConnectCompleted(int rc) {
  m_connecting = false;

  if (rc != MQTTCLIENT_SUCCESS) {
    qWarning() << "MqttManager: Failed to connect, rc=" << rc;
    QString errorDetail =
        QStringLiteral("MQTT connect failed (rc=%1, clientId=%2, broker=%3)")
            .arg(rc)
            .arg(m_clientId, m_serverUri);
    bool shouldRetry = true;

    // CONNACK 错误码诊断 (Paho MQTT C 返回码 1-5 表示 broker 拒绝)
    if (rc == 1) {
      qWarning() << "MqttManager: [DIAGNOSIS] CONNACK(1): Bad protocol version";
      errorDetail = QStringLiteral("MQTT CONNACK(1): bad protocol version");
      shouldRetry = false;
    } else if (rc == 2) {
      // 官方选手端的 broker 对同一个 ClientId 只保留一个在线会话：网络闪断、
      // 看门狗重建连接时，旧会话可能还没被 broker 回收，新连接就会拿到
      // CONNACK(2)（日志里是"自定义客户端重复登录"）。这不是配置错误，
      // 等旧会话超时/关闭后重试即可恢复，所以这里必须继续重试。
      qWarning() << "MqttManager: [DIAGNOSIS] CONNACK(2): Identifier rejected - clientId '"
                 << m_clientId << "' was rejected by broker";
      qWarning() << "MqttManager: [SUGGESTION] 通常是上一个会话还没被 broker 回收"
                 << "（重复登录）。会按退避继续重试；若长期失败再检查"
                 << "RM_CLIENT_ROBOT_ID / 引擎自定义客户端注册 / broker 地址";
      errorDetail =
          QStringLiteral("MQTT CONNACK(2): identifier rejected for clientId=%1 "
                         "(broker=%2). 通常是旧会话仍被 broker 视为在线（重复登录），"
                         "将自动退避重试；若持续失败再检查 "
                         "network.client_robot_id/RM_CLIENT_ROBOT_ID 与引擎注册。")
              .arg(m_clientId, m_serverUri);
    } else if (rc == 3) {
      qWarning() << "MqttManager: [DIAGNOSIS] CONNACK(3): Server unavailable";
      errorDetail = QStringLiteral("MQTT CONNACK(3): server unavailable");
    } else if (rc == 4) {
      qWarning() << "MqttManager: [DIAGNOSIS] CONNACK(4): Bad username or password";
      errorDetail = QStringLiteral("MQTT CONNACK(4): bad username or password");
      shouldRetry = false;
    } else if (rc == 5) {
      qWarning() << "MqttManager: [DIAGNOSIS] CONNACK(5): Not authorized";
      errorDetail = QStringLiteral("MQTT CONNACK(5): not authorized");
      shouldRetry = false;
    } else if (rc == 133) {
      qWarning() << "MqttManager: [DIAGNOSIS] CONNACK(133): Client identifier not valid - clientId '"
                 << m_clientId << "' was rejected by broker";
      qWarning() << "MqttManager: [SUGGESTION] Use the robot ID accepted by the current field broker"
                 << "(override with RM_CLIENT_ROBOT_ID=<id>)";
      errorDetail =
          QStringLiteral("MQTT CONNACK(133): clientId=%1 not valid for broker=%2. "
                         "Check network.client_robot_id or RM_CLIENT_ROBOT_ID.")
              .arg(m_clientId, m_serverUri);
      shouldRetry = false;
    } else if (rc == 134) {
      qWarning() << "MqttManager: [DIAGNOSIS] CONNACK(134): Bad username or password";
      errorDetail = QStringLiteral("MQTT CONNACK(134): bad username or password");
      shouldRetry = false;
    } else if (rc == 135) {
      qWarning() << "MqttManager: [DIAGNOSIS] CONNACK(135): Not authorized";
      errorDetail = QStringLiteral("MQTT CONNACK(135): not authorized");
      shouldRetry = false;
    } else if (rc == 136) {
      qWarning() << "MqttManager: [DIAGNOSIS] CONNACK(136): Server unavailable";
      errorDetail = QStringLiteral("MQTT CONNACK(136): server unavailable");
    } else if (rc == -1) {
      qWarning() << "MqttManager: [DIAGNOSIS] Network/transport error (code: -1)";
      qWarning() << "MqttManager: [SUGGESTION] This usually means:";
      qWarning() << "  - TCP connection refused (broker not running)";
      qWarning() << "  - Network unreachable";
      qWarning() << "  - SSL/TLS handshake failure (if using ssl://)";
      errorDetail = QStringLiteral("MQTT transport error (rc=-1): connection refused/unreachable");
    } else if (rc < 0) {
      qWarning() << "MqttManager: [DIAGNOSIS] Network/transport error (code:" << rc << ")";
      errorDetail = QStringLiteral("MQTT transport error (rc=%1)").arg(rc);
    }

    // 清理失败的客户端句柄，避免下次重连时创建新句柄导致旧句柄泄漏
    destroyClient();

    // 这里原来有个"最多试 3 次就放弃"的上限。它有个致命的副作用：
    // broker 中断超过约 26 秒（4 次尝试 × 5 秒 + 连接超时），客户端会
    // **永久停止重连**，只能靠人工切换机器人或重启才能救回来。
    // 比赛现场官方选手端重启、网络闪断都可能超过 26 秒。
    // 现在改成不限次数，靠指数退避 + 上限来兜住频率，而不是靠放弃。
    if (shouldRetry) {
      m_retryCount++;
      const int delayMs = nextReconnectDelayMs();
      m_reconnectTimer->setInterval(delayMs);
      m_reconnectTimer->start();
      qWarning() << "MqttManager: 第" << m_retryCount << "次重连失败，"
                 << delayMs << "ms 后重试（不限次数）";
    }

    emit errorOccurred(errorDetail);
    emit connectCompleted(false, errorDetail);
    return;
  }

  // 连接成功
  m_connected = true;
  m_retryCount = 0;
  m_reconnectTimer->stop();
  qDebug() << "MqttManager: Connected successfully";
  emit connectionStateChanged(true);
  emit connectCompleted(true, QString());
}

// ============================================================================
// 重连逻辑
// ============================================================================

void MqttManager::tryReconnect() {
  if (isConnected()) {
    m_reconnectTimer->stop();
    return;
  }

  if (m_connecting) {
    qDebug() << "MqttManager: Reconnect skipped, already connecting";
    return;
  }

  qDebug() << "MqttManager: Attempting to reconnect...";

  // 销毁旧客户端（已连接时先发 DISCONNECT，见 destroyClient 注释）
  destroyClient();

  // 重新连接
  connectToBrokerAsync(m_serverUri, m_clientId);
}

int MqttManager::nextReconnectDelayMs() const {
  constexpr int kBase = 500;
  // 上限压在 2 秒，这是权衡出来的：
  //   看门狗会主动拆连接，而链路中断期间连不回来；
  //   等链路恢复时，客户端最坏要等"下一次重试"才连得上，
  //   这个等待就是恢复延迟的一部分。上限越大，恢复越慢。
  // 2 秒意味着最坏多等 ~2 秒，而重试频率也不过 0.5 次/秒，
  // 20 台客户端同时重连也只是 10 次/秒，打不垮 broker。
  constexpr int kCap = 2000;
  // 500, 1000, 2000, 4000 → 封顶 2000
  const int exp = std::min(kBase << std::min(m_retryCount, 4), kCap);
  // 抖动取 [exp/2, exp]：既打散多台客户端同时重连的时刻，
  // 又保留一个最小等待，不会退避成忙等。
  return exp / 2 + QRandomGenerator::global()->bounded(exp / 2 + 1);
}

void MqttManager::forceReconnect(const QString &reason) {
  if (m_connecting) {
    return;  // 已经在连了，别插队
  }
  qWarning() << "MqttManager: 强制重建连接，原因:" << reason;

  m_reconnectTimer->stop();
  m_retryCount = 0;
  m_connected = false;
  emit connectionStateChanged(false);
  emit errorOccurred(QString("Force reconnect: %1").arg(reason));

  // 立即重试一次；若仍失败，会自然落到上面的退避逻辑里
  tryReconnect();
}

#endif // RM_HAS_MQTT
