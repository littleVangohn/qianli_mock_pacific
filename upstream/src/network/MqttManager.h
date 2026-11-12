// SPDX-License-Identifier: MIT
/**
 * @file MqttManager.h
 * @brief MQTT 客户端管理器
 * @details 封装 Eclipse Paho MQTT C 客户端，实现与裁判系统服务器的 MQTT 通信。
 *          按照官方《RoboMaster 2026 通信协议 V1.2.0》的自定义客户端协议规范。
 * @author Clear
 * @date 2026-02-08
 * @copyright Copyright (c) 2026 Fudan University EGA Team (复旦大学星云 EGA 机器人战队).
 */

#ifndef MQTTMANAGER_H
#define MQTTMANAGER_H

// ============================================================================
// Qt 头文件
// ============================================================================
#include <QByteArray>
#include <QMap>
#include <QObject>
#include <QString>
#include <QTimer>
#include <QtGlobal>

#include <atomic>

// ============================================================================
// Paho MQTT C 头文件
// ============================================================================
#ifdef RM_HAS_MQTT
extern "C" {
#include <MQTTClient.h>
}
#else
// 定义空类型以避免编译错误
typedef void* MQTTClient;
typedef void* MQTTClient_message;
typedef int MQTTClient_deliveryToken;
#endif

/**
 * @class MqttManager
 * @brief MQTT 客户端管理器
 * @details 实现 MQTT 发布/订阅通信，用于自定义客户端协议。
 *          - 订阅：GameStatus、GlobalUnitStatus、RobotDynamicStatus 等
 *          - 发布：CommonCommand、MapClickInfoNotify、CustomControl 等
 */
class MqttManager : public QObject {
  Q_OBJECT

public:
  /**
   * @brief 构造函数
   * @param parent 父对象
   */
  explicit MqttManager(QObject *parent = nullptr);

  /**
   * @brief 析构函数
   */
  ~MqttManager();

  /**
   * @brief 异步连接到 MQTT Broker（非阻塞）
   * @details TCP 连接在后台线程执行，连接结果通过 connectCompleted 信号通知。
   *          调用线程不会被阻塞，避免了 UI 卡顿。
   * @param serverUri 服务器地址，格式 "tcp://ip:port"
   * @param clientId 客户端 ID
   */
  void connectToBrokerAsync(const QString &serverUri, const QString &clientId);

  /**
   * @brief 断开连接
   */
  void disconnect();

  /**
   * @brief 检查是否已连接
   * @return bool 连接状态
   */
  bool isConnected() const;

  /**
   * @brief 最近一条 MQTT 消息在 Paho 回调线程被观察到的本地时间
   * @details 0 表示本次连接尚未收到任何消息。
   *          业务层看门狗必须用这个时间，不能用主线程处理消息的时间：
   *          视频渲染把主线程卡住几秒时，数据其实一直在进来，旧写法会
   *          误判"数据流停滞"并把一条好连接拆掉。
   */
  qint64 lastMessageArrivedMs() const;

  /**
   * @brief 强制拆掉当前连接并立即重建
   * @details 用于"连接还在、数据却停了"的假死场景：TCP 与心跳都正常，
   *          MQTT 层永远不会报错，只能由业务层发现后主动重来。
   * @param reason 触发原因（写日志用）
   */
  void forceReconnect(const QString &reason);

  /**
   * @brief 订阅主题
   * @param topic 主题名称（如 "GameStatus"）
   * @param qos QoS 等级（0, 1, 2）
   * @return bool 订阅是否成功
   */
  bool subscribe(const QString &topic, int qos = 1);

  /**
   * @brief 发布消息
   * @param topic 主题名称
   * @param payload 消息载荷（Protobuf 序列化后的二进制）
   * @param qos QoS 等级
   * @param waitForCompletionMs 等待投递完成的最长时间；0 表示不阻塞等待
   * @return bool 发布是否成功
   */
  bool publish(const QString &topic, const QByteArray &payload, int qos = 1,
               int waitForCompletionMs = 1000);

signals:
  /**
   * @brief 连接状态变化信号
   * @param connected 是否已连接
   */
  void connectionStateChanged(bool connected);

