# GPU 环境手动安装参考文档（INSTALL_GPUENV.md）

本文档为**命令行手动安装参考**（不依赖 Ansible / deploy.yml），版本基线与 `vars/deploy.yml` 当前方案一致：驱动 580.105.08 / CUDA 13.0.2 / fabricmanager 580.105.08-1 / NCCL 2.28.9-1+cuda13.0 / OpenMPI 4.1.7 / nccl-tests 2.17.6 / MLNX OFED 24.10-3.2.5.0。

**安装顺序（必须遵守）**：OFED（RDMA 栈）→ 驱动 → [重启] → CUDA → fabricmanager → NCCL → OpenMPI → nccl-tests / gpu-burn。

批量部署请用 Ansible（见 README）；本手册适用于单台机器、排障、或理解每步原理。

---

## 一、离线安装包下载链接汇总

在线安装可直接跳过本章。离线环境提前在可联网机器下载，上传到目标机 `/opt/packages/`：

| 组件 | 版本 | 下载链接 | 说明 |
|---|---|---|---|
| CUDA Toolkit | 13.0.2 | https://developer.download.nvidia.com/compute/cuda/13.0.2/local_installers/cuda_13.0.2_580.95.05_linux.run | 历史版本归档：https://developer.nvidia.com/cuda-toolkit-archive |
| NVIDIA 驱动 | 580.105.08 | https://download.nvidia.com/XFree86/Linux-x86_64/580.105.08/NVIDIA-Linux-x86_64-580.105.08.run | 按版本号拼接；驱动选择页：https://www.nvidia.com/drivers/ |
| fabricmanager | 580.105.08-1 | https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/nvidia-fabricmanager_580.105.08-1_amd64.deb | **必须与驱动版本严格一致** |
| MLNX OFED | 24.10-3.2.5.0 | https://content.mellanox.com/ofed/MLNX_OFED-24.10-3.2.5.0/MLNX_OFED_LINUX-24.10-3.2.5.0-ubuntu22.04-x86_64.tgz | 下载页：https://network.nvidia.com/products/infiniband-drivers/linux/mlnx_ofed/ |
| NCCL deb | 2.28.9-1+cuda13.0 | https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/libnccl2_2.28.9-1+cuda13.0_amd64.deb | libnccl2 与 libnccl-dev 两个都下载 |
| NCCL dev deb | 2.28.9-1+cuda13.0 | https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/libnccl-dev_2.28.9-1+cuda13.0_amd64.deb | 同上 |
| OpenMPI 源码 | 4.1.7 | https://download.open-mpi.org/release/open-mpi/v4.1/openmpi-4.1.7.tar.gz | 下载页：https://www.open-mpi.org/software/ompi/v4.1/ |
| nccl-tests 源码 | 2.17.6 | https://github.com/NVIDIA/nccl-tests/archive/refs/tags/v2.17.6.zip | Releases 页选版本 |
| gpu-burn 源码 | master | https://github.com/wilicc/gpu-burn/archive/refs/heads/master.zip | 指定版本：refs/tags/v1.1.zip |
| cuda-keyring | 1.1-1 | https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb | 配置 NVIDIA apt 源用 |

批量下载（可联网机器执行，国内建议用 `developer.download.nvidia.cn` 域名）：

```bash
mkdir -p /opt/packages && cd /opt/packages
curl -fLO https://developer.download.nvidia.cn/compute/cuda/13.0.2/local_installers/cuda_13.0.2_580.95.05_linux.run
curl -fLO https://developer.download.nvidia.cn/compute/cuda/repos/ubuntu2204/x86_64/nvidia-fabricmanager_580.105.08-1_amd64.deb
curl -fLO https://developer.download.nvidia.cn/compute/cuda/repos/ubuntu2204/x86_64/libnccl2_2.28.9-1+cuda13.0_amd64.deb
curl -fLO https://developer.download.nvidia.cn/compute/cuda/repos/ubuntu2204/x86_64/libnccl-dev_2.28.9-1+cuda13.0_amd64.deb
curl -fLO https://content.mellanox.com/ofed/MLNX_OFED-24.10-3.2.5.0/MLNX_OFED_LINUX-24.10-3.2.5.0-ubuntu22.04-x86_64.tgz
curl -fLO https://download.open-mpi.org/release/open-mpi/v4.1/openmpi-4.1.7.tar.gz
curl -fL  https://github.com/NVIDIA/nccl-tests/archive/refs/tags/v2.17.6.zip -o nccl-tests-2.17.6.zip
curl -fL  https://github.com/wilicc/gpu-burn/archive/refs/heads/master.zip -o gpu-burn-master.zip
```

