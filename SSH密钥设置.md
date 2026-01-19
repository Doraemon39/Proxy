## SSH密钥登陆配置

#### 第一步：配置SSH密钥

私钥应当永远保留在你的电脑上，只将公钥上传给服务器

##### 一、在你的电脑上（Windows Powershell 或 Mac/Linux ）终端输入：

```bash
# -t 指定算法(推荐ed25519更安全快速) -C 备注
ssh-keygen -t ed25519 -C "vps_root"
```

* 根据提示输入密码，或一路回车也可以。

* **私钥位置**：`~/.ssh/id_ed25519` (Windows在 `C:\Users\用户名\.ssh\`) —— **妥善保管，丢失无法找回！**

* **公钥位置**：`~/.ssh/id_ed25519.pub`

##### 二、将公钥内容复制到 VPS

```
# 创建目录
mkdir -p ~/.ssh

# 编辑认证文件
nano ~/.ssh/authorized_keys
```

* **操作**：打开你电脑上的 `id_ed25519.pub` 文件，复制里面的内容（以 `ssh-ed25519` 开头的一行），**粘贴**到 VPS 的 `nano` 窗口中。

* **保存**：按 `Ctrl+O` 回车保存，按 `Ctrl+X` 退出。

##### 三、 赋予正确权限（必须）

```
chmod 700 ~/.ssh
chmod 600 ~/.ssh/authorized_keys
```

#### 第二步：配置 SSH 服务 (sshd_config)

##### 一、在 VPS 上执行：

```
nano /etc/ssh/sshd_config
```

**找到并修改（或新增）以下配置：**

```
# 1. 端口与网络
Port 2222
AddressFamily inet                  # 仅监听IPv4，减少攻击面

# 2. 权限与认证基础
PermitRootLogin prohibit-password   # 允许root登录，但禁止用密码
PubkeyAuthentication yes            # 开启密钥认证

# 3. 彻底禁用密码与交互
PasswordAuthentication no           # 彻底禁用密码登录
PermitEmptyPasswords no             # 禁止空密码
ChallengeResponseAuthentication no  # 禁用挑战响应
KbdInteractiveAuthentication no     # 禁用键盘交互
AuthenticationMethods publickey     # 强制仅允许公钥认证（双重保险）
UsePAM yes                          # 保证系统会话功能的完整性

# 4. 高级安全与性能
X11Forwarding no                    # 关闭X11转发，防止反向攻击
AllowAgentForwarding no             # 禁止SSH代理转发
UseDNS no                           # 禁用DNS反查，秒连
```

**保存退出** (`Ctrl+O`, Enter, `Ctrl+X`)。

**⚠️ 关键检查**： 执行 `sshd -t`。如果没有报错（无输出），说明配置语法正确。

#### 第四步：重启服务

```
systemctl restart ssh
```

