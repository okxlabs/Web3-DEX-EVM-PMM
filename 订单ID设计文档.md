# PMM 协议订单 ID 设计文档

## 1. 概述

本文档详细说明了 PMM 协议中订单 ID 的编码规则、合约存储机制以及后端系统的组织策略。设计目标是在保证唯一性的同时，提供高效的存储和查询性能。

## 2. 合约层面的存储机制

### 2.1 订单信息编码结构

在 `OrderRFQ` 结构体中，订单信息被编码在 `info` 字段（uint256）中：

```solidity
struct OrderRFQ {
    uint256 info; // 编码：低64位=订单ID，次高64位=过期时间戳
    address makerAsset;
    address takerAsset;
    address maker;
    address allowedSender;
    uint256 makingAmount;
    uint256 takingAmount;
    address settler;
    address treasury;
}
```

### 2.2 info 字段位域分配

```
|-------- 192 bits --------||------- 64 bits -------||------- 64 bits -------|
|       未使用 (保留)        ||      过期时间戳        ||      订单 ID         |
|         (高位)           ||      (次高64位)        ||       (低64位)       |
|     bits 128-255        ||     bits 64-127       ||      bits 0-63      |
```

**字段说明：**
- **低64位 (0-63)**：订单 ID，范围 0 到 2^64-1
- **次高64位 (64-127)**：过期时间戳，Unix 时间戳，0表示永不过期
- **高192位 (128-255)**：保留字段，用于未来扩展

### 2.3 位图存储机制

合约使用位图机制高效管理订单状态：

```solidity
// 存储结构
mapping(address => mapping(uint256 => uint256)) private _invalidator;

// 位图计算逻辑
function _invalidateOrder(address maker, uint256 orderInfo, uint256 additionalMask) private {
    uint64 orderId = uint64(orderInfo);                    // 提取订单ID
    uint256 invalidatorSlot = orderId >> 8;                // 高56位作为槽位号
    uint256 invalidatorBits = (1 << (orderId & 0xFF));     // 低8位作为位位置
    
    mapping(uint256 => uint256) storage invalidatorStorage = _invalidator[maker];
    uint256 invalidator = invalidatorStorage[invalidatorSlot];
    
    // 检查订单是否已被取消
    if (invalidator & invalidatorBits == invalidatorBits) {
        revert Errors.RFQ_InvalidatedOrder();
    }
    
    // 标记订单为已取消
    invalidatorStorage[invalidatorSlot] = invalidator | invalidatorBits;
}
```

**位图机制详解：**
- 每个槽位（slot）可以存储 256 个订单的状态
- 槽位号 = 订单ID >> 8（订单ID的高56位）
- 位位置 = 订单ID & 0xFF（订单ID的低8位）
- 每个位代表一个订单的取消状态（0=活跃，1=已取消）

### 2.4 槽位与订单ID的映射关系

| 槽位号 | 订单ID范围 | 十六进制范围 |
|--------|-----------|-------------|
| 0 | 0 - 255 | 0x00 - 0xFF |
| 1 | 256 - 511 | 0x100 - 0x1FF |
| 2 | 512 - 767 | 0x200 - 0x2FF |
| N | N×256 - (N×256+255) | N×0x100 - (N×0x100+0xFF) |

## 3. 后端订单ID组织策略

### 3.1 设计原则

1. **用户隔离**：为每个用户分配独立的槽位范围，避免冲突
2. **批量分配**：一次性分配多个订单ID，提高效率
3. **位图优化**：使用高效的位操作，快速查找可用ID
4. **可扩展性**：支持大量用户和订单
5. **性能优化**：缓存热点数据，减少数据库访问

### 3.2 用户隔离分配策略

#### 3.2.1 策略描述

为每个用户分配固定数量的连续槽位，确保不同用户的订单ID不会产生冲突。

