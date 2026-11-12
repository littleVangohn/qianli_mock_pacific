#include "HeroVideoWidget.h"

#include <QPainter>
#include <QPainterPath>
#include <QPen>

namespace RM {

HeroVideoWidget::HeroVideoWidget(QWidget *parent) : QWidget(parent) {
  setAttribute(Qt::WA_TranslucentBackground);
  setAttribute(Qt::WA_NoSystemBackground);
  hide();
}

void HeroVideoWidget::setFrame(const QImage &frame) {
  m_frame = frame;
  updateEffectiveVisibility();
  update();
}

void HeroVideoWidget::setCurrentRobotId(int robotId) {
  if (m_currentRobotId == robotId) {
    return;
  }

  m_currentRobotId = robotId;
  updateEffectiveVisibility();
}

void HeroVideoWidget::setForceVisible(bool forceVisible) {
  if (m_forceVisible == forceVisible) {
    return;
  }

  m_forceVisible = forceVisible;
  updateEffectiveVisibility();
}

void HeroVideoWidget::paintEvent(QPaintEvent *event) {
  Q_UNUSED(event);

  if (m_frame.isNull()) {
    return;
  }

  QPainter painter(this);
  painter.setRenderHint(QPainter::Antialiasing, true);
  painter.setRenderHint(QPainter::SmoothPixmapTransform, true);

  QRectF contentRect = rect();
  contentRect.adjust(0.5, 0.5, -0.5, -0.5);

  QPainterPath clipPath;
  clipPath.addRoundedRect(contentRect, 4.0, 4.0);
  painter.setClipPath(clipPath);

  const QSize frameSize = m_frame.size();
  const QSizeF targetSize = contentRect.size();
  const qreal scale = qMax(targetSize.width() / qMax(1, frameSize.width()),
                           targetSize.height() / qMax(1, frameSize.height()));
  const QSizeF scaledSize(frameSize.width() * scale, frameSize.height() * scale);
  const QPointF topLeft((targetSize.width() - scaledSize.width()) / 2.0,
                        (targetSize.height() - scaledSize.height()) / 2.0);
  const QRectF targetRect(contentRect.topLeft() + topLeft, scaledSize);

  painter.drawImage(targetRect, m_frame);

  painter.setClipping(false);
  painter.setPen(QPen(QColor(QStringLiteral("#ffffff")), 1.0));
  painter.drawRoundedRect(contentRect, 4.0, 4.0);
}

void HeroVideoWidget::updateEffectiveVisibility() {
  // 只由 forceVisible 驱动。
  //
  // 这里原本还有一条"有帧 && 自己是英雄/哨兵就自动显示"的规则。那条规则成立的
  // 前提是 heroFrame 只承载英雄吊射/工业相机这类独立画面；主图传接进 heroFrame
  // 之后，英雄车一上线主界面就会凭空多出一块和背景重复的画面（还带白边）。
  // 取帧管线保持不动 —— setFrame() 照常缓存，将来做辅助瞄准/吊射时
  // 调 setForceVisible(true) 即可，不需要恢复自动显示。
  const bool effectiveVisible = m_forceVisible;

  if (effectiveVisible != m_lastEffectiveVisible) {
    m_lastEffectiveVisible = effectiveVisible;
    emit visibilityChanged(effectiveVisible);
  }

  setVisible(effectiveVisible);
}

} // namespace RM
