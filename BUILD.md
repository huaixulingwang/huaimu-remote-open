# 构建说明（BUILD）

## 环境

- DevEco Studio（建议 5.0 以上版本）与 HarmonyOS SDK（API 12 及以上）
- Node.js（工程自带 hvigor 包装脚本）

## 步骤

```powershell
# 1) 拉子模块
git submodule update --init --recursive

# 2) 配置签名：用 DevEco Studio 打开工程，
#    File → Project Structure → Signing Configs → 勾选自动生成（需登录华为开发者账号）
#    这会生成 build-profile.json5（该文件不入库）

# 3) 配置组网密钥（可选）：复制
#    entry/src/main/ets/common/Secrets.ets.example → Secrets.ets 并填写

# 4) 命令行构建
$env:JAVA_HOME='<DevEco 自带的 jbr 目录>'
node hvigorw.js assembleHap --mode module -p product=default --no-daemon
```

产物：`entry/build/default/outputs/default/entry-default-signed.hap`

## 安装到平板

```powershell
# 开启平板「无线调试」，记下 IP 与端口（每次开关都会变）
hdc tconn <平板IP>:<端口>
hdc install -r entry-default-signed.hap
```

## 需要自己准备的东西（不在仓库里）

1. **签名配置**：`build-profile.json5` 绑定真机调试授权，换机需重新生成；
2. **组网密钥**：`Secrets.ets`（照 `.example` 模板创建），也可以不填，改用配对时由电脑端下发；
3. **节点地址**：见 [CONFIG.md](CONFIG.md)；
4. **easytier-ohrs**：`libs/easytier-ohrs-*.har` 需从 EasyTier 官方发布页获取后放入 `libs/`。

## 常见问题

- 中文路径会导致构建报编码错误，工程请放在纯英文路径下；
- 子模块未拉取时，原生库编译会失败；
- 无线调试端口离开设置页面就失效，重新连接时端口会变。