```javascript
class UserIsolatedOrderIdManager {
    constructor() {
        this.SLOTS_PER_USER = 100;           // 每个用户分配100个槽位
        this.ORDERS_PER_SLOT = 256;          // 每个槽位256个订单ID
        this.userSlotMap = new Map();        // 用户地址 -> 槽位信息
        this.globalSlotCounter = 0;          // 全局槽位计数器
    }

    // 为用户分配槽位范围
    assignUserSlotRange(userAddress) {
        if (!this.userSlotMap.has(userAddress)) {
            const startSlot = this.globalSlotCounter;
            const endSlot = startSlot + this.SLOTS_PER_USER - 1;
            
            this.userSlotMap.set(userAddress, {
                startSlot: startSlot,
                endSlot: endSlot,
                currentSlot: startSlot,
                slotBitmaps: new Map(),  // 槽位号 -> 位图
                allocatedCount: 0
            });
            
            this.globalSlotCounter += this.SLOTS_PER_USER;
        }
        return this.userSlotMap.get(userAddress);
    }

    // 生成订单ID
    generateOrderId(userAddress) {
        const userRange = this.assignUserSlotRange(userAddress);
        
        // 查找可用的槽位和位位置
        for (let slot = userRange.startSlot; slot <= userRange.endSlot; slot++) {
            if (!userRange.slotBitmaps.has(slot)) {
                userRange.slotBitmaps.set(slot, 0n); // 初始化位图
            }
            
            const bitmap = userRange.slotBitmaps.get(slot);
            
            // 查找第一个可用位
            for (let bit = 0; bit < this.ORDERS_PER_SLOT; bit++) {
                const bitMask = 1n << BigInt(bit);
                if ((bitmap & bitMask) === 0n) {
                    // 标记为已使用
                    userRange.slotBitmaps.set(slot, bitmap | bitMask);
                    userRange.allocatedCount++;
                    
                    // 计算订单ID
                    const orderId = slot * this.ORDERS_PER_SLOT + bit;
                    return orderId;
                }
            }
        }
        
        throw new Error(`用户 ${userAddress} 的槽位已满`);
    }

    // 释放订单ID
    releaseOrderId(userAddress, orderId) {
        const userRange = this.userSlotMap.get(userAddress);
        if (!userRange) {
            throw new Error('用户未找到');
        }
        
        const slot = Math.floor(orderId / this.ORDERS_PER_SLOT);
        const bit = orderId % this.ORDERS_PER_SLOT;
        
        // 验证槽位属于该用户
        if (slot < userRange.startSlot || slot > userRange.endSlot) {
            throw new Error('订单ID不属于该用户');
        }
        
        const bitmap = userRange.slotBitmaps.get(slot) || 0n;
        const bitMask = 1n << BigInt(bit);
        
        // 清除对应位
        userRange.slotBitmaps.set(slot, bitmap & ~bitMask);
        userRange.allocatedCount--;
    }
}
```

#### 3.2.2 用户分配示例

```javascript
// 用户分配示例
const manager = new UserIsolatedOrderIdManager();

// 用户A: 0x1234...
const userA = "0x1234567890123456789012345678901234567890";
const userARange = manager.assignUserSlotRange(userA);
// 分配结果: 槽位 0-99, 订单ID范围 0-25599

// 用户B: 0x5678...
const userB = "0x5678901234567890123456789012345678901234";
const userBRange = manager.assignUserSlotRange(userB);
// 分配结果: 槽位 100-199, 订单ID范围 25600-51199

// 生成订单ID
const orderIdA1 = manager.generateOrderId(userA); // 可能返回 0
const orderIdA2 = manager.generateOrderId(userA); // 可能返回 1
const orderIdB1 = manager.generateOrderId(userB); // 可能返回 25600
```

### 3.3 批量预分配策略

#### 3.3.1 策略描述

为了提高性能，可以批量预分配订单ID，减少实时计算的开销。

```javascript
class BatchPreallocationManager {
    constructor() {
        this.preallocationPool = new Map(); // 用户地址 -> 预分配池
        this.poolSize = 1000;                // 预分配池大小
        this.refillThreshold = 100;          // 补充阈值
    }

    // 预分配订单ID池
    async preallocateOrderIds(userAddress, count = this.poolSize) {
        const orderIds = [];
        const baseManager = new UserIsolatedOrderIdManager();
        
        for (let i = 0; i < count; i++) {
            try {
                const orderId = baseManager.generateOrderId(userAddress);
                orderIds.push(orderId);
            } catch (error) {
                console.warn(`为用户 ${userAddress} 预分配订单ID失败:`, error);
                break;
            }
        }
        
        this.preallocationPool.set(userAddress, orderIds);
        return orderIds;
    }

    // 获取订单ID
    async getOrderId(userAddress) {
        if (!this.preallocationPool.has(userAddress)) {
            await this.preallocateOrderIds(userAddress);
        }
        
        const pool = this.preallocationPool.get(userAddress);
        
        if (pool.length === 0) {
            throw new Error(`用户 ${userAddress} 的订单ID池已耗尽`);
        }
        
        const orderId = pool.shift();
        
        // 检查是否需要补充池子
        if (pool.length <= this.refillThreshold) {
            // 异步补充，不阻塞当前请求
            this.preallocateOrderIds(userAddress, this.poolSize).catch(console.error);
        }
        
        return orderId;
    }

    // 返还未使用的订单ID
    returnOrderId(userAddress, orderId) {
        if (!this.preallocationPool.has(userAddress)) {
            this.preallocationPool.set(userAddress, []);
        }
        
        this.preallocationPool.get(userAddress).unshift(orderId);
    }
}
```

