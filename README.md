# ansible-gpuenv

GPU 服务器环境自动化部署项目。基于 Ansible 实现在线安装、检测、卸载 NVIDIA GPU 全套运行环境，覆盖硬件验收、服务器巡检、批量部署场景。

## 功能概述

- **组件按需安装**：默认不安装任何组件，全部由用户通过 `-e gpuenv_install_<组件>=true` 显式指定
- **在线/离线双模式**：每个组件按"版本 / 安装方式 / 在线地址 / 离线地址"四要素规范配置，均支持 `online`（在线）与 `package`（离线）两种安装模式
- **OFED 双 flavor**：IB 驱动支持 `mlnx_ofed`（MLNX_OFED）与 `doca_ofed`（DOCA-Host）二选一，与安装方式自由组合
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
│   ├── deploy.yml              # 部署配置清单（装哪些组件/模式/包路径，默认全注释）
│   ├── deploy.yml.example      # 配置清单模板（含预设场景）
│   └── gpuenv_repos.yml        # 软件源与版本配置（独立维护）
├── roles/
│   ├── gpuenv/                 # 安装 role
│   │   ├── defaults/main.yml   #   行为开关、路径、驱动子包列表
│   │   ├── templates/cuda.sh.j2
│   │   └── tasks/              #   按组件拆分的任务文件
│   ├── gpuenv_check/           # 检测 role（只读）
│   └── gpuenv_uninstall/       # 卸载 role
├── install_gpuenv.sh           # 单机版安装脚本（无 Ansible 依赖）
├── install_ansible.sh          # Ansible 环境安装辅助脚本
├── ssh-setup.sh                # SSH 免密配置脚本
├── INSTALL_GPUENV.md           # 手动命令行安装参考文档（不用 Ansible）
```

## 环境要求

| 项目 | 要求 |
|---|---|
| 目标系统 | Ubuntu 22.04 |
| 控制节点 | Ansible 2.10+、Python 3 |
| 网络 | 可访问 developer.download.nvidia.com（.cn 国内镜像同域可用，nvshmem 默认走 .cn）、github.com（直链类组件）；OFED：content.mellanox.com（mlnx_ofed tgz）、linux.mellanox.com（doca_ofed online 配源） |
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

### 4. 配置部署清单

要安装的组件、安装模式、离线包路径统一写在 `vars/deploy.yml`（部署配置清单）中，默认全部注释（即不安装任何组件）：

```bash
cp vars/deploy.yml.example vars/deploy.yml   # 首次使用时从模板创建（仓库已含空清单则直接编辑）
vim vars/deploy.yml                           # 取消注释并启用所需组件，预设场景见 example
```

### 5. 执行部署

配置清单写好后，一条命令即可完成部署（无需任何 `-e` 参数）：

```bash
ansible-playbook -i inventory.ini site.yml
```

临时覆盖（命令行 `-e` 优先级高于配置清单，仅本次生效）：

```bash
# 本次临时指定版本（不改动 deploy.yml）
ansible-playbook -i inventory.ini site.yml \
  -e gpuenv_driver_version=580.105.07 -e gpuenv_cuda_version=13.0.1

