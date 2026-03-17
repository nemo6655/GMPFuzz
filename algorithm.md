# GMPFuzz 核心算法

## 算法一：协议感知状态分配算法 (PASD)

### 1.1 动机

传统并行模糊测试将种子均匀分配到各并行池，忽略协议状态机的结构。MQTT协议有明确功能分区（连接握手、QoS 0/1/2发布、订阅管理、会话生命周期），盲目分配导致各池重复探索相同代码路径。

### 1.2 MQTT协议功能区定义

将每个种子解析为MQTT二进制报文序列，根据报文类型映射到6个功能区：

| 功能区 | 报文类型 | 含义 |
|--------|---------|------|
| SESSION | CONNECT, CONNACK | 连接握手、认证 |
| PUB_SIMPLE | SUBSCRIBE, SUBACK, UNSUBSCRIBE, QoS0 PUBLISH | 基础发布/订阅 |
| PUB_ACKED | PUBACK, QoS1 PUBLISH | QoS1确认发布 |
| PUB_ASSURED | PUBREC, PUBREL, PUBCOMP, QoS2 PUBLISH | QoS2四阶段握手 |
| LIFECYCLE | PINGREQ, PINGRESP, DISCONNECT | 会话生命周期 |
| EDGE_CASE | 畸形/未知报文 | 协议边界 |

### 1.3 区权重计算

对种子 s_i 中的报文序列，计算区权重：

```
w_i(z) = (|{m_j ∈ s_i : Z(m_j) = z}| + bonus(s_i, z)) / Σ_z'(...)
```

bonus规则：
- 种子无CONNECT开头 → EDGE_CASE +2
- 包含完整QoS2握手(PUBREC+PUBREL+PUBCOMP) → PUB_ASSURED +3

主功能区：`z*(s_i) = argmax_z w_i(z)`

### 1.4 复合评分

```
Score(s_i) = Σ_{t∈T(s_i)} 1/count(t)     // 稀有度
           + log2(1 + depth(s_i))          // 状态深度
           + 2 · 𝟙[QoS2_complete(s_i)]    // QoS2完整性
```

- T(s_i): 种子覆盖的状态转移集合
- count(t): 转移t在所有精英中出现的次数
- depth(s_i): 最长状态序列长度

### 1.5 池分配策略

| 池 | 分配 | 目标 |
|----|------|------|
| P0 | 全部精英种子（完整副本） | 基线全覆盖 |
| P1 | z* = SESSION | 聚焦连接/认证路径 |
| P2 | z* ∈ {PUB_SIMPLE, PUB_ACKED} | 聚焦发布/订阅+QoS1 |
| P3 | z* ∈ {PUB_ASSURED, LIFECYCLE} | 聚焦QoS2握手+生命周期 |

EDGE_CASE种子 → 当前种子最少的池（负载均衡）。

### 1.6 缺失转移拯救

```
T_miss = T_all \ T_elite
```

对每个缺失转移选最小种子，复制到所有池，避免丢失已探索路径。

### 1.7 再平衡

若任一池种子数 < ⌊|S|/|P| × 0.25⌋，从最大池移出评分最低种子补充，最多3轮。

### 1.8 伪代码

```
Algorithm PASD(S, P, C, E):
  // Step 1: 全精英 → P0
  Copy all S to P0

  // Step 2: 解析每个种子的MQTT区权重
  FOR s_i ∈ S:
    zones[s_i] ← parse_mqtt_zones(s_i.binary)
    z*[s_i] ← argmax(zones[s_i])
    score[s_i] ← rarity + depth_bonus + qos2_bonus

  // Step 3: 缺失转移拯救
  T_miss ← all_transitions(C) \ elite_transitions(E)
  rescue ← {smallest seed covering t : t ∈ T_miss}
  Copy rescue to ALL pools

  // Step 4: 区→池路由
  FOR s_i ∈ S:
    pool ← zone_pool_map[z*[s_i]]
    IF pool = NULL: pool ← argmin_p |bucket[p]|
    bucket[pool].add(s_i)

  // Step 5: 再平衡
  REPEAT 3 times:
    IF any pool < 25% of ideal size:
      Move lowest-score seeds from largest pool

  // Step 6: 按score降序排列（AFL按序处理）
  FOR each pool: sort by score DESC
```

