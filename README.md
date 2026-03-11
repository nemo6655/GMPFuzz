# GMPFuzz - Parallel Grey-box Fuzzing for MQTT Protocol

GMPFuzz (Greybox MQTT Protocol Fuzzer) implements parallel grey-box fuzzing for the MQTT protocol using evolutionary seed generation with LLM-based mutations. It is built following the architecture of [TDPFuzz](https://github.com/...) and uses [AFLNet](https://github.com/aflnet/aflnet) as the underlying network protocol fuzzer, targeting [Mosquitto](https://github.com/eclipse/mosquitto) MQTT broker.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        GMPFuzz Pipeline                         │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1. Initial Seeds (.raw)                                        │
│       │                                                         │
│       ▼                                                         │
│  2. seed_gen_mqtt.py: Convert raw MQTT → Python generators      │
│       │                                                         │
│       ▼                                                         │
│  3. genvariants_parallel_net.py: LLM generates code variants    │
│       │                                                         │
│       ▼                                                         │
│  4. genoutputs_net.py + driver_net.py: Execute → .raw outputs   │
│       │                                                         │
│       ▼                                                         │
│  5. getcov_fuzzbench_net.py: Launch parallel Docker containers  │
│     ┌──────────┬──────────┬──────────┬──────────┐               │
│     │ Docker 1 │ Docker 2 │ Docker 3 │ Docker N │               │
│     │ aflnet   │ aflnet   │ aflnet   │ aflnet   │               │
│     │   ↕      │   ↕      │   ↕      │   ↕      │               │
│     │Mosquitto │Mosquitto │Mosquitto │Mosquitto │               │
│     └──────────┴──────────┴──────────┴──────────┘               │
│       │                                                         │
│       ▼                                                         │
│  6. select_seeds_net.py: ILP/greedy set cover → elite seeds     │
│  7. select_states_net.py: State-aware distribution              │
│       │                                                         │
│       ▼                                                         │
│  8. Next Generation (repeat from step 3)                        │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

## Project Structure

```
GMPFuzz/
├── gmpfuzz_exec.sh              # Entry point script
├── all_gen_net.sh               # Main orchestration (multi-generation)
├── do_gen_net.sh                # Per-generation execution
├── do_gen_net_finial.sh         # Final generation (selection only)
├── elmconfig.py                 # Configuration management (reads config.yaml)
├── util.py                      # Utility functions
├── prepare_fuzzbench_net.py     # Docker image builder
├── getcov_fuzzbench_net.py      # Parallel Docker container launcher
├── genvariants_parallel_net.py  # LLM-based variant generation
├── genoutputs_net.py            # Execute Python generators → raw outputs
├── driver_net.py                # Sandboxed generator execution engine
├── select_seeds_net.py          # ILP/greedy seed selection
├── select_states_net.py         # State-aware seed distribution
├── analyze_cov.py               # Coverage analysis and plotting
├── preset/
│   ├── mqtt/                    # Mosquitto v1.5.5 target
│   │   ├── config.yaml          # MQTT fuzzing configuration
│   │   ├── seed_gen_mqtt.py     # Raw MQTT → Python generator converter
│   │   └── init_seeds/          # Initial raw MQTT seed files
│   ├── mongoose/                # Mongoose MQTT broker target
│   │   ├── config.yaml          # Mongoose fuzzing configuration
│   │   ├── seed_gen_mqtt.py     # Shared MQTT seed converter
│   │   └── init_seeds/          # Shared MQTT seed files
│   └── nanomq/                  # NanoMQ MQTT broker target
│       ├── config.yaml          # NanoMQ fuzzing configuration
│       ├── seed_gen_mqtt.py     # Shared MQTT seed converter
│       └── init_seeds/          # Shared MQTT seed files
├── fuzzbench/
│   ├── mqtt/                    # Mosquitto v1.5.5 Docker target
│   │   ├── Dockerfile           # Docker image: aflnet + Mosquitto
│   │   ├── run.sh               # aflnet invocation script
│   │   ├── cov_script.sh        # Coverage collection script
│   │   ├── mosquitto.conf       # Mosquitto broker configuration
│   │   ├── in-mqtt/             # Seed files copied into Docker
│   │   └── aflnet-master_mqtt/  # AFLNet source with MQTT support
│   ├── mongoose/                # Mongoose MQTT broker Docker target
│   │   ├── Dockerfile           # Docker image: aflnet + Mongoose
│   │   ├── run.sh               # aflnet invocation script
│   │   ├── cov_script.sh        # Coverage collection script
│   │   └── in-mqtt/             # Seed files copied into Docker
│   └── nanomq/                  # NanoMQ MQTT broker Docker target
│       ├── Dockerfile           # Docker image: aflnet + NanoMQ
│       ├── run.sh               # aflnet invocation script
│       ├── cov_script.sh        # Coverage collection script
│       ├── nanomq.conf          # NanoMQ broker configuration
│       └── in-mqtt/             # Seed files copied into Docker
└── requirements.txt
```

## Supported Targets

| Target | Version | Description | Preset |
|--------|---------|-------------|--------|
| **Mosquitto** | v1.5.5 | Eclipse Mosquitto MQTT broker | `preset/mqtt` |
| **Mongoose** | v7.20 | Cesanta Mongoose embedded MQTT server | `preset/mongoose` |
| **NanoMQ** | v0.21.10 | EMQ NanoMQ lightweight MQTT broker | `preset/nanomq` |

All targets use the same MQTT protocol seeds and seed generation logic (`seed_gen_mqtt.py`), ensuring fair comparison across different MQTT broker implementations.

## Prerequisites

- **Docker**: For running parallel aflnet instances
- **Python 3.10+**: For orchestration scripts
- **LLM endpoint** (e.g., CodeLlama via TGI): For variant generation
- **ruamel.yaml**: For config management
- **click**: For CLI interfaces
- **requests**: For LLM API calls

## Quick Start

### 1. Install Python dependencies

```bash
pip install -r requirements.txt
```

### 2. Build the Docker image

```bash
# Mosquitto (default)
export ELMFUZZ_RUNDIR=preset/mqtt
python prepare_fuzzbench_net.py -t profuzzbench

# Mongoose
export ELMFUZZ_RUNDIR=preset/mongoose
python prepare_fuzzbench_net.py -t profuzzbench

# NanoMQ
export ELMFUZZ_RUNDIR=preset/nanomq
python prepare_fuzzbench_net.py -t profuzzbench
```

### 3. Start an LLM endpoint (e.g., CodeLlama)

```bash
# Using Text Generation Inference (TGI)
docker run --gpus all -p 8080:80 \
    ghcr.io/huggingface/text-generation-inference:latest \
    --model-id codellama/CodeLlama-13b-hf
```

### 4. Run GMPFuzz

```bash
# Run against Mosquitto (default)
./gmpfuzz_exec.sh -r preset/mqtt

# Run against Mongoose
./gmpfuzz_exec.sh -r preset/mongoose

# Run against NanoMQ
./gmpfuzz_exec.sh -r preset/nanomq
```

## Configuration

Edit `preset/<target>/config.yaml` to customize (e.g., `preset/mqtt/config.yaml`):

- **project_name**: Target identifier (`mqtt`, `mongoose`, `nanomq`)
- **target.options**: AFLNet options for MQTT (e.g., `-P MQTT -D 10000 -q 3 -s 3 -E -K -R`)
- **model.endpoints**: LLM endpoint URL for variant generation
- **run.max_generations**: Maximum evolutionary generations (dynamic, ASE-driven)
- **run.selection_strategy**: `lattice` / `elites` / `best_of_generation`
- **run.num_selected**: Number of seeds to select per generation
- **run.state_pools**: State pool names for aflnet parallelism
- **ase**: Adaptive Synchronization Epoch parameters

## How It Works

1. **Initial Seeds**: Binary MQTT packet sequences from `preset/mqtt/init_seeds/`
2. **Seed Conversion**: `seed_gen_mqtt.py` parses raw MQTT packets and creates Python generator scripts with per-packet functions and a `__mqtt_gen__` dispatcher
3. **LLM Mutation**: `genvariants_parallel_net.py` uses CodeLlama to create variants via infilling, splicing, and completion of the Python generator code
4. **Output Generation**: `genoutputs_net.py` executes variants in sandboxed environments to produce new raw MQTT packet sequences
5. **Parallel Fuzzing**: `getcov_fuzzbench_net.py` launches Docker containers, each running aflnet against the target broker (Mosquitto/Mongoose/NanoMQ) with different seed subsets
6. **Seed Selection**: `select_seeds_net.py` uses ILP-based set cover to select a minimal seed set maximizing edge coverage
7. **State Distribution**: `select_states_net.py` distributes selected seeds across state pools for the next generation
8. **Iteration**: The process repeats for the configured number of generations

## Credits

- **TDPFuzz**: Architecture and parallel fuzzing framework
- **AFLNet**: Network protocol fuzzer
- **ProFuzzBench**: MQTT test target (Mosquitto) setup
- **Mongoose**: Embedded Web Server / Network Library by Cesanta
- **NanoMQ**: Ultra-lightweight MQTT Broker by EMQ
