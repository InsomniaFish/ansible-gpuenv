# NCCL-Tests 连接测试安装指南（完全版）

本文档介绍 GPU 集群环境下 NCCL 多机通信测试环境的完整部署流程，涵盖驱动、CUDA、NCCL、OpenMPI、nccl-tests 的安装，以及 IB / RoCE 网络下的带宽测试方法与参考基线。

## 一、版本基线

> **重要**：需先安装 IB 网络驱动（MLNX OFED），再安装 GPU 驱动，否则无法使用 `nvidia_peermem`（此限制不适用于 Ubuntu 24.04）。

| 项目 | 版本 | 备注 |
|---|---|---|
| Linux 系统 | Ubuntu 22.04 | |
| Linux 内核 | <= 6.8 | |
| MLNX OFED | 24.10-1.1.4.0-LTS | 先装 OFED，再装 GPU 驱动 |
| GPU 驱动 | 560.35.05 | 560.35.03 也可 |
| CUDA | 12.6 | 12.6 分为 12.6.1~12.6.3，建议 12.6.2 |
| OpenMPI | 4.1.5 | 需使用源码编译方式安装 |
| NCCL | 2.23.4 | deb 包安装或在线安装 |
| nvidia_peermem | 开启 | 见下方说明 |
| PCI ACS | 关闭 | 见测试前置检查 |

### nvidia_peermem 与 DMA_BUF 说明

Ubuntu 24.04 及后续版本废弃 `nvidia_peermem`，改用 DMA_BUF，要求：

- Linux Kernel >= 6.8
- CUDA Toolkit >= 11.7
- GPU driver branch >= 515，且使用 open 驱动
- NCCL >= 2.13.4

## 二、安装 NVIDIA 驱动、CUDA、fabricmanager

### 2.1 在线安装

```bash
apt-get install nvidia-driver-560 -y
apt-get install nvidia-fabricmanager-560 -y
apt-get install cuda-toolkit-12-6 -y
```

### 2.2 参考文档与下载地址

- 安装参考：https://blog.csdn.net/Guzarish/article/details/141909956
- CUDA 历史版本归档：https://developer.nvidia.com/cuda-toolkit-archive
- CUDA 12.6.2（Ubuntu 22.04 deb 网络安装）：
  https://developer.nvidia.com/cuda-12-6-2-download-archive?target_os=Linux&target_arch=x86_64&Distribution=Ubuntu&target_version=22.04&target_type=deb_network
- CUDA 下载（Ubuntu 24.04）：
  https://developer.nvidia.com/cuda-downloads?target_os=Linux&target_arch=x86_64&Distribution=Ubuntu&target_version=24.04&target_type=deb_network
- CUDA 12.4.0 归档：https://developer.nvidia.com/cuda-12-4-0-download-archive

### 2.3 设置 CUDA 环境变量

```bash
echo 'export PATH=/usr/local/cuda/bin:$PATH' >> /root/.bashrc
echo 'export LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH' >> /root/.bashrc
```

配置后重新登录系统生效。

### 2.4 安装 nvidia-fabricmanager

软件仓库地址（按 Ubuntu 版本选择目录）：

```
https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/
```

> **注意**：nvidia-fabricmanager 包名种类众多，必须下载与驱动版本严格匹配的 `nvidia-fabricmanager-<系列>_<驱动版本>-1_amd64.deb` 包。

```bash
dpkg -i nvidia-fabricmanager-xxx.deb
```

## 三、安装 NCCL

下载地址：https://developer.nvidia.com/nccl/nccl-download

根据 CUDA 版本选择对应的 deb 包安装，安装后验证：

```bash
dpkg -l | grep nccl
```

## 四、编译安装 OpenMPI

OpenMPI 4.1.5 需源码编译安装。

### 4.1 下载源码

官方地址：https://www.open-mpi.org/software/ompi/v4.1/

```bash
wget https://download.open-mpi.org/release/open-mpi/v4.1/openmpi-4.1.5.tar.gz
# 备用地址
wget https://scheduled-file-backups.oss-cn-beijing.aliyuncs.com/dw/openmpi-4.1.5.tar.gz
```

### 4.2 编译安装

```bash
tar -xzvf openmpi-4.1.5.tar.gz
cd openmpi-4.1.5
./configure --prefix=/usr/local/openmpi
make -j 192
sudo make install
```

### 4.3 配置环境变量

```bash
echo "export PATH=/usr/local/openmpi/bin:$PATH" >> /etc/profile
echo "export LD_LIBRARY_PATH=/usr/local/openmpi/lib:$LD_LIBRARY_PATH" >> /etc/profile
source /etc/profile
```