---

## 算法二：自适应同步时间段算法 (ASE)

### 2.1 动机

固定时间段（T=1800s）和固定代数（G=5）存在三个问题：
1. **早期浪费**：初代种子质量低，AFL很快饱和，大量时间做无效变异
2. **后期不足**：后代种子质量高，覆盖的代码路径更复杂，AFL需要更多时间深入探索
3. **预算浪费**：固定代数无法自适应填满总时间预算，若每代提前终止则大量预算闲置

ASE的核心思想：**后代种子经过LLM进化，质量更高，需要更多fuzzing时间来充分挖掘其潜力**。因此每代的epoch应单调递增，保证每代至少比上一代多 $T_{increment}$ 时间。

### 2.2 算法概述

ASE分四个阶段运作：

- **Phase A（代间调度）**：基于三角数权重分配，保证后代获得更多时间，且严格单调递增
- **Phase B（代内监控）**：实时监控增长率，满足严格条件才提前终止或动态延长
- **Phase C（历史更新）**：记录本代结果（含predicted_epoch），更新预算消耗
- **Phase D（动态代数决策）**：基于剩余预算和单调递增约束决定是否继续下一代

### 2.3 参数定义

| 参数 | 符号 | 默认值 | 含义 |
|------|------|--------|------|
| 最短epoch | $T_{min}$ | 1800s (30min) | 保证充分模糊测试的硬下限 |
| 最长epoch | $T_{max}$ | 36000s (10h) | 防止单代独占预算的天花板 |
| 默认epoch | $T_{default}$ | 3600s (1h) | 无历史时的首代时长 |
| 最小增量 | $T_{increment}$ | 3600s (1h) | 每代至少比上一代多的时间 |
| 停滞容忍 | $\tau_{stall}$ | 300s (5min) | 连续无增长的容忍窗口 |
| 采样间隔 | $\delta$ | 30s | 覆盖率监控频率 |
| EWMA系数 | $\alpha$ | 0.2 | 增长率平滑因子（较慢，抗噪） |
| 饱和阈值 | $\beta$ | 0.02 | 低于此视为饱和 |
| 时间预算 | $T_{budget}$ | 86400s (24h) | 总实验fuzzing时间预算 |
| 最大代数 | $G_{max}$ | 20 | 硬上限保护 |

### 2.4 关键设计决策

1. **严格单调递增**：$T_g > T_{g-1}$，每代至少增加 $T_{increment}$（默认1小时），体现LLM进化后种子质量递增的核心假设
2. **三角数权重分配**：gen0权重1，gen1权重2，...，genN权重N+1，自然地给后代分配更多时间
3. **predicted_epoch回溯保护**：当early-stop导致 $actual\_time \ll predicted\_epoch$ 时，下一代的floor基于 $\max(actual, predicted)$，防止时间回退
4. **T_max天花板终止**：当 $prev\_max + T_{increment} > T_{max}$ 时，`should_continue()` 返回 False，避免连续代被卡在天花板
5. **预算仅计fuzzing时间**：LLM/种子选择时间不计入预算消耗，保证fuzzing时间精确可控

### 2.5 Phase A：代间调度（三角数权重 + 单调递增）

核心思想：用三角数权重使后代自然获得更多时间，同时强制每代至少比上一代多 $T_{increment}$。

#### 2.5.1 剩余代数估算

