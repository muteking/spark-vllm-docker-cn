# 开机第一步先睹为快，体验一下128G内存被瞬间灌满的感觉吧！！！
开机后打开终端依次运行下列命令：
```bash
git clone https://github.com/muteking/spark-vllm-docker-cn.git
cd spark-vllm-docker-cn
##一键部署环境，第一次运行需要下载会比较慢。
./build-and-copy.sh
##选择可用的配置加载相应模型，不同模型等待加载根据网络情况耗时不等。首次需要下载比较慢。
./run-recipe.sh
```
# [双节点集群部署要点：](https://github.com/muteking/spark-vllm-docker-cn/blob/main/docs/%E9%9B%86%E7%BE%A4%E7%BD%91%E7%BB%9C%E8%AE%BE%E7%BD%AE.md)

如果你不是网络专家或者很熟悉网络配置，部署双节点集群做到下面几点尤其是前两点，然后照着官方给出的命令行一步步粘贴运行就能跑通了。
##-1.✅**只插一根线**，两根线同时插带宽不会加倍成400gbs，配置不正确带宽还会减半成100gbs；
##-2.✅**同插外侧口**，这样每个命令行执行的结果才会跟官方文档结果一致，不需要更改命令行一路粘贴回车；
###-3. 双节点互联使用的IP地址是**69.254.*.* **，不是192.168.*.*或者其他任何地址段
###-4. 200gbs的NCCL测试结果显示的最大数值25GBs，200gbs是比特，25GBs是字节，8倍的关系；
###-5. 当前显示可能不足20GBs，也有可能是15+GBs，官方论坛说是固件引起的，要么回滚到旧版本要么等修复；
   