### 3.4 数据库设计

#### 3.4.1 槽位分配表

```sql
CREATE TABLE user_slot_allocation (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    user_address VARCHAR(42) NOT NULL COMMENT '用户地址',
    start_slot INT NOT NULL COMMENT '起始槽位号',
    end_slot INT NOT NULL COMMENT '结束槽位号',
    slot_count INT NOT NULL COMMENT '分配的槽位数量',
    allocated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT '分配时间',
    
    UNIQUE KEY uk_user_address (user_address),
    INDEX idx_slot_range (start_slot, end_slot)
) COMMENT='用户槽位分配表';
```

#### 3.4.2 槽位使用情况表

```sql
CREATE TABLE slot_usage (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    user_address VARCHAR(42) NOT NULL COMMENT '用户地址',
    slot_number INT NOT NULL COMMENT '槽位号',
    bitmap VARCHAR(64) NOT NULL DEFAULT '0' COMMENT '位图状态(十六进制)',
    used_count INT NOT NULL DEFAULT 0 COMMENT '已使用位数',
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    
    UNIQUE KEY uk_user_slot (user_address, slot_number),
    INDEX idx_user_address (user_address),
    INDEX idx_slot_number (slot_number)
) COMMENT='槽位使用情况表';
```

#### 3.4.3 订单ID索引表

```sql
CREATE TABLE order_id_index (
    order_id BIGINT NOT NULL PRIMARY KEY COMMENT '订单ID',
    user_address VARCHAR(42) NOT NULL COMMENT '用户地址',
    slot_number INT NOT NULL COMMENT '槽位号',
    bit_position TINYINT NOT NULL COMMENT '位位置(0-255)',
    status ENUM('allocated', 'used', 'cancelled', 'expired') DEFAULT 'allocated' COMMENT '状态',
    allocated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP COMMENT '分配时间',
    used_at TIMESTAMP NULL COMMENT '使用时间',
    
    INDEX idx_user_address (user_address),
    INDEX idx_slot_number (slot_number),
    INDEX idx_status (status),
    INDEX idx_allocated_at (allocated_at)
) COMMENT='订单ID索引表';
```

### 3.5 性能优化策略

#### 3.5.1 缓存策略

```javascript
class CachedOrderIdManager {
    constructor() {
        this.redis = new Redis(); // Redis客户端
        this.localCache = new Map(); // 本地缓存
        this.cacheTimeout = 300; // 缓存过期时间（秒）
    }

    // 缓存用户槽位信息
    async cacheUserSlots(userAddress, slotInfo) {
        const key = `user_slots:${userAddress}`;
        await this.redis.setex(key, this.cacheTimeout, JSON.stringify(slotInfo));
        this.localCache.set(key, slotInfo);
    }

    // 获取用户槽位信息
    async getUserSlots(userAddress) {
        const key = `user_slots:${userAddress}`;
        
        // 优先从本地缓存获取
        if (this.localCache.has(key)) {
            return this.localCache.get(key);
        }
        
        // 从Redis获取
        const cached = await this.redis.get(key);
        if (cached) {
            const slotInfo = JSON.parse(cached);
            this.localCache.set(key, slotInfo);
            return slotInfo;
        }
        
        // 从数据库加载
        const slotInfo = await this.loadUserSlotsFromDB(userAddress);
        await this.cacheUserSlots(userAddress, slotInfo);
        return slotInfo;
    }

    // 从数据库加载用户槽位信息
    async loadUserSlotsFromDB(userAddress) {
        // 数据库查询逻辑
        const allocation = await db.query(
            'SELECT * FROM user_slot_allocation WHERE user_address = ?',
            [userAddress]
        );
        
        const usage = await db.query(
            'SELECT * FROM slot_usage WHERE user_address = ?',
            [userAddress]
        );
        
        return {
            allocation: allocation[0],
            usage: usage
        };
    }
}
```