## 五、编译安装 nccl-tests

源码地址：https://github.com/NVIDIA/nccl-tests

```bash
wget https://scheduled-file-backups.oss-cn-beijing.aliyuncs.com/dw/nccl-tests-master.zip
unzip nccl-tests-master.zip
cd nccl-tests-master
```

按测试场景选择编译方式：

```bash
# 单机测试编译
make MPI_HOME=/usr/local/openmpi

# 多机测试编译
make MPI=1 MPI_HOME=/usr/local/openmpi
```

## 六、执行测试

### 6.1 单机测试

```bash
./build/all_reduce_perf -b 16M -e 1G -f 2 -g 8 -c 1
```

### 6.2 多机测试前置准备

所有测试机器之间需要双向互信免密登录，并完成以下两项检查：

**① 加载 nvidia_peermem（重要）**

```bash
modprobe nvidia_peermem
```

参考文档：https://docs.nvidia.com/deeplearning/nccl/user-guide/docs/troubleshooting.html

**② 检查并关闭 PCI Switch 的 ACS（重要）**

```bash
# 检查：若输出行显示 "SrcValid+"，则说明启用了 ACS
lspci -vvv | grep ACSCtl
```

若 ACS 已开启，使用以下脚本关闭：

```bash
for BDF in $(lspci -d "*:*:*" | awk '{print $1}'); do
  # 跳过不支持 ACS 的设备
  sudo setpci -v -s ${BDF} ECAP_ACS+0x6.w > /dev/null 2>&1
  if [ $? -ne 0 ]; then
    continue
  fi
  sudo setpci -v -s ${BDF} ECAP_ACS+0x6.w=0000
done
```

### 6.3 IB 网络多机测试命令（已验证可达官方值）

```bash
mpirun --prefix /usr/local/openmpi \
  --allow-run-as-root \
  --mca btl_tcp_if_include bond0 \
  -np 16 \
  -x NCCL_SOCKET_IFNAME=bond0 \
  -x NCCL_IB_HCA=mlx5_0:1,mlx5_1:1,mlx5_2:1,mlx5_3:1,mlx5_4:1,mlx5_5:1,mlx5_6:1,mlx5_7:1 \
  -x UCX_TLS=rc,sm \
  -x CUDA_VISIBLE_DEVICES=0,1,2,3,4,5,6,7 \
  -x LD_LIBRARY_PATH -x PATH \
  -bind-to numa --gmca btl tcp,self \
  -H 10.13.43.150:8,10.13.43.149:8 \
  /root/nccl-tests/build/all_reduce_perf -b 128 -e 4G -f 2 -g 1
```

### 6.4 RoCE 网络多机测试命令

```bash
mpirun --prefix /usr/local/openmpi \
  --allow-run-as-root \
  --mca btl_tcp_if_include enp24s0np0 \
  -np 16 \
  -x NCCL_SOCKET_IFNAME=enp24s0np0 \
  -x NCCL_IB_HCA=mlx5_0:1,mlx5_1:1,mlx5_10:1,mlx5_11:1,mlx5_2:1,mlx5_3:1,mlx5_8:1,mlx5_9:1 \
  -x NCCL_IB_GID_INDEX=3 \
  -x UCX_TLS=rc,sm \
  -x CUDA_VISIBLE_DEVICES=0,1,2,3,4,5,6,7 \
  -x LD_LIBRARY_PATH -x PATH \
  -bind-to numa --gmca btl tcp,self \
  -x NCCL_IB_DISABLE=0 -x NCCL_IB_QPS_PER_CONNECTION=1 \
  -x NCCL_NET_GDR_LEVEL=2 -x NCCL_PXN_DISABLE=0 \
  -x NCCL_IB_TC=162 -x NCCL_CHECKS_DISABLE=1 \
  -x UCX_NET_DEVICE=mlx5_8:1 \
  -H 10.81.32.10:8,10.81.32.13:8 \
  /root/nccl/nccl-tests-master/build/all_reduce_perf -b 128 -e 4G -f 2 -g 1
```

### 6.5 双机 RoCE 验证命令

