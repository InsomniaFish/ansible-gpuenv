# ansible-gpuenv

GPU 服务器环境自动化部署项目。基于 Ansible 实现在线安装、检测、卸载 NVIDIA GPU 全套运行环境，覆盖硬件验收、服务器巡检、批量部署场景。

## 功能概述

- **组件按需安装**：默认不安装任何组件，全部由用户通过 `-e gpuenv_install_<组件>=true` 显式指定
- **在线/离线双模式**：每个组件均支持 `online`（在线）与 `package`（离线本地包）两种安装模式
- **版本可控**：软件源与版本独立配置，支持命令行临时覆盖，驱动子包自动锁定版本避免依赖冲突
- **幂等执行**：已安装且版本一致的组件自动跳过，可安全重复运行
- **组件检测**：只读检测各节点组件安装状况，输出结构化报告
- **组件级卸载**：支持卸载全部、核心组件或指定单个组件（如仅卸载 NCCL、DCGM）
- **免密配置**：内置 SSH 免密脚本，支持各主机不同密码

## 目录结构

```
ansible-gpuenv/
├── site.yml                    # 安装 playbook
├── check.yml                   # 检测 playbook
├── uninstall.yml               # 卸载 playbook
├── inventory.ini               # 主机清单（实际环境，含凭据，勿外传）
├── inventory.ini.example       # 主机清单模板
├── vars/
│   └── gpuenv_repos.yml        # 软件源与版本配置（独立维护）
├── roles/
│   ├── GPUENV/                 # 安装 role
│   │   ├── defaults/main.yml   #   行为开关、路径、驱动子包列表
│   │   ├── templates/cuda.sh.j2
│   │   └── tasks/              #   按组件拆分的任务文件
│   ├── GPUENV_CHECK/           # 检测 role（只读）
│   └── GPUENV_UNINSTALL/       # 卸载 role
├── install_gpuenv.sh           # 单机版安装脚本（无 Ansible 依赖）
├── install_ansible.sh          # Ansible 环境安装辅助脚本
├── ssh-setup.sh                # SSH 免密配置脚本
├── install_GPUENV.md           # 手动安装操作手册
└── base_vesion.md              # NCCL-Tests 连接测试安装指南（版本基线）
```

## 环境要求

| 项目 | 要求 |
|---|---|
| 目标系统 | Ubuntu 22.04 |
| 控制节点 | Ansible 2.10+、Python 3 |
| 网络 | 可访问 developer.download.nvidia.com、github.com、download.open-mpi.org、content.mellanox.com（OFED package 模式） |
| 权限 | root 用户（或配置 sudo 提权） |

## 快速开始

### 0. 安装 Ansible（控制节点未安装时）

```bash
bash install_ansible.sh    # 安装 ansible + sshpass
```

### 1. 配置主机清单

```bash
cp inventory.ini.example inventory.ini
# 编辑 inventory.ini，填入主机 IP 与认证信息
```

各主机密码不同时，在主机行单独指定 `ansible_password`（覆盖组级配置）。

### 2. 配置 SSH 免密（可选，推荐）

```bash
./ssh-setup.sh            # 生成密钥并分发到远程主机
./ssh-setup.sh --check    # 检查免密是否生效
./ssh-setup.sh --list     # 列出清单中的主机
```

### 3. 验证连通性

```bash
ansible -i inventory.ini gpu_nodes -m ping
```

### 4. 执行部署

默认不安装任何组件，需通过 `-e gpuenv_install_<组件>=true` 指定要安装的组件：

```bash
# 在线安装驱动 + CUDA（按 vars/gpuenv_repos.yml 中的版本）
ansible-playbook -i inventory.ini site.yml \
  -e gpuenv_install_driver=true -e gpuenv_install_cuda=true

# 指定版本安装
ansible-playbook -i inventory.ini site.yml \
  -e gpuenv_install_driver=true -e gpuenv_install_cuda=true \
  -e gpuenv_driver_version=560.35.03 -e gpuenv_cuda_version=12.6

# 仅部署指定节点
ansible-playbook -i inventory.ini site.yml \
  -e gpuenv_install_driver=true --limit node01
```

## 组件列表

所有组件默认不安装，通过开关变量启用：

| 开关 | 组件 | 用途 |
|---|---|---|
| `gpuenv_install_ofed=true` | MLNX OFED / RDMA 栈 | IB 网络驱动，必须在 GPU 驱动之前安装 |
| `gpuenv_install_driver=true` | NVIDIA GPU 驱动 | GPU 基础驱动 |
| `gpuenv_install_peermem=true` | nvidia_peermem | GPUDirect RDMA 支持（依赖驱动） |
| `gpuenv_install_pci_acs=true` | 关闭 PCI ACS | 多机通信要求 |
| `gpuenv_install_cuda=true` | CUDA Toolkit | GPU 计算工具链 |
| `gpuenv_install_fabricmanager=true` | nvidia-fabricmanager | NVLink 多卡互联（版本须与驱动一致） |
| `gpuenv_install_gpu_burn=true` | gpu-burn | GPU 压力测试 |
| `gpuenv_install_nccl=true` | NCCL + OpenMPI + nccl-tests | 多卡集合通信与带宽测试 |
| `gpuenv_install_dcgm=true` | DCGM（datacenter-gpu-manager） | GPU 硬件诊断与监控 |
| `gpuenv_install_container_toolkit=true` | nvidia-container-toolkit | 容器内使用 GPU（会重启 docker） |