```
Function estimate_remaining_gens(g, G_max):
    T_remain = T_budget − total_elapsed
    
    // 确定下一代的基准时间
    IF History ≠ ∅:
        prev_max = max_{h ∈ History} max(h.actual_time, h.predicted_epoch)
        next_base = prev_max + T_increment
    ELSE:
        next_base = T_default
    next_base = max(next_base, T_min)
    
    // 贪心计算：递增序列能塞多少代
    // gen_k 需要 next_base + k × T_increment 秒
    gens_left = 0; cumulative = 0
    FOR k = 0, 1, 2, ...:
        t_gen = next_base + k × T_increment
        IF cumulative + t_gen > T_remain: BREAK
        cumulative += t_gen
        gens_left += 1
    
    gens_left = max(gens_left, 1)
    IF G_max > 0: gens_left = min(gens_left, G_max − g)
    RETURN gens_left
```

#### 2.5.2 epoch预测

```
Function predict_epoch(g, G_max):
    T_remain = T_budget − total_elapsed
    
    IF History = ∅:
        // 首代：使用默认值
        T = max(T_default, T_min)
    ELSE:
        // --- 单调递增保护 ---
        // 取历史最大epoch（防early-stop回退）
        prev_max = max_{h ∈ History} max(h.actual_time, h.predicted_epoch)
        T_floor = prev_max + T_increment    // 硬下限
        
        // --- 三角数权重分配 ---
        // gen0权重1, gen1权重2, ..., genN权重N+1
        gens_left = estimate_remaining_gens(g, G_max)
        current_weight = g + 1
        total_weight = Σ_{i=g+1}^{g+gens_left} i   // 三角数求和
        T_proportional = T_remain × (current_weight / total_weight)
        
        // 取三角分配与单调floor的较大值
        T = max(T_proportional, T_floor)
        
        // 效率加成：最近一代高效则加10%
        IF recent_efficiency > avg_efficiency × 1.2:
            T = T × 1.1
    
    // 最终裁剪
    T = clip(T, T_min, min(T_max, T_remain))
    
    // 安全兜底：即使裁剪后仍须满足单调递增
    IF History ≠ ∅ AND T < T_floor AND T_remain ≥ T_floor:
        T = min(T_floor, T_max, T_remain)
    
    RETURN T
```

**关键性质**：
- 三角数权重 $w_g = g+1$ 使得时间分配自然递增，无需显式"LLM提升系数"
- $T_{floor} = prev\_max + T_{increment}$ 保证即使三角分配不足，也有硬性增长
- $prev\_max$ 使用 $\max(actual, predicted)$，防止early-stop导致的时间回退

### 2.6 Phase B：代内实时监控

每 $\delta$ 秒从各容器采样覆盖率 $C_k(t)$，计算：

$$\rho_{max}(t) = \max_k \frac{C_k(t) - C_k(t-\delta)}{C_k(t-\delta) + \epsilon}$$

$$\bar{\rho}(t) = \alpha \cdot \rho_{max}(t) + (1-\alpha) \cdot \bar{\rho}(t-\delta)$$

同时跟踪峰值覆盖率和最后一次改进的时间：

```text
IF total_cov(t) > peak_cov:
    peak_cov = total_cov(t)
    t_last_improve = t
```

**提前终止条件**（五重AND，全部满足才终止）：

```text
IF  t ≥ T_min                              // 条件1: 过硬下限
AND t ≥ 0.6 × T_g                          // 条件2: 至少跑60%
AND ρ_bar(t) < β                            // 条件3: 增长率极低
AND (t − t_last_improve) ≥ τ_stall          // 条件4: 持续无改进
THEN:
    stall_count += 1
    IF stall_count ≥ ⌈τ_stall / δ⌉:        // 条件5: 多周期确认
        STOP
ELSE IF any_pool_improved:
    stall_count = 0                          // 有改进则重置
```

**动态延长条件**（可多次延长）：

```text
IF t ≥ 0.85 × T_g AND T_g < T_max:
    IF ρ_bar(t) > β OR any_pool_improved:
        extension = min(τ_stall, T_max − T_g)
        T_g ← T_g + extension               // 还在产出, 延长
```

