# GPU 环境部署与压力测试操作手册

本手册介绍在 Ubuntu 22.04 系统上部署 GPU 运行环境并执行压力烤机测试的完整流程，涵盖显卡驱动、CUDA Toolkit、nvidia-fabricmanager 组件的安装，以及 gpu-burn 压力测试工具的编译与使用。全程采用**在线安装**方式（apt + NVIDIA 官方软件仓库），适用于硬件验收、服务器巡检等场景。

## 一、环境说明

| 项目 | 说明 |
|---|---|
| 操作系统 | Ubuntu 22.04 |
| 显卡驱动版本 | 550 系列（在线默认安装该系列最新版本，如 550.163.01；可精确锁定至 550.127.05） |
| CUDA 版本 | 12.4 |
| 测试工具 | gpu-burn（GPU 压力烤机工具） |
| 安装方式 | 在线安装，服务器需可访问外网（NVIDIA 官方仓库、GitHub） |

> **重要说明**：驱动、CUDA 等组件需根据实际硬件型号与业务需求选择适配版本，本手册演示的版本仅供参考。

## 二、资源获取

### 在线安装（本手册方式，推荐）

无需手动下载安装包。驱动、CUDA、fabricmanager 均通过 NVIDIA 官方软件仓库在线安装，gpu-burn 源码从 GitHub 在线下载，仅需保证服务器可正常访问外网。

### 离线安装（适用于无网络环境）

若服务器无法联网，需提前在可联网环境按下文"官方下载地址"准备全套离线安装包（gcc 依赖 deb 包、NVIDIA 驱动、fabricmanager、gpu-burn 源码），上传至服务器后使用 dpkg 安装，本手册不再展开离线操作步骤。

### 官方下载地址

1. NVIDIA 显卡驱动（按显卡型号、系统版本选择对应驱动）

   https://www.nvidia.com/drivers/

2. CUDA Toolkit 历史版本归档

   https://developer.nvidia.com/cuda-toolkit-archive

3. NVIDIA 官方 CUDA 软件仓库（驱动 / CUDA / fabricmanager 的 deb 包，按 Ubuntu 版本选择目录）

   https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/

4. gpu-burn 源码仓库

   https://github.com/wilicc/gpu-burn

> **版本兼容性提示**：
>
> ① `nvidia-smi` 输出的 CUDA Version 为驱动支持的最高 CUDA 版本，安装的 CUDA 版本不得高于该版本，否则会出现兼容性异常；
>
> ② nvidia-fabricmanager 版本必须与 NVIDIA 驱动版本完全一致，版本不匹配将导致服务启动失败、NVLink 多卡通信异常。

## 三、操作步骤（在线安装）

### 步骤 1：配置 root 账号

系统安装完成后，启用 root 账户：

```bash
sudo passwd root
```

按提示设置密码，完成 root 账号激活。

### 步骤 2：安装编译依赖包

使用 apt 安装编译工具链与内核头文件（驱动 dkms 编译所需）：

```bash
apt-get update
apt-get install -y build-essential linux-headers-$(uname -r) unzip curl
```

验证 gcc 安装结果：

```bash
gcc --version
```

正常输出版本号，表示编译环境就绪。

### 步骤 3：配置 NVIDIA 官方 CUDA 软件源

驱动、CUDA、fabricmanager 均来自 NVIDIA 官方 CUDA 仓库，安装 cuda-keyring 完成源配置：

```bash
curl -fsSL https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb -o /tmp/cuda-keyring.deb
apt-get install -y /tmp/cuda-keyring.deb
apt-get update
```

### 步骤 4：安装 NVIDIA 显卡驱动

在线安装 550 系列驱动（默认安装该系列最新版本）：

```bash
apt-get install -y nvidia-driver-550
```

> **提示**：如需精确锁定 550.127.05 版本，由于驱动由多个子包组成，必须将所有子包同时锁定到同一版本号，否则会出现依赖冲突。建议直接使用第四章的一键安装脚本自动处理版本锁定。

安装完成后**重启服务器**以加载驱动内核模块：

```bash
reboot
```

重启后验证驱动：

```bash
nvidia-smi
```

正常输出显卡列表、驱动版本、CUDA 版本信息，表示驱动安装成功。

> **说明**：未重启前直接执行 `nvidia-smi` 会提示无法与驱动通信，属正常现象；若服务器无 NVIDIA 显卡，`nvidia-smi` 同样无法输出显卡信息。

### 步骤 5：安装 CUDA Toolkit

在线安装 CUDA 12.4（apt 方式仅安装 Toolkit 本体，不会重复安装驱动）：

```bash
apt-get install -y cuda-toolkit-12-4
```

配置 CUDA 环境变量：