```bash
mpirun --prefix /usr/local/openmpi \
  --allow-run-as-root -np 16 \
  --mca btl_tcp_if_include enp24s0np0 \
  -H 10.81.32.10:8,10.81.32.13:8 \
  -x NCCL_SOCKET_IFNAME=enp24s0np0 \
  -x NCCL_DEBUG=INFO \
  -x NCCL_IB_HCA=mlx5_0:1,mlx5_1:1,mlx5_10:1,mlx5_11:1,mlx5_2:1,mlx5_3:1,mlx5_8:1,mlx5_9:1 \
  -x UCX_NET_DEVICES=mlx5_8:1 \
  -x NCCL_IB_QPS_PER_CONNECTION=1 -x NCCL_IB_TC=162 \
  -x NCCL_CHECKS_DISABLE=1 -x NCCL_NVLS_ENABLE=0 \
  -x NCCL_IB_GID_INDEX=3 -x UCX_TLS=rc \
  /root/nccl/nccl-tests-master/build/all_reduce_perf -b 128 -e 16G -f 2 -g 1 -w 10
```

> **注意**：可能由于 RoCE 组网环境差异，导致 MPI 建连的网卡选择不同。如以太网无法建立连接或数据表现不佳，可改用 RoCE 网卡进行建连。

## 七、错误处理

### 7.1 NVLS 报错：Cuda failure 1 'invalid argument'

报错信息：

```
transport/nvls.cc:254 NCCL WARN Cuda failure 1 'invalid argument'
```

处理方法：添加环境变量 `export NCCL_NVLS_ENABLE=0`，示例（alltoall，已验证可达官方值）：

```bash
mpirun --prefix /usr/local/openmpi \
  --allow-run-as-root \
  --mca btl_tcp_if_include bond0 \
  -np 16 \
  -x NCCL_SOCKET_IFNAME=bond0 \
  -x NCCL_IB_HCA=mlx5_0:1,mlx5_1:1,mlx5_2:1,mlx5_3:1,mlx5_4:1,mlx5_5:1,mlx5_6:1,mlx5_8:1 \
  -x UCX_TLS=rc,sm \
  -x CUDA_VISIBLE_DEVICES=0,1,2,3,4,5,6,7 \
  -x NCCL_DEBUG=INFO \
  -x LD_LIBRARY_PATH -x PATH \
  -bind-to numa --gmca btl tcp,self \
  -H 10.133.0.2:8,10.133.0.3:8 \
  /root/nccl-tests-2.17.2/build/alltoall_perf -b 128 -e 4G -f 2 -g 1 -a 3 -w 20 -n 10
```

### 7.2 NVLS Multicast 绑定失败

报错信息：

```
transport/nvls.cc:284 NCCL WARN Failed to bind NVLink SHARP (NVLS) Multicast memory of size 2097152 :
CUDA error 401 'the operation cannot be performed in the present state'.
This is usually caused by a system or configuration error in the Fabric Manager or NVSwitches.
Disable NVLS (NCCL_NVLS_ENABLE=0) if you wish to avoid this error in the future.
```

处理方法：通常为 Fabric Manager 或 NVSwitch 配置问题，可设置 `NCCL_NVLS_ENABLE=0` 规避，或排查 fabricmanager 服务状态。

## 八、测试结果参考基线（H100）

| 测试规模 | alltoall (GB/s) | allreduce (GB/s) |
|---|---|---|
| 2 机 2 卡 | 27.33 | 48.74 |
| 2 机 4 卡 | 54.30 | 135.00 |
| 2 机 8 卡 | 74.10 | 312.06 |
| 2 机 16 卡 | 75.00 | 468.09 |

## 九、其他已验证命令示例

### 9.1 allreduce（bond0 建连）

```bash
mpirun --prefix /usr/local/openmpi \
  --allow-run-as-root -np 16 \
  --mca btl_tcp_if_include bond0 \
  -H 10.81.32.10:8,10.81.32.13:8 \
  -x NCCL_SOCKET_IFNAME=bond0 \
  -x NCCL_IB_HCA=mlx5_0:1,mlx5_1:1,mlx5_10:1,mlx5_11:1,mlx5_2:1,mlx5_3:1,mlx5_8:1,mlx5_9:1 \
  -x UCX_NET_DEVICES=mlx5_8:1 \
  -x UCX_TLS=rc \
  /root/nccl/nccl-tests-master/build/all_reduce_perf -b 128 -e 8G -f 2 -g 1 -w 10
```

### 9.2 alltoall（bond0 建连）

```bash
mpirun --prefix /usr/local/openmpi \
  --allow-run-as-root -np 16 \
  --mca oob_tcp_if_include bond0 \
  -H 10.81.32.9:8,10.81.32.20:8 \
  -x NCCL_SOCKET_IFNAME=bond0 \
  -x NCCL_IB_HCA=mlx5_0:1,mlx5_1:1,mlx5_10:1,mlx5_11:1,mlx5_2:1,mlx5_3:1,mlx5_8:1,mlx5_9:1 \
  -x UCX_NET_DEVICES=mlx5_8:1 \
  -x UCX_TLS=rc \
  /root/nccl/nccl-tests-master/build/alltoall_perf -b 128 -e 8G -f 2 -g 1 -w 10
```

