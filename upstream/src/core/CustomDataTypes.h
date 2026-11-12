/**
 * @file CustomDataTypes.h
 * @brief 自定义数据结构定义 (用于 CustomByteBlock 协议)
 * @details 机器人端和客户端共享的数据结构定义
 */

#ifndef CUSTOM_DATA_TYPES_H
#define CUSTOM_DATA_TYPES_H

#include <cstdint>

#pragma pack(push, 1)

/// 电控状态包魔数（固定放在 Byte 0）。
/// 同一个 CustomByteBlock 通道还跑 H.264 视频分片（约 300 字节、以 0x0A 开头），
/// 客户端用这个字节把状态包与视频分片区分开，不再靠长度猜测。
/// 特意不用 0xA5，避免与裁判系统串口帧头混淆。
static constexpr uint8_t kRobotCustomStatusMagic = 0x5A;

/// 电控状态包版本（Byte 1）。将来同一通道承载其他数据时，用该字节区分类型。
static constexpr uint8_t kRobotCustomStatusVersion = 1;

/// v2：应用负载 11 -> 12 字节，新增 Byte 11 module_status（E5 模块状态位）。
/// 对接文档：docs/real_vehicle_integration/电控组E5模块状态对接文档.md
static constexpr uint8_t kRobotCustomStatusVersionV2 = 2;

/**
 * @struct RobotCustomStatus
 * @brief 机器人自定义状态数据结构
 * @details v1 共 11 字节、v2 共 12 字节，经图传链路 0x0310 → 官方选手端 MQTT CustomByteBlock 传输。
 *          对接文档：docs/real_vehicle_integration/电控组最小数据对接文档.md 第 5 节
 *
 * 数据布局（有效数据连续，无保留字节）:
 * - Byte 0:    magic = 0x5A
 * - Byte 1:    version = 1
 * - Byte 2:    机构与状态位
 * - Byte 3:    底盘模式位
 * - Byte 4-5:  云台相对底盘偏角 (int16, 0.0001 rad)
 * - Byte 6-7:  云台世界正方向角 (int16, 0.0001 rad)
 * - Byte 8-9:  炮管俯仰角     (int16, 0.0001 rad)
 * - Byte 10:   包序号
 */
struct RobotCustomStatus {
    // ========== Byte 0-1: 魔数与版本 ==========
    uint8_t magic;    // 固定 0x5A，用于与同通道的视频分片区分
    uint8_t version;  // 本版 = 1

    // ========== Byte 2: 机构与状态位 ==========
    union {
        struct {
            uint8_t fric_enabled : 1;      // bit0 摩擦轮已就绪
            uint8_t rammer_enabled : 1;    // bit1 拨弹轮正在动作
            uint8_t fire_permitted : 1;    // bit2 当前允许发射
            uint8_t auto_lob_active : 1;   // bit3 自动吊射实际启用
            uint8_t electrical_fault : 1;  // bit4 电控检测到故障
            uint8_t pose_valid : 1;        // bit5 底盘角与云台角可信
            uint8_t pitch_valid : 1;       // bit6 俯仰角可信
            uint8_t reserve1 : 1;          // bit7 保留
        } bits;
        uint8_t byte;
    } friction_status;

    // ========== Byte 3: 底盘模式 ==========
    // 原 spin_mode / follow_mode / chassis_protect 三个冗余位已删除：
    // 三者都能由 chassis_mode 推出，客户端本地推导，线上只传 mode。
    union {
        struct {
            uint8_t chassis_mode : 3;      // 底盘模式: 0=正常 1=跟随 2=小陀螺 3=保护
            uint8_t chassis_warning : 1;   // 底盘警告（超功率等）
            uint8_t reserve2 : 4;          // 保留
        } bits;
        uint8_t byte;
    } chassis_status;

    // ========== Byte 4-5: 云台相对底盘偏角 ==========
    // 精度: 0.0001 rad, 范围约 -31416~31416 (代表 -pi~pi)
    int16_t gimbal_chassis_angle;

    // ========== Byte 6-7: 云台世界正方向角 ==========
    // 精度: 0.0001 rad，云台相对世界正方向，逆时针为正；
    // 底盘正方向角由客户端本地推导：chassis_yaw = gimbal_yaw - gimbal_offset_yaw
    int16_t gimbal_yaw;

    // ========== Byte 8-9: 炮管俯仰角 ==========
    // 精度: 0.0001 rad，水平为 0，抬炮为正
    int16_t barrel_pitch;

    // ========== Byte 10: 包序号 ==========
    // 每发一个新状态包加一，255 回绕；客户端按它去重并判断新鲜度
    uint8_t seq;

    // ========== Byte 11: 模块状态位（仅 v2） ==========
    // bit0 底盘上电  bit1 云台上电  bit2 发射机构电源  bit3 RFID 读卡  bit4 遥控器在线
    union {
        struct {
            uint8_t chassis_powered : 1;
            uint8_t gimbal_powered : 1;
            uint8_t shooter_powered : 1;
            uint8_t rfid_card : 1;   // 0x0209 任一增益点检测到卡
            uint8_t rc_online : 1;   // 100 ms 内收到过遥控帧
            uint8_t reserve3 : 3;
        } bits;
        uint8_t byte;
    } module_status;

    // 默认构造函数
    RobotCustomStatus() {
        magic = kRobotCustomStatusMagic;
        version = kRobotCustomStatusVersion;
        friction_status.byte = 0;
        chassis_status.byte = 0;
        gimbal_chassis_angle = 0;
        gimbal_yaw = 0;
        barrel_pitch = 0;
        seq = 0;
        module_status.byte = 0;
    }
};

#pragma pack(pop)

// 确保结构体大小正确（v1 包缺的 Byte 11 在解析时保持 0）
static_assert(sizeof(RobotCustomStatus) == 12,
              "RobotCustomStatus size must be 12 bytes (v2)");

/**
 * @struct RobotMiniStateV1
 * @brief 0x0301 机器人最小状态摘要 (20B, 用于 TeamTelemetry 汇聚)
 */
struct RobotMiniStateV1 {
    uint8_t magic = 0xAA;
    uint8_t version = 1;
    uint8_t robotId = 0;
    uint8_t seq = 0;
    uint16_t timestampLow = 0;
    uint8_t flags = 0;
    uint8_t targetId = 0;
    uint8_t visionState = 0;
    uint8_t confidence = 0;
    uint8_t heatRatio = 0;
    uint8_t ammoRatio = 0;
    uint8_t capRatio = 0;
    uint8_t underFireLevel = 0;
    uint16_t faultFlags = 0;
    uint8_t crc8 = 0;
};

/// 0x0310 TeamTelemetry 汇聚协议头
struct TeamTelemetryHeader {
    uint8_t magic = 0xBB;
    uint8_t version = 1;
    uint8_t robotCount = 0;
    uint8_t seq = 0;
    uint16_t timestampLow = 0;
    int8_t rssi = 0;
    uint8_t crc8 = 0;
};

// 底盘模式枚举
enum class ChassisMode : uint8_t {
    NORMAL = 0,   // 正常模式
    FOLLOW = 1,   // 跟随模式
    SPIN = 2,     // 小陀螺模式
    PROTECT = 3   // 保护模式
};

#endif // CUSTOM_DATA_TYPES_H