### 2.7 Phase C：历史更新

```text
Δ_g = end_cov − start_cov
was_early = (actual_time < 0.95 × predicted_epoch)
was_extended = (extend_count > 0)

// 关键：保存 predicted_epoch 供后续代的单调floor使用
History ← History ∪ {(g, predicted_epoch, Δ_g, actual_time,
                       start_cov, end_cov, was_early, was_extended)}

// 预算仅计fuzzing时间（LLM时间不消耗预算）
total_elapsed += actual_time
total_fuzz_time += actual_time
```

### 2.8 Phase D：动态代数决策

每代结束后，判断是否还应启动下一代。需要同时检查三个条件：

```text
Function should_continue(current_gen, G_max):
    // 条件1: 硬代数上限
    IF current_gen + 1 ≥ G_max: RETURN FALSE
    
    // 条件2: T_max天花板检查
    // 如果下一代所需的最小epoch超过T_max，无法保证单调递增
    IF History ≠ ∅:
        prev_max = max_{h ∈ History} max(h.actual_time, h.predicted_epoch)
        IF prev_max + T_increment > T_max: RETURN FALSE
    
    // 条件3: 预算充足性
    T_remain = T_budget − total_elapsed
    IF History ≠ ∅:
        T_min_gen = prev_max + T_increment + 300   // 单调递增的最小cost
    ELSE:
        T_min_gen = T_min + 300
    
    RETURN T_remain ≥ T_min_gen
```

**T_max天花板终止**（条件2）的作用：当 $prev\_max + T_{increment} > T_{max}$ 时，即使预算充足也应停止，因为无法在 $T_{max}$ 限制下保证单调递增。这避免了连续多代被卡在 $T_{max}$（$\Delta = 0$）的无意义执行。

### 2.9 完整伪代码

```text
Algorithm ASE(T_budget, G_max, T_increment):

  g ← 0; total_elapsed ← 0; History ← ∅

  WHILE should_continue(g − 1, G_max) OR g = 0:
    
    // Phase A: 三角数权重 + 单调递增预测
    T_g ← predict_epoch(g, G_max)
    // 保证: T_g ≥ T_{g-1} + T_increment (如果 g > 0)
    // 保证: T_g ∈ [T_min, T_max]

    // Phase B: 实时监控
    Launch K containers with timeout T_g
    t ← 0; stall ← 0; ρ_bar ← 1.0; peak_cov ← 0; t_improve ← 0
    WHILE t < T_g:
      sleep(δ); t ← t + δ
      Sample C_k(t) from each container k
      ρ_max ← max_k growth_rate(k)
      ρ_bar ← α·ρ_max + (1−α)·ρ_bar
      Update peak_cov, t_improve

      // Early stop: strict 5-way AND
      IF t ≥ T_min AND t ≥ 0.6·T_g AND ρ_bar < β
         AND (t − t_improve) ≥ τ_stall:
        stall ← stall + 1
        IF stall ≥ ⌈τ_stall/δ⌉: BREAK
      ELSE IF any_improved: stall ← 0

      // Dynamic extension (multiple times OK)
      IF t ≥ 0.85·T_g AND T_g < T_max:
        IF ρ_bar > β OR any_improved:
          T_g ← T_g + min(τ_stall, T_max − T_g)

      // Hard ceiling
      IF t ≥ T_max: BREAK

    Graceful-stop all K containers

    // Phase C: 历史更新（保存 predicted_epoch）
    total_elapsed += actual_fuzz_time    // 仅计fuzzing时间
    Record (g, predicted_epoch=T_g, actual_time, Δ_cov, ...)
    
    g ← g + 1

    // Phase D: should_continue 检查
    //   - G_max 硬上限
    //   - T_max 天花板: prev_max + T_increment > T_max → STOP
    //   - 预算充足: T_remain ≥ next_min_epoch + 300

  RETURN History
```