## 安装模式（在线 / 离线）

每个组件均支持两种安装模式，通过 `-e gpuenv_<组件>_install_mode=<模式>` 指定：

| 模式 | 说明 |
|---|---|
| `online`（默认） | 在线安装：apt 官方源 / 官方直链下载 |
| `package` | 离线安装：通过 `-e gpuenv_<组件>_package=<本地包路径>` 指定本地安装包 |

各组件离线安装包变量：

| 组件 | 模式变量 | 离线包变量 | 安装包类型 |
|---|---|---|---|
| driver | `gpuenv_driver_install_mode` | `gpuenv_driver_package` | NVIDIA-Linux-x86_64-*.run |
| cuda | `gpuenv_cuda_install_mode` | `gpuenv_cuda_package` | cuda_*_linux.run |
| fabricmanager | `gpuenv_fm_install_mode` | `gpuenv_fm_package` | nvidia-fabricmanager_*.deb |
| ofed | `gpuenv_ofed_install_mode` | `gpuenv_ofed_package` | MLNX_OFED_LINUX-*.tgz |
| nccl | `gpuenv_nccl_install_mode` | `gpuenv_nccl_package`（deb 目录）<br>`gpuenv_openmpi_src_package`（源码包）<br>`gpuenv_nccl_tests_src_package`（源码包） | deb + tar.gz + zip |
| gpu_burn | `gpuenv_gpu_burn_install_mode` | `gpuenv_gpu_burn_package` | gpu-burn zip 源码包 |
| dcgm | `gpuenv_dcgm_install_mode` | `gpuenv_dcgm_package` | datacenter-gpu-manager deb |
| container_toolkit | `gpuenv_container_toolkit_install_mode` | `gpuenv_container_toolkit_package` | nvidia-container-toolkit deb |

```bash
# 离线安装驱动 + CUDA（本地 .run 安装包）
ansible-playbook -i inventory.ini site.yml \
  -e gpuenv_install_driver=true -e gpuenv_driver_install_mode=package \
  -e gpuenv_driver_package=/path/to/NVIDIA-Linux-x86_64-560.35.05.run \
  -e gpuenv_install_cuda=true -e gpuenv_cuda_install_mode=package \
  -e gpuenv_cuda_package=/path/to/cuda_12.6.2_560.35.03_linux.run

# 离线安装 OFED（本地 tgz 安装包）
ansible-playbook -i inventory.ini site.yml \
  -e gpuenv_install_ofed=true -e gpuenv_ofed_install_mode=package \
  -e gpuenv_ofed_package=/path/to/MLNX_OFED_LINUX-24.10-1.1.4.0-ubuntu22.04-x86_64.tgz
```

