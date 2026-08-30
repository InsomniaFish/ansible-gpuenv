# ansible-gpuenv

GPU 服务器环境自动化部署项目。基于 Ansible 实现在线安装、检测、卸载 NVIDIA GPU 全套运行环境，覆盖硬件验收、服务器巡检、批量部署场景。

## 功能概述

- **在线安装**：通过 NVIDIA 官方软件仓库（apt）安装驱动、CUDA、fabricmanager 等组件，无需手动下载安装包
- **版本可控**：软件源与版本独立配置，支持命令行临时覆盖，驱动子包自动锁定版本避免依赖冲突
- **幂等执行**：已安装且版本一致的组件自动跳过，可安全重复运行
- **组件检测**：只读检测各节点组件安装状况，输出结构化报告
- **一键卸载**：purge 方式清理全部组件并验证无残留
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
└── install_GPUENV.md           # 手动安装操作手册
```

## 环境要求

| 项目 | 要求 |
|---|---|
| 目标系统 | Ubuntu 22.04 |
| 控制节点 | Ansible 2.10+、Python 3 |
| 网络 | 可访问 developer.download.nvidia.com 与 github.com |
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

```bash
# 按 vars/gpuenv_repos.yml 中的版本安装所有节点
ansible-playbook -i inventory.ini site.yml

# 指定版本安装
ansible-playbook -i inventory.ini site.yml \
  -e gpuenv_driver_version=550.127.05 -e gpuenv_cuda_version=12.4

# 仅部署指定节点
ansible-playbook -i inventory.ini site.yml --limit node01
```

## 版本与源配置

软件源和版本统一维护在 `vars/gpuenv_repos.yml`：

```yaml
gpuenv_repo_base_url: "https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64"
gpuenv_keyring_deb: "cuda-keyring_1.1-1_all.deb"
gpuenv_gpu_burn_url: "https://github.com/wilicc/gpu-burn/archive/refs/heads/master.zip"
gpuenv_driver_version: "550.163.01"
gpuenv_cuda_version: "12.4"
gpuenv_fm_version: ""          # 留空则与驱动版本一致
```

变量优先级（从低到高）：

```
role defaults < vars/gpuenv_repos.yml < 主机/组变量 < -e 命令行参数
```

## 组件检测与卸载

```bash
# 检测所有节点组件状况（只读，不做修改）
ansible-playbook -i inventory.ini check.yml

# 卸载指定节点（破坏性操作，建议先检测）
ansible-playbook -i inventory.ini check.yml --limit node01
ansible-playbook -i inventory.ini uninstall.yml --limit node01
```

检测报告涵盖：gcc / cuda-keyring / 驱动 / CUDA / fabricmanager / dkms 模块 / nvidia-smi / nvcc / 环境变量 / gpu-burn。

## 可选组件

以下组件默认不安装，通过 `-e` 开关启用：

| 开关 | 组件 | 用途 |
|---|---|---|
| `gpuenv_install_nccl=true` | NCCL 库 + nccl-tests | 多卡集合通信与带宽测试 |
| `gpuenv_install_dcgm=true` | DCGM（datacenter-gpu-manager） | GPU 硬件诊断与监控 |
| `gpuenv_install_container_toolkit=true` | nvidia-container-toolkit | 容器内使用 GPU（会重启 docker） |

```bash
# 组合启用
ansible-playbook -i inventory.ini site.yml \
  -e gpuenv_install_nccl=true -e gpuenv_install_dcgm=true

# 仅安装某个可选组件（基础组件已装时）
ansible-playbook -i inventory.ini site.yml --tags nccl -e gpuenv_install_nccl=true
```

nccl-tests 带宽测试示例（需有 GPU）：

```bash
/root/ansible-gpuenv/nccl-tests-master/build/all_reduce_perf -b 8 -e 128M -f 2 -g <GPU数>
```

## 其他行为开关

| 变量 | 默认值 | 说明 |
|---|---|---|
| `gpuenv_skip_gpu_burn` | false | 跳过 gpu-burn 下载编译 |
| `gpuenv_force` | false | 忽略已安装检测，强制重装/重编译 |
| `gpuenv_reboot_after_driver` | false | 驱动安装后自动重启（加载内核模块） |

## 单机脚本（无 Ansible）

仅需在单台服务器部署时，可直接使用 `install_gpuenv.sh`：

```bash
bash install_gpuenv.sh start                                    # 默认版本安装
bash install_gpuenv.sh start --driver 550.127.05 --cuda 12.4    # 指定版本
bash install_gpuenv.sh uninstall                                # 卸载
bash install_gpuenv.sh --help                                   # 帮助
```

## 常用 tags

```bash
ansible-playbook -i inventory.ini site.yml --tags driver            # 仅驱动
ansible-playbook -i inventory.ini site.yml --tags cuda              # 仅 CUDA
ansible-playbook -i inventory.ini site.yml --tags fabricmanager     # 仅 fabricmanager
ansible-playbook -i inventory.ini site.yml --tags gpu_burn          # 仅 gpu-burn
```

可用 tags：`precheck` `deps` `repo` `driver` `cuda` `fabricmanager` `gpu_burn` `nccl` `dcgm` `container_toolkit`

## 注意事项

1. **驱动版本锁定**：精确指定驱动版本时，脚本/role 会自动锁定全部驱动子包版本，避免依赖冲突
2. **fabricmanager 版本**：必须与驱动版本完全一致（默认自动跟随驱动版本）
3. **驱动生效需重启**：apt 安装驱动后需重启加载内核模块，未重启时 `nvidia-smi` 报错属正常现象
4. **无 GPU 环境**：`nvidia-smi`、fabricmanager 服务、gpu-burn 运行会失败，属正常现象，不影响安装
5. **container_toolkit 会重启 docker**：K8s 控制节点慎用，建议在 worker 节点启用
6. **凭据安全**：`inventory.ini` 含密码，请勿提交到版本库或外传

## 相关文档

- [install_GPUENV.md](install_GPUENV.md)：手动安装操作手册（含原理说明与踩坑提示）