### 2.10 数值示例

以 $T_{budget}=86400s$, $T_{default}=3600s$, $T_{increment}=3600s$, $T_{max}=36000s$ 为例：

| 代 | 权重 | predict_epoch | 实际时间(95%) | Δ(vs上一代) | 累计消耗 |
|----|------|---------------|--------------|-------------|---------|
| gen0 | 1 | 3600s (1h) | 3420s | — | 3420s |
| gen1 | 2 | 7200s (2h) | 6840s | +3420s ✓ | 10260s |
| gen2 | 3 | 10800s (3h) | 10260s | +3420s ✓ | 20520s |
| gen3 | 4 | 14400s (4h) | 13680s | +3420s ✓ | 34200s |
| gen4 | 5 | 18000s (5h) | 17100s | +3420s ✓ | 51300s |
| gen5 | 6 | 21600s (6h) | — | should_continue→FALSE | — |

注：gen5 时 $prev\_max(18000) + T_{increment}(3600) = 21600 < T_{max}(36000)$ 且 $T_{remain}=35100 \ge 21900$，但实际能否继续取决于剩余预算。此例中 gen5 的 predicted_epoch=21600 需要 21900s（含300s开销），$35100 \ge 21900$，gen5 可执行。gen6 需 25200+300=25500，$35100-21600=13500 < 25500$，预算不足，终止。

---

## 两个算法的协同

```text
┌──────────────────────────────────────────────────────────┐
│               GMPFuzz 主循环（动态代数）                    │
│                                                           │
│  g = 0                                                   │
│  WHILE ASE.should_continue() OR g = 0:                   │
│    ① ASE Phase A: 三角数权重 + 单调递增 → T_g (时间维度)  │
│         ↓                                                 │
│    ② PASD: 种子→MQTT协议区→并行池 (空间维度)              │
│         ↓                                                 │
│    ③ 并行执行: K个AFL容器运行 (timeout T_g)               │
│       ASE Phase B: 实时监控→提前终止/动态延长              │
│         ↓                                                 │
│    ④ ASE Phase C: 记录 (predicted_epoch, actual_time)     │
│       total_elapsed += actual_fuzz_time (仅计fuzzing)     │
│         ↓                                                 │
│    ⑤ LLM进化: CodeLlama生成下一代变体 (不计入预算)        │
│         ↓                                                 │
│    ⑥ ASE Phase D: 三重检查 →继续/结束                     │
│       - G_max硬上限                                       │
│       - T_max天花板 (prev_max + T_inc > T_max → STOP)    │
│       - 预算充足性 (T_remain ≥ next_min + 300)           │
│         ↓                                                 │
│    g ← g + 1                                             │
│  END WHILE                                                │
└──────────────────────────────────────────────────────────┘
```

**PASD**解决"种子放到哪个池"（空间维度），**ASE**解决"每代跑多久"和"总共跑几代"（时间维度）。两者正交互补：

- PASD提高每个时间单位的覆盖效率（按MQTT功能区分池，避免重复探索）
- ASE根据LLM进化代数递增分配时间——后代种子质量更高，获得更多fuzzing时间
- 效率高的代可动态延长，饱和的代可提前终止，但下一代的floor不受early-stop影响
- 代数不再固定，由预算 + $T_{max}$ 天花板 + 单调递增约束三者共同决定

### 实现文件

| 算法 | 实现文件 | 入口 |
| ------ | --------- | ------ |
| PASD | `select_states_net.py` | `select_states_mqtt()` |
| ASE | `ase.py` | `ASEScheduler` class |
| ASE动态代数 | `ase.py` | `should_continue()` / CLI `should-continue` |
| ASE集成 | `getcov_fuzzbench_net.py` | `--ase-state` 参数 |
| 动态循环 | `all_gen_net.sh` | `while` + ASE should-continue |
| 配置 | `preset/*/config.yaml` | `ase:` section |