### 9.3 alltoall（NVLS 调优参数示例）

```bash
mpirun --prefix /usr/local/openmpi \
  --allow-run-as-root \
  --mca btl_openib_warn_no_device_params_found 0 \
  --mca oob_tcp_if_include bond0 \
  -H 10.81.32.10:2,10.81.32.13:2 --map-by ppr:2:node \
  -x NCCL_IB_GID_INDEX=3 -x NCCL_IB_SL=5 -x NCCL_IB_TC=136 \
  -x NCCL_SOCKET_IFNAME=bond0 \
  -x NCCL_IB_HCA=mlx5_0,mlx5_1,mlx5_10,mlx5_11,mlx5_2,mlx5_3,mlx5_8,mlx5_9 \
  -x NCCL_DEBUG=INFO \
  -x NCCL_IB_QPS_PER_CONNECTION=4 \
  -x NCCL_MIN_NCHANNELS=4 \
  -x NCCL_NET_PLUGIN=none \
  -x NCCL_NVLS_ENABLE=1 \
  -x NCCL_IB_SPLIT_DATA_ON_QPS=1 \
  /root/nccl/nccl-tests-master/build/alltoall_perf -b 1k -e 16g -g 1 -f 2 -w 10
```

### 9.4 大规模 allreduce（hostfile 方式，DMA_BUF 启用）

25 节点 200 卡：

```bash
mpirun --prefix /root/package/openmpi/ \
  --allow-run-as-root \
  --mca oob_tcp_if_include bond0.700 \
  -np 200 \
  -x NCCL_SOCKET_IFNAME=bond0.700 \
  -x NCCL_IB_HCA=mlx5,^mlx5_bond_0 \
  -x CUDA_VISIBLE_DEVICES=0,1,2,3,4,5,6,7 \
  -x UCX_TLS=dc_x \
  -x LD_LIBRARY_PATH -x PATH \
  -x NCCL_DMABUF_ENABLE=1 \
  -bind-to numa --gmca btl tcp,self \
  -x NCCL_DEBUG=INFO -x NCCL_ALGO=NVLSTREE \
  --hostfile hostfile-25 \
  /root/package/nccl-tests-2.16.8/build/all_reduce_perf -b 8G -e 35G -i2G -g1 -t1 -w60 -n60
```

32 节点 256 卡（同上，替换 `-np 256` 与 `--hostfile hostfile-32`）：

```bash
mpirun --prefix /root/package/openmpi/ \
  --allow-run-as-root \
  --mca oob_tcp_if_include bond0.700 \
  -np 256 \
  -x NCCL_SOCKET_IFNAME=bond0.700 \
  -x NCCL_IB_HCA=mlx5,^mlx5_bond_0 \
  -x CUDA_VISIBLE_DEVICES=0,1,2,3,4,5,6,7 \
  -x UCX_TLS=dc_x \
  -x LD_LIBRARY_PATH -x PATH \
  -x NCCL_DMABUF_ENABLE=1 \
  -bind-to numa --gmca btl tcp,self \
  -x NCCL_DEBUG=INFO -x NCCL_ALGO=NVLSTREE \
  --hostfile hostfile-32 \
  /root/package/nccl-tests-2.16.8/build/all_reduce_perf -b 8G -e 35G -i2G -g1 -t1 -w60 -n60
```

16 卡双机（DMA_BUF + NVLSTREE）：

```bash
mpirun --prefix /root/package/openmpi/ \
  --allow-run-as-root \
  --mca oob_tcp_if_include bond0.700 \
  -np 16 \
  -x NCCL_SOCKET_IFNAME=bond0.700 \
  -x NCCL_IB_HCA=mlx5,^mlx5_bond_0 \
  -x CUDA_VISIBLE_DEVICES=0,1,2,3,4,5,6,7 \
  -x UCX_TLS=dc_x \
  -x LD_LIBRARY_PATH -x PATH \
  -x NCCL_DMABUF_ENABLE=1 \
  -bind-to numa --gmca btl tcp,self \
  -x NCCL_DEBUG=INFO -x NCCL_ALGO=NVLSTREE \
  -H 10.13.42.30:8,10.13.42.33:8 \
  /root/package/nccl-tests-2.16.8/build/all_reduce_perf -b 1M -e 4G -f2 -g1
```