#### 3.5.2 监控和统计

```javascript
class OrderIdMonitor {
    constructor() {
        this.metrics = {
            totalAllocated: 0,       // 总分配数
            totalUsed: 0,           // 总使用数
            totalReleased: 0,       // 总释放数
            userStats: new Map(),   // 用户统计
            slotStats: new Map(),   // 槽位统计
            performanceStats: {     // 性能统计
                avgGenerateTime: 0,
                maxGenerateTime: 0,
                totalRequests: 0
            }
        };
    }

    // 记录订单ID分配
    recordAllocation(userAddress, orderId, slot, bit, generateTime) {
        this.metrics.totalAllocated++;
        
        // 更新用户统计
        if (!this.metrics.userStats.has(userAddress)) {
            this.metrics.userStats.set(userAddress, {
                allocated: 0,
                used: 0,
                released: 0
            });
        }
        this.metrics.userStats.get(userAddress).allocated++;
        
        // 更新槽位统计
        if (!this.metrics.slotStats.has(slot)) {
            this.metrics.slotStats.set(slot, {
                allocated: 0,
                utilization: 0
            });
        }
        const slotStat = this.metrics.slotStats.get(slot);
        slotStat.allocated++;
        slotStat.utilization = (slotStat.allocated / 256 * 100).toFixed(2);
        
        // 更新性能统计
        this.updatePerformanceStats(generateTime);
    }

    // 更新性能统计
    updatePerformanceStats(generateTime) {
        const perf = this.metrics.performanceStats;
        perf.totalRequests++;
        perf.maxGenerateTime = Math.max(perf.maxGenerateTime, generateTime);
        perf.avgGenerateTime = (perf.avgGenerateTime * (perf.totalRequests - 1) + generateTime) / perf.totalRequests;
    }

    // 生成监控报告
    generateReport() {
        return {
            summary: {
                totalAllocated: this.metrics.totalAllocated,
                totalUsed: this.metrics.totalUsed,
                totalReleased: this.metrics.totalReleased,
                activeOrders: this.metrics.totalAllocated - this.metrics.totalUsed - this.metrics.totalReleased
            },
            performance: this.metrics.performanceStats,
            topUsers: Array.from(this.metrics.userStats.entries())
                .sort((a, b) => b[1].allocated - a[1].allocated)
                .slice(0, 10),
            slotUtilization: Array.from(this.metrics.slotStats.entries())
                .map(([slot, stats]) => ({
                    slot: slot,
                    allocated: stats.allocated,
                    utilization: stats.utilization + '%'
                }))
                .sort((a, b) => b.allocated - a.allocated)
                .slice(0, 20)
        };
    }
}
```

## 4. 实施建议

### 4.1 阶段性部署

1. **第一阶段**：实现基本的用户隔离分配策略
2. **第二阶段**：添加批量预分配和缓存优化
3. **第三阶段**：完善监控统计和性能调优

### 4.2 运维要点

1. **容量规划**：根据用户增长预估槽位需求
2. **性能监控**：实时监控分配效率和槽位利用率
3. **数据备份**：定期备份槽位分配和使用情况
4. **故障恢复**：设计完善的故障恢复机制

### 4.3 注意事项

1. **唯一性保证**：确保同一用户的订单ID在其槽位范围内唯一
2. **并发控制**：处理多线程并发访问的竞争条件
3. **数据一致性**：保证缓存和数据库数据的一致性
4. **扩容策略**：当用户槽位不足时的扩容方案

## 5. 总结

本设计通过分析合约的位图存储机制，提出了适合后端系统的订单ID组织策略。主要特点包括：

- **完美适配**：与合约位图机制无缝对接
- **用户隔离**：避免不同用户间的ID冲突
- **高性能**：批量分配和缓存优化
- **可扩展**：支持大规模用户和订单
- **可监控**：完善的统计和监控机制

该方案能够有效支撑 PMM 协议的订单管理需求，确保系统的稳定性和高性能。 