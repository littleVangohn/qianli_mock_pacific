#include "EngineArmorLogWatcher.h"

#include "GameData.h"

#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QRegularExpression>
#include <QRegularExpressionMatch>
#include <QTextStream>

namespace {

// 日志形如：[RobotR1] 装甲3受击.受击类型:3, ...
// 历史上分隔符出现过逗号和句点两种，用 .*? 兜住；中英文冒号都认。
const QRegularExpression &armorHitPattern() {
  static const QRegularExpression re(
      QStringLiteral("装甲(\\d+)受击.*?受击类型[:：](\\d+)"));
  return re;
}

// 采样间隔。引擎按事件写日志，500ms 足够跟手，也不会把磁盘读爆。
constexpr int kPollIntervalMs = 500;

// 单次轮询最多读这么多字节，避免首次打开 74MB 日志时卡住 UI 线程。
constexpr qint64 kMaxReadPerPoll = 512 * 1024;

} // namespace

EngineArmorLogWatcher::EngineArmorLogWatcher(GameData *gameData,
                                             const QString &directory,
                                             QObject *parent)
    : QObject(parent), m_gameData(gameData) {
  m_directory = directory.isEmpty() ? defaultLogDirectory() : directory;

  m_timer = new QTimer(this);
  m_timer->setInterval(kPollIntervalMs);
  connect(m_timer, &QTimer::timeout, this, &EngineArmorLogWatcher::poll);

  // 首次进比赛时日志可能还没建，所以不在这里打开，交给轮询自己发现。
  if (!m_directory.isEmpty() && QDir(m_directory).exists()) {
    m_timer->start();
  } else {
    // 目录还不存在时也保持轮询 —— 引擎可能在客户端之后才启动。
    m_timer->start();
  }
}

EngineArmorLogWatcher::~EngineArmorLogWatcher() { closeCurrent(); }

QString EngineArmorLogWatcher::defaultLogDirectory() {
  // 学生版引擎的固定布局：
  //   <root>/RoboMasterEngine_Data/StreamingAssets/RMServer/RMServerLogClient/
  //       RM裁判系统日志文件夹3.0/
  // 允许用 RM_ENGINE_ARMOR_LOG_DIR 覆盖，方便换机器或换引擎版本。
  const QString override =
      qEnvironmentVariable("RM_ENGINE_ARMOR_LOG_DIR").trimmed();
  if (!override.isEmpty()) {
    return override;
  }

  const QString appDir = QCoreApplication::applicationDirPath();

  // 从可执行文件所在目录向上找 RoboMasterEngine_Data
  QDir dir(appDir);
  for (int depth = 0; depth < 6; ++depth) {
    const QString candidate =
        dir.filePath(QStringLiteral(
            "RoboMasterEngine_Data/StreamingAssets/RMServer/RMServerLogClient/"
            "RM裁判系统日志文件夹3.0"));
    if (QDir(candidate).exists()) {
      return candidate;
    }
    if (!dir.cdUp()) {
      break;
    }
  }

  // 兜底：直接给出约定路径，存在与否交给轮询判断。
  return QString();
}

int EngineArmorLogWatcher::parseArmorIdFromLine(const QString &line) {
  const QRegularExpressionMatch match = armorHitPattern().match(line);
  if (!match.hasMatch()) {
    return -1;
  }
  bool ok = false;
  const int armorId = match.captured(1).toInt(&ok);
  if (!ok || armorId < 0 || armorId > 3) {
    return -1;
  }
  return armorId;
}

void EngineArmorLogWatcher::closeCurrent() {
  if (m_file) {
    m_file->close();
    delete m_file;
    m_file = nullptr;
  }
  m_filePath.clear();
  m_offset = 0;
  m_partialLine.clear();
}

bool EngineArmorLogWatcher::openNewest() {
  QDir dir(m_directory);
  if (!dir.exists()) {
    return false;
  }

  const QFileInfoList entries =
      dir.entryInfoList(QStringList() << QStringLiteral("*.csv"),
                        QDir::Files, QDir::Time);
  if (entries.isEmpty()) {
    return false;
  }

  const QFileInfo &newest = entries.first();
  // 引擎会滚动新文件；换文件时从 0 重新读，历史受击不需要回放。
  if (m_file && m_filePath == newest.absoluteFilePath()) {
    return true;
  }

  closeCurrent();
  m_file = new QFile(newest.absoluteFilePath());
  if (!m_file->open(QIODevice::ReadOnly | QIODevice::Text)) {
    delete m_file;
    m_file = nullptr;
    return false;
  }
  m_filePath = newest.absoluteFilePath();
  // 已经存在的老内容不回放，从当前末尾开始跟。
  m_offset = m_file->size();
  m_file->seek(m_offset);
  qWarning() << "[armor] following" << m_filePath;
  return true;
}

void EngineArmorLogWatcher::poll() {
  if (!openNewest()) {
    return;
  }

  const qint64 size = m_file->size();
  if (size < m_offset) {
    // 文件被截断（引擎重启/轮转），重新跟。
    closeCurrent();
    return;
  }
  if (size == m_offset) {
    return;
  }

  const qint64 toRead = qMin(size - m_offset, kMaxReadPerPoll);
  if (!m_file->seek(m_offset)) {
    closeCurrent();
    return;
  }
  const QByteArray chunk = m_file->read(toRead);
  m_offset += chunk.size();

  // 日志是 UTF-8；末尾可能是半行，留到下一次轮询。
  QString text = m_partialLine + QString::fromUtf8(chunk);
  const int lastNewline = text.lastIndexOf(QLatin1Char('\n'));
  if (lastNewline < 0) {
    m_partialLine = text;
    return;
  }
  m_partialLine = text.mid(lastNewline + 1);
  text.truncate(lastNewline);

  const QStringList lines = text.split(QLatin1Char('\n'), Qt::SkipEmptyParts);
  for (const QString &line : lines) {
    const int armorId = parseArmorIdFromLine(line);
    if (armorId < 0) {
      continue;
    }

    // 引擎的装甲编号：0=前 1=左 2=后 3=右。
    // GameData 的方向枚举：0=前 1=右 2=后 3=左 —— 1 和 3 需要对调。
    static const int kArmorToDirection[4] = {0, 3, 2, 1};
    const int direction = kArmorToDirection[armorId];

    if (m_gameData) {
      m_gameData->setHitDirection(direction);
    }
    qWarning() << "[armor] hit armor=" << armorId << "direction=" << direction;
  }
}