---

## 二、前置准备

```bash
# 编译依赖（驱动 dkms / OpenMPI / nccl-tests 编译需要）
apt-get update
apt-get install -y build-essential linux-headers-$(uname -r) unzip curl

# 验证 gcc
gcc --version
```

配置 NVIDIA 官方 apt 源（在线安装驱动 / CUDA / fabricmanager / NCCL 需要）：

```bash
curl -fsSL https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb -o /tmp/cuda-keyring.deb
apt-get install -y /tmp/cuda-keyring.deb
apt-get update
# 国内加速可把域名换为 developer.download.nvidia.cn
```

---

## 三、MLNX OFED / RDMA 栈（须先于驱动）

### 在线安装（apt 原生 RDMA 栈，适用大多数场景）

```bash
apt-get install -y rdma-core ibverbs-providers ibverbs-utils \
  infiniband-diags perftest libibverbs-dev librdmacm-dev
```

验证：`ibv_devices` 能列出 IB 设备（无 IB/RoCE 网卡时输出空属正常）。

### 离线安装（官方 MLNX_OFED tgz，需要完整 OFED 功能时）

> 下载：https://content.mellanox.com/ofed/MLNX_OFED-24.10-3.2.5.0/MLNX_OFED_LINUX-24.10-3.2.5.0-ubuntu22.04-x86_64.tgz
> 下载页（选其他版本）：https://network.nvidia.com/products/infiniband-drivers/linux/mlnx_ofed/

```bash
cd /opt/packages
tar -xzf MLNX_OFED_LINUX-24.10-3.2.5.0-ubuntu22.04-x86_64.tgz
cd MLNX_OFED_LINUX-24.10-3.2.5.0-ubuntu22.04-x86_64
./mlnxofedinstall --all
```

验证：`ofed_info -s` 输出版本号。安装后**必须重启**再装驱动。

---

## 四、NVIDIA GPU 驱动

### 在线安装（apt，自动处理依赖）

```bash
# 安装 580 系列（当前源中该系列最新版）
apt-get install -y nvidia-driver-580

# 或精确锁定 580.105.08（多个子包必须同时锁同一版本，否则依赖冲突）
apt-get install -y \
  nvidia-driver-580=580.105.08-0ubuntu1 nvidia-dkms-580=580.105.08-0ubuntu1 \
  nvidia-kernel-common-580=580.105.08-0ubuntu1 libnvidia-compute-580=580.105.08-0ubuntu1
```

> 精确锁定的完整子包列表可执行 `apt-cache show nvidia-driver-580 | grep Depends` 按提示补齐；嫌繁琐可只装系列号（不锁 patch 版本）。

安装后重启并验证：

```bash
reboot
# 重启后
nvidia-smi    # 输出显卡列表 + Driver Version: 580.105.08 即成功
```

### 离线安装（官方 .run 安装器）

> 下载：https://download.nvidia.com/XFree86/Linux-x86_64/580.105.08/NVIDIA-Linux-x86_64-580.105.08.run
> 驱动选择页（按显卡型号）：https://www.nvidia.com/drivers/

```bash
cd /opt/packages
chmod +x NVIDIA-Linux-x86_64-580.105.08.run
./NVIDIA-Linux-x86_64-580.105.08.run --silent --dkms
reboot
```