> **注意**：CUDA run 包文件名中包含捆绑驱动版本（如 `cuda_12.6.2_560.35.03_linux.run`），与 `gpuenv_driver_version` 可能不同；其他版本的直链需按[官方归档页](https://developer.nvidia.com/cuda-toolkit-archive)调整。

## 版本与源配置

软件源和版本统一维护在 `vars/gpuenv_repos.yml`：

```yaml
gpuenv_repo_base_url: "https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64"
gpuenv_keyring_deb: "cuda-keyring_1.1-1_all.deb"
gpuenv_gpu_burn_url: "https://github.com/wilicc/gpu-burn/archive/refs/heads/master.zip"
gpuenv_driver_version: "560.35.05"     # 版本基线见 base_vesion.md
gpuenv_cuda_version: "12.6.2"
gpuenv_fm_version: ""                  # 留空则与驱动版本一致
gpuenv_nccl_version: "2.23.4"          # 需与 CUDA 版本配套
gpuenv_nccl_tests_url: "https://github.com/NVIDIA/nccl-tests/archive/refs/heads/master.zip"
gpuenv_openmpi_version: "4.1.5"
gpuenv_openmpi_url: "https://download.open-mpi.org/release/open-mpi/v4.1/openmpi-4.1.5.tar.gz"
gpuenv_ofed_version: "24.10-1.1.4.0"
gpuenv_ofed_package: "https://content.mellanox.com/ofed/MLNX_OFED-24.10-1.1.4.0/MLNX_OFED_LINUX-24.10-1.1.4.0-ubuntu22.04-x86_64.tgz"
```

变量优先级（从低到高）：

```
role defaults < vars/gpuenv_repos.yml < 主机/组变量 < -e 命令行参数
```

## 组件检测与卸载

```bash
# 检测所有节点组件状况（只读，不做修改）
ansible-playbook -i inventory.ini check.yml

# 卸载指定节点核心组件（驱动 / CUDA / fabricmanager / gpu-burn）
ansible-playbook -i inventory.ini uninstall.yml --limit node01

# 卸载全部组件（核心 + 可选）
ansible-playbook -i inventory.ini uninstall.yml -e gpuenv_uninstall_components=all

# 仅卸载指定组件（逗号分隔，不影响其他组件）
ansible-playbook -i inventory.ini uninstall.yml -e gpuenv_uninstall_components=nccl,dcgm
```

`gpuenv_uninstall_components` 取值：

| 取值 | 说明 |
|---|---|
| `core`（默认） | 核心组件：driver / cuda / fabricmanager / gpu_burn |
| `all` | 全部组件（核心 + 可选） |
| 逗号分隔列表 | 仅卸载指定组件 |

可用组件名：

- 核心：`driver` `cuda` `fabricmanager` `gpu_burn`
- 可选：`nccl` `openmpi` `nccl_tests` `dcgm` `container_toolkit` `ofed` `peermem` `pci_acs`

检测报告涵盖：gcc / cuda-keyring / 驱动 / CUDA / fabricmanager / dkms 模块 / nvidia-smi / nvcc / 环境变量 / gpu-burn / NCCL / OpenMPI / nccl-tests / DCGM / container-toolkit / OFED / nvidia_peermem / PCI ACS。

## 多机通信配置（IB / RoCE 场景）

多机 NCCL 测试的前置配置已自动化（基线见 `base_vesion.md`），均为独立组件，按需启用：

| 配置项 | 开关变量 | 默认 | 说明 |
|---|---|---|---|
| MLNX OFED | `gpuenv_install_ofed` | false | IB 网络驱动，先于 GPU 驱动安装 |
| nvidia_peermem | `gpuenv_install_peermem` | false | GPUDirect RDMA 支持，加载模块并配置开机自动加载 |
| PCI ACS 关闭 | `gpuenv_install_pci_acs` | false | 检测 ACS 状态，启用时自动关闭并配置开机持久化 |

```bash
# 仅执行多机通信配置
ansible-playbook -i inventory.ini site.yml \
  -e gpuenv_install_peermem=true -e gpuenv_install_pci_acs=true
```

nccl-tests 带宽测试示例（需有 GPU）：

```bash
/opt/nccl-tests/build/all_reduce_perf -b 8 -e 128M -f 2 -g <GPU数>
```

## 其他行为开关

| 变量 | 默认值 | 说明 |
|---|---|---|
| `gpuenv_force` | false | 忽略已安装检测，强制重装/重编译 |
| `gpuenv_reboot_after_driver` | false | 驱动安装后自动重启（加载内核模块） |

## 单机脚本（无 Ansible）

仅需在单台服务器部署时，可直接使用 `install_gpuenv.sh`：

```bash
bash install_gpuenv.sh start                                    # 默认版本安装
bash install_gpuenv.sh start --driver 560.35.05 --cuda 12.6.2   # 指定版本
bash install_gpuenv.sh uninstall                                # 卸载
bash install_gpuenv.sh --help                                   # 帮助
```

## 常用 tags

tags 需配合对应组件开关使用：

```bash
ansible-playbook -i inventory.ini site.yml -e gpuenv_install_driver=true --tags driver   # 仅驱动
ansible-playbook -i inventory.ini site.yml -e gpuenv_install_cuda=true --tags cuda       # 仅 CUDA
```

可用 tags：`precheck` `deps` `repo` `ofed` `driver` `peermem` `pci_acs` `cuda` `fabricmanager` `gpu_burn` `nccl` `dcgm` `container_toolkit`

## 注意事项

1. **驱动版本锁定**：精确指定驱动版本时，脚本/role 会自动锁定全部驱动子包版本，避免依赖冲突
2. **fabricmanager 版本**：必须与驱动版本完全一致（默认自动跟随驱动版本）
3. **驱动生效需重启**：apt 安装驱动后需重启加载内核模块，未重启时 `nvidia-smi` 报错属正常现象
4. **无 GPU 环境**：`nvidia-smi`、fabricmanager 服务、gpu-burn 运行会失败，属正常现象，不影响安装
5. **container_toolkit 会重启 docker**：K8s 控制节点慎用，建议在 worker 节点启用
6. **OFED package 模式下载**：若 worker 节点访问 `content.mellanox.com` 出现 DNS 解析失败（偶发），可在控制节点用 `curl` 预下载 tgz 后，通过 `-e gpuenv_ofed_package=/path/to/mlnx_ofed.tgz` 传入本地路径，由 Ansible 分发到各节点
7. **凭据安全**：`inventory.ini` 含密码，请勿提交到版本库或外传

## 相关文档

- [base_vesion.md](base_vesion.md)：NCCL-Tests 连接测试安装指南（版本基线与多机测试命令）
- [install_GPUENV.md](install_GPUENV.md)：手动安装操作手册（含原理说明与踩坑提示）
