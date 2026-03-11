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
2. **后期不足**：后代种子质量高，AFL还在快速发现新边时被强制停止
3. **预算浪费**：固定代数无法自适应填满总时间预算，若每代提前终止则大量预算闲置

最优同步方案应同时解决"每代跑多久"和"总共跑几代"两个问题，使时间预算利用率趋近100%。

### 2.2 算法概述

ASE分四个阶段运作：

- **Phase A（代间调度）**：基于剩余预算和历史数据，动态预测当前代的epoch时长
- **Phase B（代内监控）**：实时监控增长率，满足严格条件才提前终止或动态延长
- **Phase C（历史更新）**：记录本代结果，更新wall-clock累计
- **Phase D（动态代数决策）**：基于剩余预算决定是否继续下一代

### 2.3 参数定义

| 参数 | 符号 | 默认值 | 含义 |
|------|------|--------|------|
| 最短epoch | T_min | 1800s (30min) | 保证充分模糊测试的硬下限 |
| 最长epoch | T_max | 7200s (2h) | 防止单代独占预算 |
| 默认epoch | T_default | 3600s (1h) | 无历史时的首代时长 |
| 停滞容忍 | τ_stall | 300s (5min) | 连续无增长的容忍窗口 |
| 采样间隔 | δ | 30s | 覆盖率监控频率 |
| EWMA系数 | α | 0.2 | 增长率平滑因子（较慢，抗噪） |
| 饱和阈值 | β | 0.02 | 低于此视为饱和（更严格） |
| LLM提升系数 | γ | 0.15 | 进化后种子质量提升 |
| 时间预算 | T_budget | 86400s | 总实验时间(24h) |
| LLM时间估算 | T_llm | 2400s (40min) | 每代LLM+种子选择的估算时间 |
| 最大代数 | G_max | 20 | 硬上限保护 |

### 2.4 关键设计决策

1. **T_min 是硬下限**：任何epoch不可短于T_min，杜绝"级联缩短"问题
2. **动态估算剩余代数**：不用固定G均分预算，而是基于历史平均代价动态估算
3. **Early stop 需四重条件**：防止误判导致过早终止
4. **代数由预算驱动**：只要预算够一代（T_min + T_llm + 开销），就继续

### 2.5 Phase A：代间调度（动态预算分配）

```
// 动态估算剩余可跑代数
T_remain = T_budget − total_elapsed
IF History ≠ ∅:
    avg_wall = mean(wall_clock_total_j for j ∈ History)
ELSE:
    avg_wall = T_default + T_llm
avg_wall = max(avg_wall, T_min + T_llm × 0.5)
gens_left = max(⌊T_remain / avg_wall⌋, 1)
gens_left = min(gens_left, G_max − g)     // 受最大代数约束

// 公平分配fuzzing时间
T_llm_total = T_llm × gens_left
T_fuzz_remain = max(T_remain − T_llm_total, T_min × gens_left)
T_fair = T_fuzz_remain / gens_left

// 基于历史调整
IF History = ∅:
    T_g = max(T_default, T_fair)
ELSE:
    T_g = T_fair
    // 效率提升 → 适当加时
    IF recent_efficiency > avg_efficiency × 1.2:
        T_g = T_g × 1.15
    // LLM进化提升（后代种子更强）
    IF g > 0:
        T_g = T_g × (1 + γ × min(g / (gens_done + gens_left), 1))

T_g = clip(T_g, T_min, T_max)
```

**注意**：不再有级联缩短逻辑（`min(T, last.T × 1.2)` 已移除），避免early-stop导致后续代越来越短。

### 2.6 Phase B：代内实时监控

每δ秒从各容器采样覆盖率C_k(t)，计算：

```
ρ_max(t) = max_k (C_k(t) − C_k(t−δ)) / (C_k(t−δ) + ε)
ρ_bar(t) = α · ρ_max(t) + (1−α) · ρ_bar(t−δ)
```

同时跟踪峰值覆盖率和最后一次改进的时间：

```
IF total_cov(t) > peak_cov:
    peak_cov = total_cov(t)
    t_last_improve = t
```

**提前终止条件**（四重AND，全部满足才终止）：
```
IF  t ≥ T_min                              // 条件1: 过硬下限
AND t ≥ 0.6 × T_g                          // 条件2: 至少跑60%
AND ρ_bar(t) < β                            // 条件3: 增长率极低
AND (t − t_last_improve) ≥ τ_stall          // 条件4: 持续无改进
AND stall_count ≥ ⌈τ_stall / δ⌉:           // 条件5: 多周期确认
    STOP
```

**动态延长条件**（可多次延长）：
```
IF t ≥ 0.85 × T_g AND T_g < T_max:
    IF ρ_bar(t) > β OR any_pool_improved:
        T_g ← min(T_g + τ_stall, T_max)    // 还在产出, 延长
```

### 2.7 Phase C：历史更新