> 注意：run 安装器检测到 apt 安装的驱动会拒绝执行，需先 `apt-get remove -y 'nvidia-driver*' 'libnvidia-*'` 清理。卸载 run 驱动用 `/usr/bin/nvidia-uninstall`（不是 apt remove）。

---

## 五、CUDA Toolkit

### 在线安装（apt）

```bash
# 13.0 系列（主.次版本拼接包名）
apt-get install -y cuda-toolkit-13-0
```

### 离线安装（run 包，只装 Toolkit 不装捆绑驱动）

> 下载：https://developer.download.nvidia.com/compute/cuda/13.0.2/local_installers/cuda_13.0.2_580.95.05_linux.run
> 历史版本归档：https://developer.nvidia.com/cuda-toolkit-archive

```bash
cd /opt/packages
chmod +x cuda_13.0.2_580.95.05_linux.run
./cuda_13.0.2_580.95.05_linux.run --silent --toolkit
```

配置环境变量（两种方式安装后都执行）：

```bash
cat > /etc/profile.d/cuda.sh <<'EOF'
export PATH=/usr/local/cuda/bin:$PATH
export LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH
EOF
source /etc/profile.d/cuda.sh
```

验证：`nvcc -V` 输出 `release 13.0`。

> 文件名中的 580.95.05 是 run 包捆绑的驱动副本，与实际驱动 580.105.08 不同属正常（`--toolkit` 不会安装它）；驱动 580 系列 ≥ CUDA 13 要求即可。

---

## 六、nvidia-fabricmanager（多卡 NVLink 必装）

版本必须与驱动**完全一致**（580.105.08）。

### 在线安装（apt）

```bash
apt-get install -y nvidia-fabricmanager-580=580.105.08-1
```

### 离线安装（deb 包）

> 下载：https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/nvidia-fabricmanager_580.105.08-1_amd64.deb
> 仓库目录（其他版本）：https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/

```bash
dpkg -i /opt/packages/nvidia-fabricmanager_580.105.08-1_amd64.deb
apt-get install -f    # 修复可能缺失的依赖
```

启动并验证（两种方式安装后都执行）：

```bash
systemctl enable nvidia-fabricmanager
systemctl start nvidia-fabricmanager
systemctl status nvidia-fabricmanager    # active (running)
```

> 无 GPU 或无 NVLink 交换机的机器上服务启动失败属正常，不影响其他组件。

---

## 七、NCCL 库

### 在线安装（apt，锁定版本与 CUDA 系列配套）

```bash
apt-get install -y libnccl2=2.28.9-1+cuda13.0 libnccl-dev=2.28.9-1+cuda13.0
```

> 版本需与 CUDA 系列配套（cuda13.0），可用 `apt-cache madison libnccl2` 查询源中可用版本。

### 离线安装（deb 包）

> 下载（两个都要）：
> - https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/libnccl2_2.28.9-1+cuda13.0_amd64.deb
> - https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/libnccl-dev_2.28.9-1+cuda13.0_amd64.deb
> 下载页（按 CUDA 版本选）：https://developer.nvidia.com/nccl/nccl-download

```bash
dpkg -i /opt/packages/libnccl2_2.28.9-1+cuda13.0_amd64.deb \
       /opt/packages/libnccl-dev_2.28.9-1+cuda13.0_amd64.deb
```

验证：`dpkg -l | grep nccl` 显示两个包均为 `ii` 状态。

---

## 八、OpenMPI（源码编译，安装到 /usr/local/openmpi）

> 源码下载：https://download.open-mpi.org/release/open-mpi/v4.1/openmpi-4.1.7.tar.gz
> 下载页：https://www.open-mpi.org/software/ompi/v4.1/

```bash
# 在线下载源码（或用离线包 /opt/packages/openmpi-4.1.7.tar.gz）
cd /opt
curl -fLO https://download.open-mpi.org/release/open-mpi/v4.1/openmpi-4.1.7.tar.gz

# 解压、编译、安装
tar -xzf openmpi-4.1.7.tar.gz
cd openmpi-4.1.7
./configure --prefix=/usr/local/openmpi
make -j$(nproc)
make install
```

