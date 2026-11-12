#ifndef ENGINERAMORLOGWATCHER_H
#define ENGINERAMORLOGWATCHER_H

#include <QObject>
#include <QString>
#include <QTimer>

class GameData;
class QFile;

/**
 * @class EngineArmorLogWatcher
 * @brief 从引擎 CSV 日志里取权威的装甲受击方向。
 *
 * @details 官方自定义客户端协议不带装甲板 ID：RobotInjuryStat 只有 killer_id，
 *          Event 的 event_id 已被符文/飞镖/狙击占满，RobotPosition 只给本机。
 *          所以受击方向只能从引擎自己写的日志里取 —— 这也是这个类存在的唯一理由。
 *
 *          日志行形如（分隔符在不同版本间变过，正则用 .*? 兜住）：
 *            [RobotR1] 装甲3受击.受击类型:3, 受击质心坐标:-1,-1, ...
 *          抓到的装甲号映射成方向后写进 GameData::setHitDirection()。
 *
 *          只在装了引擎的机器上有数据；取不到时静默降级，不影响其它链路。
 */
class EngineArmorLogWatcher : public QObject {
  Q_OBJECT

 public:
  /**
   * @param gameData  受击方向的落点
   * @param directory 引擎日志目录；为空时用 defaultLogDirectory()
   * @param parent    QObject 父对象
   */
  explicit EngineArmorLogWatcher(GameData *gameData, const QString &directory = QString(),
                                 QObject *parent = nullptr);
  ~EngineArmorLogWatcher() override;

  /// 引擎默认日志目录（学生版引擎的固定布局）。
  static QString defaultLogDirectory();

  /// 解析单行日志，返回装甲号（0-3）；这行不含受击时返回 -1。
  static int parseArmorIdFromLine(const QString &line);

 private slots:
  void poll();

 private:
  void closeCurrent();
  bool openNewest();

  GameData *m_gameData = nullptr;
  QString m_directory;
  QTimer *m_timer = nullptr;
  QFile *m_file = nullptr;
  QString m_filePath;
  qint64 m_offset = 0;
  QString m_partialLine; // 跨轮询的半行缓冲
};

#endif // ENGINERAMORLOGWATCHER_H