```bash
cat > /etc/profile.d/cuda.sh <<'EOF'
export PATH=/usr/local/cuda/bin:$PATH
export LD_LIBRARY_PATH=/usr/local/cuda/lib64:/usr/local/cuda/targets/x86_64-linux/lib:$LD_LIBRARY_PATH
EOF
source /etc/profile.d/cuda.sh
```

验证 CUDA：

```bash
nvcc -V
```

正常输出版本信息，表示配置完成。

### 步骤 6：安装 nvidia-fabricmanager（多卡 NVLink 必装）

多 GPU 服务器必须部署 fabricmanager，以保障 NVLink、多卡通信正常。在线安装时，包版本必须与驱动版本完全一致。

1. 先确认已安装的驱动版本：

```bash
dpkg -l nvidia-driver-550 | awk '/^ii/{print $3}'
```

2. 安装与驱动**同版本**的 fabricmanager。若步骤 4 使用默认方式安装（550 系列最新版），直接安装最新版即可：

```bash
apt-get install -y nvidia-fabricmanager-550
```

若步骤 4 精确锁定了驱动版本（如 550.127.05），则必须安装完全一致的版本：

```bash
apt-get install -y nvidia-fabricmanager-550=550.127.05-1
```

3. 设置开机自启、启动服务并查看状态：

```bash
# 设置开机自启
systemctl enable nvidia-fabricmanager
# 启动服务
systemctl start nvidia-fabricmanager
# 查看运行状态
systemctl status nvidia-fabricmanager
```

状态显示 `active (running)` 表示服务正常运行。

### 步骤 7：编译 gpu-burn 并执行压力烤机测试

gpu-burn 是经典的 GPU 压力测试工具，可将 GPU 满载运行，用于检验硬件稳定性、温度表现及是否存在硬件报错。

1. 在线下载源码并解压：

```bash
curl -fsSL https://github.com/wilicc/gpu-burn/archive/refs/heads/master.zip -o /root/gpu-burn-master.zip
unzip /root/gpu-burn-master.zip -d /root
cd /root/gpu-burn-master
```

2. 编译源码（自动探测 /usr/local/cuda）：

```bash
make
```

编译过程中出现的警告可忽略，生成 `gpu_burn` 可执行文件即为编译成功。

3. 执行压力测试（参数为测试时长，单位秒，示例运行 60 秒）：

```bash
./gpu_burn 60
```

**结果判定**：

- 测试结束输出 `GPU X: OK`，且所有显卡均为 OK，表示硬件无报错；
- 若出现 error、failed，表示对应显卡存在硬件异常，需进一步排查。

> **提示**：
>
> - 硬件验收场景建议延长测试时间，例如运行 1800 秒（30 分钟）长时间烤机，并通过 `nvidia-smi` 观察温度、功耗；
> - 测试期间服务器负载较高，请勿同时运行其他业务。

## 四、一键安装脚本（推荐）

上述全部步骤已封装为自动化脚本 `install_gpuenv.sh`（与本手册同目录），支持在线安装、指定版本、已装组件自动跳过：

```bash
# 默认版本安装（驱动 550.163.01 + CUDA 12.4）
bash install_gpuenv.sh start

# 指定版本安装（与本手册演示版本一致）
bash install_gpuenv.sh start --driver 550.127.05 --cuda 12.4

# 查看帮助 / 卸载
bash install_gpuenv.sh --help
bash install_gpuenv.sh uninstall
```

脚本特性：

- 源地址、版本号均为脚本开头的配置变量，可按需修改（如切换国内加速域名）；
- 自动锁定驱动全部子包版本，避免依赖冲突；
- fabricmanager 默认与驱动版本保持一致；
- 已安装且版本一致的组件自动跳过，`--force` 可强制重装；
- apt 安装失败时立即报错退出，并给出修复建议。

## 五、常见问题与注意事项

1. 在线安装前需确认服务器可访问 NVIDIA 官方仓库（developer.download.nvidia.com），内网环境需提前配置代理。
2. 精确指定驱动版本时，必须锁定全部驱动子包版本，仅锁定主包会出现依赖冲突；使用一键安装脚本可自动处理。
3. CUDA 使用 apt 安装 `cuda-toolkit-12-4` 即可，不会重复安装驱动；若使用 run 包安装，务必取消驱动选项，避免冲突。
4. 多卡服务器若未启动 fabricmanager 服务，将导致多卡通信异常、测试报错；fabricmanager 包版本必须与驱动版本完全匹配。
5. gpu-burn 编译时出现警告属于正常现象，成功生成可执行程序即可使用。
6. 驱动、CUDA 等组件需根据实际硬件型号与业务需求配套选择，本手册演示版本仅供参考。