***注意：本人的主机还在运行中尚不能进行完整测试，所以无法保证代码准确性和可行性，如有急用先参考原始项目进行部署[spark-vllm-docker](https://github.com/eugr/spark-vllm-docker）。
# vLLM Docker Optimized for DGX Spark (单节点/多节点)

> **中文说明：** 本仓库基于 [spark-vllm-docker](https://github.com/eugr/spark-vllm-docker) 进行本地化改进，添加中英双语支持，并在大模型下载时优先使用魔社源和HuggingFace国内镜像，更好地支持中文用户。

This repository contains the Docker configuration and startup scripts to run a multi-node vLLM inference cluster using Ray. It supports InfiniBand/RDMA (NCCL) and custom environment configuration for high-performance setups.

While it was primarily developed to support multi-node inference, it works just as well on a single node setups.

---

## 📚 中文说明 / Chinese Introduction

### 🎯 项目简介

✅本项目是为 **DGX Spark 集群**优化的 vLLM Docker 配置和启动脚本。支持多节点 vLLM 推理集群部署，兼容 InfiniBand/RDMA (NCCL) 高速网络。
✅本项目更改了hf-download.sh脚本适配国内环境下载，添加了国内modelscope下载和HuggingFace国内镜像以提升下载速度。
✅本项目可能能让你在DgxSpark首次登录后半小时内完成加载模型看到内存占用率飙升到100GB+，GPU利用率90%+的效果。
✅我本人是小白爱好者，所有更改都由Openclaw配合Qwen3.5根据我的想法完成，所以理论上提供不了任何更深入的技术支持。
✅本项目所有中文翻译都由机器完成，不保证准确性。

✅本项目更改了hf-download.sh脚本适配国内环境下载，添加了国内魔社modelscope下载和HuggingFace国内镜像以提升下载速度。
✅本项目所有翻译都由机器完成，不保证准确性。

### 🚀 主要功能

- ✅ **单节点/多节点支持** - 适用于单台 DGX Spark 或整个集群
- ✅ **中英双语支持** - 所有脚本注释和输出都已翻译成中文
- ✅ **高性能配置** - 针对 Hopper GPU (12.1a) 优化
- ✅ **自动网络检测** - 自动检测以太网和 InfiniBand 接口
- ✅ **智能模型下载** - 支持 ModelScope/HF Mirror/官方源多源下载（hf-download.sh）
- ✅ **一键部署** - 自动构建和分发 Docker 镜像

### 📝 改进内容

相比原项目，本仓库添加了：

1. **中英双语支持**
   - 所有脚本注释都添加了中文翻译
   - 所有输出信息都有中英双语显示
   - 帮助信息完全中文化

2. **用户体验优化**
   - 优先通过modelscope魔社或huggingface国内镜像下载大模型
   - recipe菜单互动化加载
   - 配方添加--served-model-name参数（默认为.yaml的文件名，方便openclaw配置连接）
   - 修复了部分脚本缩进问题
   - 添加了详细的中文说明文档
   - 改进了错误提示信息
3. **本地化下载及交互式配置**
---

## 🌐 原始项目 / Original Project

本项目基于以下开源项目 Fork 而来：

- **原始仓库**: [https://github.com/eugr/spark-vllm-docker](https://github.com/eugr/spark-vllm-docker)
- **作者**: Eugene Rakhmatulin
- **许可证**: [MIT License](LICENSE)

### 感谢原作者的贡献！🙏

---

## Table of Contents / 目录

- [Disclaimer / 免责声明](#disclaimer)
- [Quick Start / 快速开始](#quick-start)
- [Changelog / 更新日志](#changelog)
- [1. Building the Docker Image / 构建 Docker 镜像](#1-building-the-docker-image)
- [2. Launching the Cluster / 启动集群](#2-launching-the-cluster-recommended)
- [3. Running the Container / 手动运行容器](#3-running-the-container-manual)
- [4. Configuration / 配置说明](#5-configuration-details)
- [5. Mods and Patches / 补丁和修改](#6-mods-and-patches)
- [6. Launch Scripts / 启动脚本](#7-launch-scripts)
- [7. Cluster Mode Inference / 集群推理](#8-using-cluster-mode-for-inference)
- [8. Fastsafetensors / 快速加载](#9-fastsafetensors)
- [9. Benchmarking / 性能测试](#10-benchmarking)
- [10. Model Download / 模型下载](#11-downloading-models)

---

## DISCLAIMER / 免责声明

> **English**: This repository is not affiliated with NVIDIA or their subsidiaries. This is a community effort aimed to help DGX Spark users to set up and run the most recent versions of vLLM on Spark cluster or single nodes.
>
> **中文**：本仓库与 NVIDIA 或其子公司无关。这是社区为帮助 DGX Spark 用户搭建和运行最新版 vLLM 而进行的努力。

Unless `--rebuild-vllm` or `--vllm-ref` or `--apply-vllm-pr` is specified, the builder will fetch the latest precompiled vLLM wheels from the repository. They are built nightly and tested on multiple models in both cluster and solo configuration before publishing.
We will expand the selection of models we test in the pipeline, but since vLLM is a rapidly developing platform, some things may break.

> **中文说明**：除非指定了 `--rebuild-vllm` 或 `--vllm-ref` 或 `--apply-vllm-pr` 参数，否则构建器会从仓库获取最新预编译的 vLLM wheel。这些 wheel 每晚构建，并在集群和单机配置下对多个模型进行测试后才发布。我们将扩展测试的模型选择范围，但由于 vLLM 是一个快速发展的平台，某些功能可能会出现问题。

If you want to build the latest from main branch, you can specify `--rebuild-vllm` flag. Or you can target a specific vLLM release by setting `--vllm-ref` parameter.

> **中文说明**：如果你想构建主分支的最新版本，可以指定 `--rebuild-vllm` 参数。或者你可以设置 `--vllm-ref` 参数来指定特定的 vLLM 版本。

---

## QUICK START / 快速开始

### 先睹为快测试版（单机版）
开机后打开终端
依次运行下列命令：
```bash
git clone https://github.com/muteking/spark-vllm-docker-cn.git
cd spark-vllm-docker-cn
##一键部署环境，第一次运行需要下载会比较慢。
./build-and-copy.sh
##选择可用的配置加载相应模型，不同模型等待加载根据网络情况耗时不等。首次需要下载比较慢。
./run-recipe.sh
```
等待完成看系统监控。

### Build / 构建

Check out locally. If using DGX Spark cluster, do it on the head node.

> **中文**：克隆到本地。如果使用 DGX Spark 集群，请在主节点上执行。

```bash
git clone https://github.com/muteking/spark-vllm-docker-cn.git
cd spark-vllm-docker-cn
```

Build the container.

> **构建容器**

**If you have only one DGX Spark:**
> **如果你只有一台 DGX Spark：**

```bash
./build-and-copy.sh
```

**For multi-node cluster:**
> **多节点集群：**

```bash
./build-and-copy.sh -c <node1_ip>,<node2_ip>
```

---

## CHANGELOG / 更新日志

### 本版本改进 / Improvements in This Fork

- 🌐 **中英双语支持** - 所有脚本和输出都添加了中文翻译
- 📝 **文档完善** - 添加了详细的中文说明
- 🐛 **Bug 修复** - 修复了 autodiscover.sh 的缩进问题
- ✨ **用户体验** - 改进了错误提示和帮助信息

### 原项目更新 / Original Project Updates

See [original changelog](https://github.com/eugr/spark-vllm-docker/blob/main/README.md#changelog) for upstream changes.

> **中文**：查看[原项目更新日志](https://github.com/eugr/spark-vllm-docker/blob/main/README.md#changelog)以了解上游项目的更新。

---

## 1. Building the Docker Image / 构建 Docker 镜像

> **中文说明**：构建 Docker 镜像需要 NVIDIA GPU 和 Docker 环境。

### Prerequisites / 前置条件

- NVIDIA GPU (Hopper 架构支持最佳)
- Docker 20.10+
- At least 200GB disk space for building

> **磁盘空间**：构建至少需要 200GB 磁盘空间

### Build Command / 构建命令

```bash
# 单节点构建
./build-and-copy.sh

# 带参数构建
./build-and-copy.sh \
  --tag my-vllm-image \
  --build-jobs 16 \
  --rebuild-vllm
```

---

## 2. Launching the Cluster / 启动集群

### Quick Start / 快速启动

```bash
# 单节点启动
./launch-cluster.sh

# 多节点启动（自动检测）
./launch-cluster.sh -c <peer_ip1>,<peer_ip2>

# 手动指定节点
./launch-cluster.sh -n 192.168.1.12,192.168.1.13
```

### Available Options / 可用选项

```bash
./launch-cluster.sh --help

# 主要选项：
#   -n, --nodes     逗号分隔的节点 IP 列表（可选，省略则自动检测）
#   -t              Docker 镜像名称（可选，默认：vllm-node）
#   --name          容器名称（可选，默认：vllm_node）
#   --eth-if        以太网接口（可选，自动检测）
#   --ib-if         InfiniBand 接口（可选，自动检测）
#   --check-config  检查配置和自动检测，但不启动
#   --solo          单独模式：跳过自动检测，仅在当前节点启动
#   -d              守护进程模式（仅适用于'start'操作）
```

---

## 3. Running the Container / 手动运行容器

```bash
# 检查配置
./launch-cluster.sh --check-config

# 启动容器
./launch-cluster.sh --name my-container start

# 查看状态
./launch-cluster.sh status

# 停止容器
./launch-cluster.sh stop
```

---

## 4. Configuration / 配置说明

### Environment Variables / 环境变量

```bash
# 额外 Docker 参数
export VLLM_SPARK_EXTRA_DOCKER_ARGS="-e VLLM_WORKERS_MEMORY_RATIO=0.9"

# 构建作业数
export BUILD_JOBS=16
```

---

## 5. Mods and Patches / 补丁和修改

本项目包含以下补丁：

- **flashinfer_cache.patch** - FlashInfer 缓存优化
- **fastsafetensors.patch** - 快速安全张量加载
- **flashinfer_cache.patch** - FlashInfer 缓存补丁

---

## 6. Launch Scripts / 启动脚本

在 `examples/` 目录下提供了一些启动脚本示例：

```bash
ls examples/
```

使用示例：

```bash
# 使用内置脚本
./launch-cluster.sh --launch-script my-script.sh

# 使用自定义脚本
./launch-cluster.sh --launch-script /path/to/script.sh
```

---

## 7. Cluster Mode Inference / 集群推理

### Basic Usage / 基本用法

```bash
# 启动推理服务
./launch-cluster.sh --name vllm_cluster start

# 执行推理命令
./launch-cluster.sh exec -- "vllm serve Qwen/Qwen3.5-0.8B --port 8000"
```

### Distributed Training / 分布式训练

```bash
# 使用无 Ray 模式（PyTorch 分布式后端）
./launch-cluster.sh --no-ray --name dist_train start

# 执行分布式命令
./launch-cluster.sh exec -- "python train.py --nnodes 2 --node-rank 0"
```

---

## 8. Fastsafetensors / 快速加载

本项目支持 fastsafetensors 以加速模型加载。

> **注意**：需要额外的依赖，已在镜像中预装。

---

## 9. Benchmarking / 性能测试

### Benchmark Commands / 基准测试命令

```bash
# 吞吐量测试
./launch-cluster.sh exec -- \
  "python benchmark_throughput.py \
   --model Qwen/Qwen3.5-0.8B \
   --input-len 256 \
   --output-len 128"
```

---

## 10. Model Download / 模型下载

本项目提供了智能模型下载脚本，支持多源下载：

```bash
cd ~/jack/spark-vllm-docker-cn

# 下载模型（支持 ModelScope/HF Mirror/官方源）
./hf-download.sh Qwen/Qwen3.5-0.8B

# 下载并复制到其他节点
./hf-download.sh Qwen/Qwen3.5-0.8B -c 192.168.1.12,192.168.1.13
```

### Supported Sources / 支持的源

1. **ModelScope** (魔塔社区) - 国内源，无需梯子 ✅ 推荐
2. **HF Mirror** - 国内镜像，无需梯子
3. **Official HF** - 官方源，可能需要梯子

---

## 📜 License / 许可证

本仓库采用 [MIT License](LICENSE)，与原始项目保持一致。

**原始项目**：
- 仓库：https://github.com/eugr/spark-vllm-docker
- 作者：Eugene Rakhmatulin
- 许可证：MIT

> **版权声明**：本仓库保留了原始项目的完整版权声明，遵循 MIT 许可证要求。

---

## 🤝 Contributing / 贡献

欢迎贡献！请遵循以下步骤：

1. Fork 本仓库
2. 创建特性分支 (`git checkout -b feature/AmazingFeature`)
3. 提交更改 (`git commit -m 'Add some AmazingFeature'`)
4. 推送到分支 (`git push origin feature/AmazingFeature`)
5. 开启 Pull Request

---

## 📮 Contact / 联系方式

- 原始项目：https://github.com/eugr/spark-vllm-docker
- 本仓库：https://github.com/muteking/spark-vllm-docker-cn
- Issues: [GitHub Issues](https://github.com/muteking/spark-vllm-docker-cn/issues)

---

## 🙏 Acknowledgments / 致谢

- 感谢 [Eugene Rakhmatulin](https://github.com/eugr) 的原始项目
- 感谢 [vLLM](https://github.com/vllm-project/vllm) 团队
- 感谢 [NVIDIA](https://www.nvidia.com/) 提供的 GPU 技术支持

---

**Made with ❤️ for the Chinese AI community**

**为中文 AI 社区而生**