  /**
   * @brief 接收到消息信号
   * @param topic 主题名称
   * @param payload 消息载荷
   */
  void messageReceived(const QString &topic, const QByteArray &payload);

  /**
   * @brief 接收到 MQTT 消息时的本地观测信号
   * @details 该信号只表达“客户端本机在回调中观察到消息”的时间点，
   *          不代表赛事引擎真实 publish 时间。普通 topic 每条发出；高频
   *          CustomByteBlock 视频默认最多每秒采样一次，设置
   *          RM_VERBOSE_VIDEO_LOG=1 可恢复逐条观测。
   *
   * @param topic 主题名称
   * @param payloadSize 负载字节数
   * @param payloadSha1 负载 SHA1，供外部相关性匹配使用
   * @param receivedMs 本地观测时间戳（毫秒）
   */
  void messageObserved(const QString &topic, int payloadSize,
                       const QString &payloadSha1, qint64 receivedMs);

  /**
   * @brief 错误发生信号
   * @param error 错误信息
   */
  void errorOccurred(const QString &error);

  /**
   * @brief 连接完成信号（异步连接结果）
   * @param success 是否连接成功
   * @param error 失败时的错误描述
   */
  void connectCompleted(bool success, const QString &error);

  /**
   * @brief 连接尝试已开始信号
   */
  void connectingStarted();

private:
  // --- MQTT 客户端句柄 ---
  MQTTClient m_client; // Paho MQTT 客户端句柄

  // --- 连接配置 ---
  QString m_serverUri;      // 服务器地址
  QString m_clientId;       // 客户端 ID
  bool m_connected = false;  // 连接状态
  bool m_connecting = false; // 防重入：正在进行异步连接

  // --- 重连定时器 ---
  QTimer *m_reconnectTimer = nullptr; // 自动重连定时器
  int m_retryCount = 0;               // 连续失败次数，用于算退避（不设上限）
  int m_reconnectInterval = 5000;     // 定时器当前间隔 (ms)，退避时动态调整

  /**
   * @brief 计算下一次重连的等待时长（指数退避 + 抖动）
   * @details 固定间隔有两个坏处：单机恢复慢（白等满一个周期），
   *          多机则会在同一时刻一起重连，把 broker 打出重连风暴。
   */
  int nextReconnectDelayMs() const;

  /**
   * @brief 关闭并销毁当前 Paho 客户端
   * @details 已连接时必须先 MQTTClient_disconnect 再 destroy。只 destroy
   *          不会发 DISCONNECT，broker 会一直保留这个会话，紧接着用同一
   *          ClientId 重连就会被判成"重复登录"（CONNACK 2）。
   */
  void destroyClient();

  // 视频消息只保留每秒一次的 DevHooks/延迟观测，避免数百条/秒的 trace
  // 压垮 UI，同时不破坏 messageObserved 的诊断契约。
  std::atomic<qint64> m_lastVideoObservationMs{0};

  // 最近一条消息到达时间（Paho 回调线程写，主线程读）
  std::atomic<qint64> m_lastMessageArrivedMs{0};

  // --- 消息回调处理 ---
  static int messageArrivedCallback(void *context, char *topicName,
                                    int topicLen, MQTTClient_message *message);
  static void connectionLostCallback(void *context, char *cause);
  static void deliveryCompleteCallback(void *context,
                                       MQTTClient_deliveryToken token);

private slots:
  /**
   * @brief 尝试重新连接
   */
  void tryReconnect();

  /**
   * @brief 异步连接完成后的回调（在主线程执行）
   * @param rc MQTTClient_connect 返回值
   */
  void onConnectCompleted(int rc);
};

#endif // MQTTMANAGER_H