# 本次临时追加安装一个组件
ansible-playbook -i inventory.ini site.yml -e gpuenv_install_gpu_burn=true
```

> 说明：`-e` 优先级高于 deploy.yml，因此既可临时追加组件，也可用 `-e gpuenv_install_<组件>=false` 临时跳过清单中已启用的组件；要长期增删组件请直接编辑 deploy.yml。

仅部署指定节点：

```bash
ansible-playbook -i inventory.ini site.yml --limit node01
```

## 组件列表

所有组件默认不安装，在 `vars/deploy.yml` 中将对应开关置 `true` 启用（`-e gpuenv_install_<组件>=true` 可临时启用）：

| 开关 | 组件 | 用途 |
|---|---|---|
| `gpuenv_install_ofed=true` | OFED 驱动 / RDMA 栈 | IB 网络驱动，必须在 GPU 驱动之前安装；`mlnx_ofed` / `doca_ofed` 二选一 |
| `gpuenv_install_driver=true` | NVIDIA GPU 驱动 | GPU 基础驱动 |
| `gpuenv_install_peermem=true` | nvidia_peermem | GPUDirect RDMA 支持（依赖驱动） |
| `gpuenv_install_pci_acs=true` | 关闭 PCI ACS | 多机通信要求 |
| `gpuenv_install_cuda=true` | CUDA Toolkit | GPU 计算工具链 |
| `gpuenv_install_fabricmanager=true` | nvidia-fabricmanager | NVLink 多卡互联（版本须与驱动一致） |
| `gpuenv_install_gpu_burn=true` | gpu-burn | GPU 压力测试 |
| `gpuenv_install_nccl=true` | NCCL + OpenMPI + nccl-tests | 多卡集合通信与带宽测试 |
| `gpuenv_install_dcgm=true` | DCGM（datacenter-gpu-manager） | GPU 硬件诊断与监控 |
| `gpuenv_install_container_toolkit=true` | nvidia-container-toolkit | 容器内使用 GPU（会重启 docker） |
| `gpuenv_install_nvshmem=true` | NVSHMEM（nvshmem-cuda-\<大版本\>） | 多 GPU/多节点通信库，随装写入 GPUDirect RDMA 所需的 nvidia 驱动参数 |

## 安装模式与配置四要素

每个组件均支持在线/离线两种安装方式，在 `vars/deploy.yml` 中按固定顺序配置四要素（也可用 `-e` 临时覆盖）：

| 要素 | 变量 | 说明 |
|---|---|---|
| ① 版本 | `gpuenv_<组件>_version` | 无版本概念的组件省略（gpu_burn / nccl_tests 跟随 master 分支） |
| ② 安装方式 | `gpuenv_<组件>_install_mode` | `online`（在线，默认）/ `package`（离线） |
| ③ 在线地址 | `gpuenv_<组件>_url` | 仅【URL】直链类组件有独立 URL；【apt】类在线走软件源（`gpuenv_repo_base_url`，见 `vars/gpuenv_repos.yml`）；【URL+apt】类（doca_ofed / nvshmem）按版本自动拼接，均无独立 URL |
| ④ 离线地址 | `gpuenv_<组件>_package` | 仅 package 方式生效；本地路径（默认 `/opt/packages`）或离线包 URL 二选一，任务按 `http(s)://` 前缀自动分流（URL 下载 / 本地拷贝） |

> OFED 驱动另有第 ⑤ 要素 `gpuenv_ofed_flavor`，见下文【OFED 驱动双 flavor】。

### 在线安装机制（apt / URL / URL+apt）

各组件 `online` 模式实际走的通道（`vars/deploy.yml` 各组件块注释中同步标注）：

| 组件 | 机制 | 通道说明 |
|---|---|---|
| driver / cuda / fabricmanager / nccl / dcgm / container_toolkit | **apt** | NVIDIA 官方 CUDA apt 源（`gpuenv_repo_base_url`） |
| ofed（`gpuenv_ofed_flavor=mlnx_ofed`） | **apt** | Ubuntu 原生 `rdma-core` 系列 |
| ofed（`gpuenv_ofed_flavor=doca_ofed`） | **URL+apt** | 按 `gpuenv_ofed_version`（如 3.2.2）自动拼官方源 URL → 下载 GPG 密钥 + 写 `doca.list` → apt 安装 `doca-ofed` 元包（版本由所选源决定） |
| nvshmem | **URL+apt** | 按 `gpuenv_nvshmem_version`（如 3.7.2）自动拼官方引导 deb URL（developer.download.nvidia.cn）→ `dpkg` 建本地 apt 仓库 → 拷 keyring → apt 安装 `nvshmem-cuda-<CUDA 大版本>`（与 CUDA 主版本联动）；同时写入 GPUDirect RDMA 所需的 `/etc/modprobe.d/nvidia.conf` 驱动参数并刷新 initramfs |
| openmpi / nccl_tests / gpu_burn | **URL** | ③ 官方直链下载源码包后编译 |