配置环境变量：

```bash
cat > /etc/profile.d/openmpi.sh <<'EOF'
export PATH=/usr/local/openmpi/bin:$PATH
export LD_LIBRARY_PATH=/usr/local/openmpi/lib:$LD_LIBRARY_PATH
EOF
source /etc/profile.d/openmpi.sh
```

验证：`mpirun --version` 输出 `mpirun (Open MPI) 4.1.7`。

---

## 九、nccl-tests（多机带宽测试）

> 源码下载（2.17.6）：https://github.com/NVIDIA/nccl-tests/archive/refs/tags/v2.17.6.zip
> Releases 页（其他版本）：https://github.com/NVIDIA/nccl-tests/releases

```bash
# 在线下载源码（或用离线包 /opt/packages/nccl-tests-2.17.6.zip）
cd /opt
curl -fL https://github.com/NVIDIA/nccl-tests/archive/refs/tags/v2.17.6.zip -o nccl-tests-2.17.6.zip
unzip nccl-tests-2.17.6.zip
cd nccl-tests-2.17.6

# 编译（多机模式用 MPI=1；单机测试可去掉 MPI=1 MPI_HOME）
make -j MPI=1 MPI_HOME=/usr/local/openmpi CUDA_HOME=/usr/local/cuda
```

验证：`ls build/all_reduce_perf` 存在即编译成功。

```bash
# 单机带宽测试
./build/all_reduce_perf -b 8 -e 128M -f 2 -g <GPU数>

# 多机测试（节点间需 SSH 免密互信）
mpirun --prefix /usr/local/openmpi --allow-run-as-root -np 16 \
  -H <node01>:8,<node02>:8 \
  -x NCCL_SOCKET_IFNAME=bond0 -x LD_LIBRARY_PATH -x PATH \
  /opt/nccl-tests-2.17.6/build/all_reduce_perf -b 128 -e 4G -f 2 -g 1
```

多机前置（按需）：

```bash
modprobe nvidia_peermem                                    # GPUDirect RDMA
lspci -vvv | grep ACSCtl                                   # 输出含 SrcValid+ 则需关闭 ACS
```

---

## 十、gpu-burn（GPU 压力烤机）

> 源码下载（master）：https://github.com/wilicc/gpu-burn/archive/refs/heads/master.zip
> 指定版本（如 v1.1）：https://github.com/wilicc/gpu-burn/archive/refs/tags/v1.1.zip

```bash
# 在线下载源码（或用离线包 /opt/packages/gpu-burn-master.zip）
cd /opt
curl -fL https://github.com/wilicc/gpu-burn/archive/refs/heads/master.zip -o gpu-burn-master.zip
unzip gpu-burn-master.zip
cd gpu-burn-master
make    # 编译警告可忽略，生成 gpu_burn 可执行文件即成功
```

执行压测：

```bash
./gpu_burn 60        # 60 秒；硬件验收建议 1800 秒长烤
```

结果判定：全部显卡输出 `GPU X: OK` 为正常；出现 error/failed 需排查硬件。

---

## 十一、目录约定与验证

| 路径 | 用途 |
|---|---|
| `/opt/packages` | 离线安装包存放 |
| `/usr/local/cuda` | CUDA Toolkit 安装位置 |
| `/usr/local/openmpi` | OpenMPI 安装位置 |
| `/etc/profile.d/` | cuda.sh / openmpi.sh 环境变量 |

全部装完后逐项验证：

```bash
ibv_devices                                        # RDMA 栈
nvidia-smi                                         # 驱动（Driver Version: 580.105.08）
nvcc -V                                            # CUDA（release 13.0）
systemctl status nvidia-fabricmanager              # fabricmanager
dpkg -l | grep nccl                                # NCCL
mpirun --version                                   # OpenMPI（4.1.7）
ls /opt/nccl-tests-2.17.6/build/all_reduce_perf    # nccl-tests
ls /opt/gpu-burn-master/gpu_burn                   # gpu-burn
```