```
Δ_g = end_cov − start_cov
wall_clock_g = time_now − gen_start_time    // 实际wall-clock (含LLM+fuzz+开销)
total_elapsed += wall_clock_g               // 累加到全局
total_fuzz_time += actual_fuzz_time
History ← History ∪ {(g, Δ_g, actual_time, wall_clock_g, early_stopped?, extended?)}
```

### 2.8 Phase D：动态代数决策

每代结束后，判断是否还应启动下一代：

```
Function should_continue(current_gen, G_max):
    // 硬上限
    IF current_gen + 1 ≥ G_max: RETURN FALSE
    
    // 预算检查：至少需要一代的最小开销
    T_remain = T_budget − total_elapsed
    T_min_gen = T_min + T_llm + 300         // fuzz + LLM + 开销
    
    RETURN T_remain ≥ T_min_gen
```

### 2.9 完整伪代码

```
Algorithm ASE(T_budget, G_max):

  g ← 0; total_elapsed ← 0; History ← ∅

  WHILE should_continue(g − 1, G_max) OR g = 0:
    
    // Phase A: 预测初始时长
    gens_left ← estimate_remaining_gens(g, G_max)
    T_remain ← T_budget − total_elapsed
    T_fuzz_remain ← max(T_remain − T_llm × gens_left, T_min × gens_left)
    T_fair ← T_fuzz_remain / gens_left
    T_g ← adjust_with_history(T_fair, History)
    T_g ← clip(T_g, T_min, T_max)

    // Phase B: 实时监控
    Launch K containers with limit T_g
    t ← 0; stall ← 0; ρ_bar ← 1.0; peak_cov ← 0; t_improve ← 0
    WHILE t < T_g:
      sleep(δ); t ← t + δ
      Sample C_k(t) from each container k
      ρ_max ← max_k growth_rate(k)
      ρ_bar ← α·ρ_max + (1−α)·ρ_bar
      
      Update peak_cov, t_improve

      // Early stop: strict 4-way AND
      IF t ≥ T_min AND t ≥ 0.6·T_g AND ρ_bar < β
         AND (t − t_improve) ≥ τ_stall:
        stall ← stall + 1
        IF stall ≥ ⌈τ_stall/δ⌉: BREAK
      ELSE IF any_improved: stall ← 0

      // Dynamic extension (multiple allowed)
      IF t ≥ 0.85·T_g AND T_g < T_max AND (ρ_bar > β OR any_improved):
        T_g ← min(T_g + τ_stall, T_max)

    Stop all K containers

    // Phase C: 历史更新
    wall_clock_g ← LLM_time + actual_fuzz_time + overhead
    total_elapsed += wall_clock_g
    Record (g, Δ_g, actual_time, wall_clock_g, early_stopped?, extended?)
    
    g ← g + 1

    // Phase D: 动态代数决策
    // (loop condition checks should_continue)

  RETURN History
```

---

## 两个算法的协同

```
┌──────────────────────────────────────────────────────┐
│              GMPFuzz 主循环（动态代数）                 │
│                                                       │
│  g = 0                                               │
│  WHILE ASE.should_continue() OR g = 0:               │
│    ① ASE Phase A: 预测本代时长 T_g (时间维度)         │
│         ↓                                             │
│    ② PASD: 种子→协议区→并行池 (空间维度)              │
│         ↓                                             │
│    ③ 并行执行: K个AFL容器运行                         │
│       ASE Phase B: 实时监控→提前终止/动态延长          │
│         ↓                                             │
│    ④ ASE Phase C: 记录wall-clock，更新预算            │
│         ↓                                             │
│    ⑤ LLM进化: CodeLlama生成下一代变体                 │
│         ↓                                             │
│    ⑥ ASE Phase D: 剩余预算≥T_min+T_llm? →继续/结束   │
│         ↓                                             │
│    g ← g + 1                                         │
│  END WHILE                                            │
└──────────────────────────────────────────────────────┘
```

**PASD**解决"种子放到哪个池"（空间维度），**ASE**解决"每代跑多久"和"总共跑几代"（时间维度）。两者正交互补：PASD提高每个时间单位的覆盖效率，ASE根据效率动态调整时间分配——效率高的代获得更多时间，饱和的代尽早让位给LLM进化。代数不再固定，由预算驱动自适应决定，确保24小时预算利用率趋近100%。

### 实现文件

| 算法 | 实现文件 | 入口 |
|------|---------|------|
| PASD | `select_states_net.py` | `select_states_mqtt()` |
| ASE | `ase.py` | `ASEScheduler` class |
| ASE动态代数 | `ase.py` | `should_continue()` / CLI `should-continue` |
| ASE集成 | `getcov_fuzzbench_net.py` | `--ase-state` 参数 |
| 动态循环 | `all_gen_net.sh` | `while` + ASE should-continue |
| 配置 | `preset/mqtt/config.yaml` | `ase:` section, `run.max_generations` |