### 各组件变量速查

| 组件 | 版本变量（①） | 模式变量（②） | 离线包变量（④） | 安装包类型 |
|---|---|---|---|---|
| driver | `gpuenv_driver_version` | `gpuenv_driver_install_mode` | `gpuenv_driver_package` | NVIDIA-Linux-x86_64-*.run |
| cuda | `gpuenv_cuda_version` | `gpuenv_cuda_install_mode` | `gpuenv_cuda_package` | cuda_*_linux.run |
| fabricmanager | `gpuenv_fm_version` | `gpuenv_fm_install_mode` | `gpuenv_fm_package` | nvidia-fabricmanager_*.deb |
| ofed | `gpuenv_ofed_version` | `gpuenv_ofed_install_mode` | `gpuenv_ofed_package` | mlnx_ofed：MLNX_OFED_LINUX-*.tgz；doca_ofed：本地 deb 目录 |
| nccl 三件套 | `gpuenv_nccl_version` / `gpuenv_openmpi_version` | `gpuenv_nccl_install_mode` / `gpuenv_openmpi_install_mode` / `gpuenv_nccl_tests_install_mode` | `gpuenv_nccl_package`（deb 目录）<br>`gpuenv_openmpi_package`（源码包）<br>`gpuenv_nccl_tests_package`（源码包） | deb + tar.gz + zip |
| gpu_burn | — | `gpuenv_gpu_burn_install_mode` | `gpuenv_gpu_burn_package` | gpu-burn zip 源码包 |
| dcgm | — | `gpuenv_dcgm_install_mode` | `gpuenv_dcgm_package` | datacenter-gpu-manager deb |
| container_toolkit | — | `gpuenv_container_toolkit_install_mode` | `gpuenv_container_toolkit_package` | nvidia-container-toolkit deb |
| nvshmem | `gpuenv_nvshmem_version` | `gpuenv_nvshmem_install_mode` | `gpuenv_nvshmem_package`（引导 deb） | nvshmem-local-repo 引导 deb → apt 装 nvshmem-cuda-X |

### OFED 驱动双 flavor（mlnx_ofed / doca_ofed）

`gpuenv_ofed_flavor` 二选一，与安装方式自由组合：

| flavor | 说明 | 版本（①）语义 | online（②） | package（④） |
|---|---|---|---|---|
| `mlnx_ofed`（默认） | MLNX_OFED 传统发行版 | OFED 版本号，如 `23.10-2.1.3.1`（`ofed_info` 校验） | 【apt】原生 `rdma-core` 系列 | MLNX_OFED_LINUX-*.tgz，`mlnxofedinstall` 安装 |
| `doca_ofed` | DOCA-Host（MLNX_OFED 的 1:1 继任者，同驱动/库/工具） | DOCA 发行版本，如 `3.2.2`（前缀匹配 `3.2.2-035000-25.10`） | 【URL+apt】无需 ③：按版本自动下载 GPG 密钥并写 DOCA 官方源（等价官方 doca-host 引导 deb 方式），apt 安装 `doca-ofed` 元包（版本由所选源决定） | 本地 deb 目录全量安装（须含 doca-ofed 元包与全部依赖 deb） |

`vars/deploy.yml` 配置示例（mlnx_ofed 离线 / doca_ofed 在线）：

```yaml
gpuenv_install_ofed: true
gpuenv_ofed_flavor: mlnx_ofed              # ⑤ 二选一（默认 mlnx_ofed）
gpuenv_ofed_version: "23.10-2.1.3.1"       # ① 版本（语义随 flavor 变化）
gpuenv_ofed_install_mode: package          # ② 安装方式
gpuenv_ofed_package: /opt/packages/MLNX_OFED_LINUX-23.10-2.1.3.1-ubuntu22.04-x86_64.tgz   # ④

# doca_ofed 在线模式示例（源 URL 按版本自动拼接，无需填在线地址）：
#gpuenv_ofed_flavor: doca_ofed
#gpuenv_ofed_version: "3.2.2"
#gpuenv_ofed_install_mode: online
```

> doca_ofed 在线模式与官方安装方式等价：GPG 密钥导入 `/etc/apt/trusted.gpg.d/`、源写入 `/etc/apt/sources.list.d/doca.list`（官方另提供 doca-host 引导 deb，其作用同样是写入此源配置）。切换 flavor 前建议先卸载现有 OFED（`ansible-playbook -i inventory.ini uninstall.yml -e gpuenv_uninstall_components=ofed`；doca 模式会同步卸载 doca-host 并清理 DOCA 源与密钥）。

离线安装的推荐方式是在 `vars/deploy.yml` 中配置（示例，完整场景见 `vars/deploy.yml.example` 场景 C）：

```yaml
gpuenv_install_driver: true
gpuenv_driver_install_mode: package
gpuenv_driver_package: /opt/packages/NVIDIA-Linux-x86_64-580.105.08.run

gpuenv_install_cuda: true
gpuenv_cuda_install_mode: package
gpuenv_cuda_package: /opt/packages/cuda_13.0.2_580.95.05_linux.run
```

配置好后同样一条命令执行：

```bash
ansible-playbook -i inventory.ini site.yml
```

> **注意**：CUDA run 包文件名中包含捆绑驱动版本（如 `cuda_13.0.2_580.95.05_linux.run`），与 `gpuenv_driver_version` 可能不同；其他版本的直链需按[官方归档页](https://developer.nvidia.com/cuda-toolkit-archive)调整。

## 版本与源配置

软件源和版本统一维护在 `vars/gpuenv_repos.yml`：

```yaml
gpuenv_repo_base_url: "https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64"
gpuenv_keyring_deb: "cuda-keyring_1.1-1_all.deb"
gpuenv_gpu_burn_url: "https://github.com/wilicc/gpu-burn/archive/refs/heads/master.zip"
gpuenv_driver_version: "580.105.08"
gpuenv_cuda_version: "13.0.2"
gpuenv_fm_version: ""                  # 留空则与驱动版本一致
gpuenv_nccl_version: "2.28.9"          # 需与 CUDA 版本配套
gpuenv_nccl_tests_url: "https://github.com/NVIDIA/nccl-tests/archive/refs/heads/master.zip"
gpuenv_openmpi_version: "4.1.7"
gpuenv_openmpi_url: "https://download.open-mpi.org/release/open-mpi/v4.1/openmpi-4.1.7.tar.gz"
gpuenv_ofed_flavor: "mlnx_ofed"        # mlnx_ofed / doca_ofed 二选一（语义见 OFED 双 flavor 章节）
gpuenv_ofed_version: "23.10-2.1.3.1"  # mlnx_ofed: OFED 版本号 / doca_ofed: DOCA 发行版本（如 3.2.2）
gpuenv_ofed_package: "https://content.mellanox.com/ofed/MLNX_OFED-23.10-2.1.3.1/MLNX_OFED_LINUX-23.10-2.1.3.1-ubuntu22.04-x86_64.tgz"
gpuenv_doca_repo_base: "https://linux.mellanox.com/public/repo/doca"  # doca_ofed 官方源基址（按版本拼 repo URL）
```

变量优先级（从低到高）：

```
role defaults < vars/gpuenv_repos.yml < vars/deploy.yml < 主机/组变量 < -e 命令行参数
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
- 可选：`nccl` `openmpi` `nccl_tests` `dcgm` `container_toolkit` `ofed` `peermem` `pci_acs` `nvshmem`

检测报告涵盖：gcc / cuda-keyring / 驱动 / CUDA / fabricmanager / dkms 模块 / nvidia-smi / nvcc / 环境变量 / gpu-burn / NCCL / OpenMPI / nccl-tests / DCGM / container-toolkit / OFED / nvidia_peermem / PCI ACS。

## 多机通信配置（IB / RoCE 场景）

多机 GPU 通信的前置配置与通信库均已自动化，均为独立组件，按需启用：

| 配置项 | 开关变量 | 默认 | 说明 |
|---|---|---|---|
| OFED 驱动 | `gpuenv_install_ofed` | false | IB 网络驱动（`mlnx_ofed` / `doca_ofed` 二选一），先于 GPU 驱动安装 |
| nvidia_peermem | `gpuenv_install_peermem` | false | GPUDirect RDMA 支持，加载模块并配置开机自动加载 |
| PCI ACS 关闭 | `gpuenv_install_pci_acs` | false | 幂等关闭所有支持 ACS 的设备，并配置开机服务自动执行 |
| NVSHMEM 通信库 | `gpuenv_install_nvshmem` | false | 多 GPU/多节点通信库（`nvshmem-cuda-<大版本>`，依赖驱动 + CUDA），随装写入 GPUDirect RDMA 驱动参数（需重启生效） |

ACS 关闭实现：`/usr/local/sbin/disable-pcie-acs.sh` 对全部支持 ACS 的设备**无条件幂等**写 `ACSCtl=0000`，并逐台输出 `BDF 前值 -> 后值` 审计明细；systemd 服务 `disable-pcie-acs.service`（`DefaultDependencies=no` + `Before=network-pre.target`）在开机先于网络栈自动重写——ACS 寄存器位于 PCI 配置空间，重启即恢复固件默认值，必须开机重设。playbook 收尾自动验证无 `SrcValid+` 残留，未关净即报错。

NVSHMEM 安装与官方命令逐步等价（实现见 `roles/gpuenv/tasks/nvshmem.yml`，以下为 3.7.2 示例）：

| NVSHMEM 官方命令 | role 自动化实现 |
|---|---|
| `wget .../3.7.2/local_installers/nvshmem-local-repo-ubuntu2204-3.7.2_3.7.2-1_amd64.deb` | 按 `gpuenv_nvshmem_version` 自动拼 URL 下载引导 deb（基址 `gpuenv_nvshmem_repo_base`，默认 .cn 镜像）；package 模式改从 `gpuenv_nvshmem_package`（本地路径/URL）获取 |
| `dpkg -i` 引导 deb | 安装引导包，建立本地 apt 仓库与源配置 |
| `cp /var/nvshmem-local-repo-*/nvshmem-*-keyring.gpg /usr/share/keyrings/` | 自动拷贝 keyring（内容一致时跳过） |
| `apt-get update` | 刷新源缓存（网络抖动自动重试） |
| `apt-get install nvshmem-cuda-13` | 安装 `nvshmem-cuda-<CUDA 大版本>`（与 CUDA 主版本联动，连带 libnvshmem3 runtime/dev/static 子包） |
| 写 `/etc/modprobe.d/nvidia.conf`：`options nvidia NVreg_EnableStreamMemOPs=1 NVreg_RegistryDwords="PeerMappingOverride=1;"` | 自动落盘驱动参数（与是否新装无关，每次执行确保写入） |
| `update-initramfs -u` | 参数变更时自动执行 |
| `sudo reboot` | **不自动执行**：参数需重启后在运行内核生效；验证 `cat /proc/driver/nvidia/params \| grep EnableStreamMemOPs` 应为 `1`（role 收尾三态提示：已生效 / 已写入待重启 / 未写入） |

> 离线模式：官方下载页获取同版本引导 deb 后，配置 `gpuenv_nvshmem_install_mode=package` + `gpuenv_nvshmem_package=<路径>`，后续安装步骤完全一致。

在 `vars/deploy.yml` 中启用对应开关后执行 `ansible-playbook -i inventory.ini site.yml` 即可；临时执行可：

```bash
ansible-playbook -i inventory.ini site.yml \
  -e gpuenv_install_peermem=true -e gpuenv_install_pci_acs=true
```

nccl-tests 带宽测试示例（需有 GPU）：

```bash
/opt/build/nccl-tests/build/all_reduce_perf -b 8 -e 128M -f 2 -g <GPU数>
```

## 其他行为开关

其他行为开关（在 `vars/deploy.yml` 中配置）：

| 变量 | 默认值 | 说明 |
|---|---|---|
| `gpuenv_force` | false | 忽略已安装检测，强制重装/重编译 |
| `gpuenv_reboot_after_driver` | false | 驱动安装后自动重启（加载内核模块） |
| `gpuenv_apt_hold` | true | 安装后 `apt-mark hold` 驱动/CUDA/fabricmanager/NCCL（及 doca flavor 下的 doca-ofed、nvshmem 组件的 nvshmem-cuda-X）全部版本联动包，防止 `apt upgrade` 意外升级（重装/升级/卸载前自动解除） |
| `gpuenv_uninstall_autoremove` | true | 卸载后执行 `apt autoremove --purge` 清理孤立依赖（仅 uninstall.yml 读取，可用 `-e gpuenv_uninstall_autoremove=false` 临时跳过） |

## 单机脚本，已暂停维护。（无 Ansible）

仅需在单台服务器部署时，可直接使用 `install_gpuenv.sh`：

```bash
bash install_gpuenv.sh start                                    # 默认版本安装
bash install_gpuenv.sh start --driver 580.105.08 --cuda 13.0.2   # 指定版本
bash install_gpuenv.sh uninstall                                # 卸载
bash install_gpuenv.sh --help                                   # 帮助
```

## 常用 tags

tags 需配合对应组件开关使用：

```bash
ansible-playbook -i inventory.ini site.yml -e gpuenv_install_driver=true --tags driver   # 仅驱动
ansible-playbook -i inventory.ini site.yml -e gpuenv_install_cuda=true --tags cuda       # 仅 CUDA
```

可用 tags：`precheck` `deps` `repo` `ofed` `driver` `peermem` `pci_acs` `cuda` `fabricmanager` `gpu_burn` `nccl` `dcgm` `container_toolkit` `nvshmem`

## 注意事项

1. **驱动版本锁定**：精确指定驱动版本时，脚本/role 会自动锁定全部驱动子包版本，避免依赖冲突
2. **fabricmanager 版本**：必须与驱动版本完全一致（默认自动跟随驱动版本）
3. **驱动生效需重启**：apt 安装驱动后需重启加载内核模块，未重启时 `nvidia-smi` 报错属正常现象（`gpuenv_reboot_after_driver` 默认关闭，需手动重启；控制节点 local 连接不会自动重启）
4. **无 GPU 环境**：`nvidia-smi`、fabricmanager 服务、gpu-burn 运行会失败，属正常现象，不影响安装
5. **container_toolkit 会重启 docker**：K8s 控制节点慎用，建议在 worker 节点启用
6. **NVSHMEM 驱动参数需重启生效**：nvshmem 组件写入 `/etc/modprobe.d/nvidia.conf`（`NVreg_EnableStreamMemOPs` 等 GPUDirect RDMA 参数）并自动 `update-initramfs`，运行中的内核模块不会热加载，需重启后生效；生效验证：`cat /proc/driver/nvidia/params | grep EnableStreamMemOPs` 应为 `1`（role 收尾自动检查并三态提示；官方命令全程对照见「多机通信配置」章节）
7. **OFED package 模式下载**：若 worker 节点访问 `content.mellanox.com` 出现 DNS 解析失败（偶发），可在控制节点用 `curl` 预下载 tgz 后，通过 `-e gpuenv_ofed_package=/path/to/mlnx_ofed.tgz` 传入本地路径，由 Ansible 分发到各节点；doca_ofed 离线模式同理，从 DOCA 官方源 `https://linux.mellanox.com/public/repo/doca/<版本>/ubuntu22.04/x86_64/` 全量下载 deb 放入一个目录后填 `gpuenv_ofed_package=/path/to/doca-debs`
8. **凭据安全**：`inventory.ini` 含密码，请勿提交到版本库或外传

## 驱动与 CUDA 版本兼容性说明

驱动与 CUDA 是**两套独立的版本序列**：驱动版本（如 580.105.08）是 NVIDIA 驱动的发布版本，CUDA 版本（如 13.0.2）是工具链版本，两者版本号不同是正常现象。

**CUDA run 包文件名中的驱动版本（如 `cuda_13.0.2_580.95.05_linux.run`）**只是该安装包**捆绑的一份驱动副本**，供未装驱动的机器开箱即用。本项目安装 CUDA 时使用 `--silent --toolkit` 参数，**只装工具链、不碰捆绑驱动**，系统实际生效的驱动始终是单独安装的 `gpuenv_driver_version`。

**兼容性判定规则（只有一条）**：驱动主系列（branch）≥ CUDA 要求的最低系列。

| CUDA 版本 | 要求驱动系列 | 示例 |
|---|---|---|
| CUDA 13.0 | ≥ 580 | 580.105.08 ✓ / 560.x ✗ |
| CUDA 12.6 | ≥ 560 | 560.35.05 ✓ / 550.x ✗ |

**验证方法**：

```bash
nvidia-smi   # 右上角显示 Driver Version 与其支持的 CUDA Version
nvcc -V      # 显示已安装的 CUDA 工具链版本
```

只要 `nvidia-smi` 显示的 CUDA 版本 ≥ `nvcc` 的版本，编译运行即正常。

**需要警惕的场景**：
- 驱动主系列低于 CUDA 要求（如 560 驱动配 CUDA 13）→ 编译失败或运行时报 `CUDA driver version is insufficient`
- 同一台机器混装两个不同系列的驱动 → 依赖冲突（本项目通过驱动子包版本锁定避免）

## 使用 run 包自带的驱动（driver package 模式）

如需改用 CUDA run 包捆绑的驱动（而非单独的 apt 驱动），在 `vars/deploy.yml` 中配置：

```yaml
gpuenv_driver_install_mode: package
gpuenv_driver_package: /opt/packages/cuda_13.0.2_580.95.05_linux.run   # 一个包两用
gpuenv_driver_version: "580.95.05"     # 必须改为 run 包实际捆绑的驱动版本
```

同一个 run 包驱动任务以 `--silent --dkms` 整包安装（含捆绑驱动），CUDA 任务以 `--silent --toolkit` 只装工具链，互不冲突。

也可单独下载独立驱动 run 包（更常规做法）：

```bash
wget https://download.nvidia.com/XFree86/Linux-x86_64/580.95.05/NVIDIA-Linux-x86_64-580.95.05.run -P /opt/packages/
```

```yaml
gpuenv_driver_install_mode: package
gpuenv_driver_package: /opt/packages/NVIDIA-Linux-x86_64-580.95.05.run
gpuenv_driver_version: "580.95.05"
```

**切换前必读**：

1. **`gpuenv_driver_version` 必须与 run 包捆绑版本一致**：package 模式的幂等判断基于 `nvidia-smi` 读到的实际版本，版本号不符会导致每次执行都判定为"需安装"而重装
2. **先卸载 apt 版驱动**：run 安装器检测到 dpkg 管理的驱动会拒绝安装，需先卸载再部署：

   ```bash
   ansible-playbook -i inventory.ini uninstall.yml -e gpuenv_uninstall_components=driver
   ansible-playbook -i inventory.ini site.yml
   ```

3. **fabricmanager 版本必须同步**：须与驱动完全一致。切换驱动版本后，离线包 `/opt/packages/nvidia-fabricmanager.deb` 版本不再匹配，需重新下载对应版本 deb、或临时禁用 fabricmanager、或改回在线模式安装
4. **卸载方式不同**：run 装的驱动不归 dpkg 管理，`uninstall.yml` 的 `apt remove` 对其**不生效**，需手动执行 `/usr/bin/nvidia-uninstall`

> 提示：run 包驱动（dkms 源码编译）与 apt 驱动（预编译包）是两套管理体系。如果只是想让版本号"看起来一致"，继续使用 apt 驱动 + 高版本 CUDA 的组合（如 580.105.08 + 13.0.2）更省心——两者本就兼容。

## 相关文档

- [INSTALL_GPUENV.md](INSTALL_GPUENV.md)：手动命令行安装参考文档（在线/离线，含全部包下载链接）
