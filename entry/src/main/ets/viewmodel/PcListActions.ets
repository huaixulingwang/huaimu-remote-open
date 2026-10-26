/*
 * Moonlight for HarmonyOS
 * Copyright (C) 2024-2025 Moonlight/AlkaidLab
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

/**
 * PC 列表业务逻辑处理类
 *
 * 封装电脑相关的业务操作，如唤醒、配对、退出游戏等。
 * 通过回调接口与 UI 层解耦。
 */
import { promptAction } from '@kit.ArkUI';
import { AppNav } from '../common/AppNav';
import { AccessCodePageParams, AppListPageParams, StreamPageParams, serializeCmdList } from '../common/PageParams';
import { common } from '@kit.AbilityKit';
import { buffer } from '@kit.ArkTS';
import { ObservableComputer } from './ComputerViewModel';
import { ComputerManager } from '../service/ComputerManager';
import { PairingManager, PairState as PMPairState } from '../service/network/PairingManager';
import { NvHttp, ServerInfo } from '../service/streaming/NvHttp';
import { PairState, ComputerState, selectBestAddress, ComputerInfo } from '../model/ComputerInfo';
import {
  classifyServerIdentity,
  collectKnownAddresses,
  ServerIdentityDisposition
} from '../service/network/ComputerNetworkPolicy';
import { ConfirmDialogConfig, InfoDialogConfig } from '../components/dialogs/ConfirmDialog';
import { AppColors } from '../common/Theme';
import { isLoopbackIPv4 } from '../utils/NetHelper';
import { ToastQueue } from '../utils/ToastQueue';
import { VpnController, HOST_VIRTUAL_IP } from '../service/networking/VpnController';
import { StreamEntry } from '../service/network/StreamEntry';
import { AccessGate } from '../service/network/AccessGate';
import { AccountCenterService } from '../service/account/AccountCenterService';
import { Logger } from '../common/Logger';

/** 单地址网络测试结果 */
interface AddressTestResult {
  address: string;
  reachable: boolean;
  latencyMs: number;
  serverInfo: ServerInfo | null;
  error: string;
}

/**
 * UI 回调接口 — PcListActions 操作中需要触发 UI 变更时使用
 */
export interface PcListUICallbacks {
  showConfirmDialog: (config: ConfirmDialogConfig) => void;
  showInfoDialog: (config: InfoDialogConfig) => void;
  syncViewModel: () => void;
  showPinDialog: (pin: string, computerName: string) => void;
  hidePinDialog: () => void;
}

/**
 * 电脑操作业务逻辑
 */
export class PcListActions {
  private computerManager: ComputerManager;
  private ui: PcListUICallbacks;

  constructor(ui: PcListUICallbacks) {
    this.computerManager = ComputerManager.getInstance();
    this.ui = ui;
  }

  /** 处理电脑卡片点击 */
  async handleComputerTap(computer: ObservableComputer): Promise<void> {
    if (computer.isPaired) {
      AppNav.push('AppListPageV2', { computerId: computer.uuid } as AppListPageParams);
      return;
    }
    // 账号名单自动带出来的电脑还没配对：先确保能连上，再走一次配对
    const reachable = await this.ensureOnline(computer);
    if (!reachable) {
      ToastQueue.show({ message: '电脑暂时连不上，请确认电脑端已开机并在线' });
      return;
    }
    this.pairWithComputer(computer);
  }

  /**
   * 确保这台电脑当前可达；离线时拉起内置组网再探测一次。
   * 用于账号名单自动带出的电脑首次配对。
   */
  private async ensureOnline(computer: ObservableComputer): Promise<boolean> {
    const before = this.computerManager.getComputer(computer.uuid);
    if (computer.isOnline || (before !== undefined && before.state === ComputerState.ONLINE)) {
      return true;
    }

    AppStorage.setOrCreate<boolean>('connectingVisible', true);
    AppStorage.setOrCreate<string>('connectingText', '正在建立安全连接…');
    VpnController.getInstance().setProgressListener((msg: string): void => {
      AppStorage.setOrCreate<string>('connectingText', msg);
    });
    try {
      // 每台电脑的虚拟地址不同：优先用它登记/探测到的地址
      const target: string = before !== undefined
        ? (before.manualAddress !== undefined && before.manualAddress.length > 0
          ? before.manualAddress
          : (before.address.length > 0 ? before.address : HOST_VIRTUAL_IP))
        : (computer.manualAddress.length > 0
          ? computer.manualAddress
          : (computer.address.length > 0 ? computer.address : HOST_VIRTUAL_IP));
      const ok = await VpnController.getInstance().start(target);
      if (!ok) {
        return false;
      }
      const info = this.computerManager.getComputer(computer.uuid);
      if (info !== undefined && !info.manualAddress) {
        await this.computerManager.updateComputer(computer.uuid, { manualAddress: target });
      }
      await this.computerManager.refreshAllComputers();
      const after = this.computerManager.getComputer(computer.uuid);
      return after !== undefined && after.state === ComputerState.ONLINE;
    } catch (err) {
      Logger.warn('PcListActions', `准备配对失败: ${(err as Error).message}`);
      return false;
    } finally {
      AppStorage.setOrCreate<boolean>('connectingVisible', false);
    }
  }

  /**
   * 一键连接（主页播放按钮）
   * 只要已配对就可点击：
   *  - 电脑在线（局域网/外部 EasyTier 已组网）→ 不打扰现有网络，直接连
   *  - 电脑离线 → 先自动建立内置组网（弹 VPN 授权），再走固定虚拟 IP 直连
   */
  async handleQuickStream(computer: ObservableComputer): Promise<void> {
    if (!computer.isPaired) {
      // 账号名单自动带出的电脑：先确保能连上，再走一次配对
      const reachable = await this.ensureOnline(computer);
      if (!reachable) {
        ToastQueue.show({ message: '电脑暂时连不上，请确认电脑端已开机并在线' });
        return;
      }
      this.pairWithComputer(computer);
      return;
    }
    // 连接全程显示进度弹框（持续显示、可取消），由 ConnectingDialog 消费这两个全局状态
    AppStorage.setOrCreate<boolean>('connectingVisible', true);
    AppStorage.setOrCreate<string>('connectingText', '正在准备连接…');
    VpnController.getInstance().setProgressListener((msg: string): void => {
      AppStorage.setOrCreate<string>('connectingText', msg);
    });
    try {
      const context = getContext() as common.UIAbilityContext;

      // 每台电脑的虚拟地址不同：优先用它登记/探测到的地址
      const target: string = computer.manualAddress.length > 0
        ? computer.manualAddress
        : (computer.address.length > 0 ? computer.address : HOST_VIRTUAL_IP);

      // 电脑当前不可达 → 先启动内置组网（首次会弹系统 VPN 授权，最多等 25 秒）
      if (!computer.isOnline) {
        ToastQueue.show({ message: '正在建立安全连接，如弹出 VPN 请求请点允许…', duration: 4000 });
        const vpnOk = await VpnController.getInstance().start(target);
        if (!vpnOk) {
          AppStorage.setOrCreate<boolean>('connectingVisible', false);
          // 用户主动取消：不再弹失败框打扰
          if (!VpnController.getInstance().isCancelledByUser()) {
            // 组网失败：VpnController 内部已自动清理 VPN 通道，不会留下黑洞
            promptAction.showDialog({
              title: '无法连接到电脑',
              message: '安全组网没有建立成功。\n\n请确认已允许 VPN 权限后重试；如正在使用外部 EasyTier，请先在该 App 中断开连接再试。',
              buttons: [{ text: '我知道了', color: '#007DFF' }]
            });
          }
          return;
        }
        if (VpnController.getInstance().isCancelledByUser()) {
          // 弹框阶段被取消：保留 VPN 通道 5 分钟后自动关闭（重连可复用）
          VpnController.getInstance().scheduleStop();
          return;
        }
        AppStorage.setOrCreate<string>('connectingText', '安全通道已就绪，正在准备串流…');
        // 组网通道已验证可达（VpnController 以能连 47984 为准）。
        // 把电脑固定虚拟 IP 登记为轮询候选（用户没手动设过地址时），
        // 再立即探测一次，让电脑状态翻为在线、活跃地址就绪，后续串流才能选对路
        const infoBefore = this.computerManager.getComputer(computer.uuid);
        if (infoBefore && !infoBefore.manualAddress) {
          await this.computerManager.updateComputer(computer.uuid, { manualAddress: target });
        }
        await this.computerManager.refreshAllComputers();
      } else {
        ToastQueue.show({ message: '正在准备串流...', duration: 1000 });
      }

      const computerInfo = this.computerManager.getComputer(computer.uuid);
      if (!computerInfo || computerInfo.pairState !== PairState.PAIRED) {
        ToastQueue.show({ message: '设备未配对' });
        return;
      }
      if (VpnController.getInstance().isCancelledByUser()) {
        // 用户在获取应用列表期间点了取消
        VpnController.getInstance().scheduleStop();
        return;
      }
      // 探测后已在线：走实测最优地址（同局域网时自动走物理直连）；
      // 仍未翻在线：VpnController 已验证虚拟 IP 的 Sunshine 端口可达，直接用它
      const nvHttp = computer.isOnline
        ? NvHttp.fromComputer(computerInfo, context)
        : NvHttp.fromAddress(target, computerInfo, context);
      const apps = await nvHttp.getAppList();
      if (computer.runningGameId > 0) {
        const runningApp = apps.find(a => a.id === computer.runningGameId);
        const cmdList = runningApp?.cmdList;
        await StreamEntry.open(computer.uuid, {
          computerId: computer.uuid,
          appId: computer.runningGameId,
          appName: runningApp?.name || '正在运行',
          cmdList: serializeCmdList(cmdList),
          resume: true,
          displayGuid: ''
        } as StreamPageParams);
        return;
      }
      if (apps.length === 0) {
        ToastQueue.show({ message: '没有可用的应用' });
        return;
      }
      const firstApp = apps[0];
      await StreamEntry.open(computer.uuid, {
        computerId: computer.uuid,
        appId: firstApp.id,
        appName: firstApp.name,
        cmdList: serializeCmdList(firstApp.cmdList),
        resume: false,
        displayGuid: ''
      } as StreamPageParams);
    } catch (err) {
      ToastQueue.show({ message: `启动失败: ${(err as Error).message}` });
    } finally {
      AppStorage.setOrCreate<boolean>('connectingVisible', false);
    }
  }

  /**
   * 主动用临时控制码连接一台已配对的电脑。
   * 先建立组网、拿到应用列表，再进入控制码页；验证通过后由码页直接进串流。
   */
  async connectWithAccessCode(computer: ObservableComputer): Promise<void> {
    if (!computer.isPaired) {
      ToastQueue.show({ message: '请先与这台电脑完成配对' });
      return;
    }

    AppStorage.setOrCreate<boolean>('connectingVisible', true);
    AppStorage.setOrCreate<string>('connectingText', '正在准备控制码连接…');
    VpnController.getInstance().setProgressListener((msg: string): void => {
      AppStorage.setOrCreate<string>('connectingText', msg);
    });

    try {
      const context = getContext() as common.UIAbilityContext;
      const target: string = computer.manualAddress.length > 0
        ? computer.manualAddress
        : (computer.address.length > 0 ? computer.address : HOST_VIRTUAL_IP);

      if (!computer.isOnline) {
        const vpnOk = await VpnController.getInstance().start(target);
        if (!vpnOk) {
          AppStorage.setOrCreate<boolean>('connectingVisible', false);
          if (!VpnController.getInstance().isCancelledByUser()) {
            promptAction.showDialog({
              title: '无法连接到电脑',
              message: '安全组网没有建立成功。\n\n请确认已允许 VPN 权限后重试。',
              buttons: [{ text: '我知道了', color: '#007DFF' }]
            });
          }
          return;
        }
      }

      const info = this.computerManager.getComputer(computer.uuid);
      if (!info) {
        ToastQueue.show({ message: '找不到这台电脑的配置' });
        return;
      }

      const nvHttp = computer.isOnline
        ? NvHttp.fromComputer(info, context)
        : NvHttp.fromAddress(target, info, context);
      const apps = await nvHttp.getAppList();

      let appId: number = computer.runningGameId;
      let appName: string = '正在运行';
      if (appId <= 0 && apps.length > 0) {
        appId = apps[0].id;
        appName = apps[0].name;
      }
      if (appId <= 0) {
        ToastQueue.show({ message: '这台电脑上没有可用的应用' });
        return;
      }

      const host: string = selectBestAddress(info);
      AppNav.push('AccessCodePage', {
        host: host.length > 0 ? host : target,
        computerId: computer.uuid,
        computerName: computer.name,
        reason: '输入电脑端生成的控制码即可连接',
        stream: {
          computerId: computer.uuid,
          appId: appId,
          appName: appName,
          resume: computer.runningGameId > 0
        } as StreamPageParams
      } as AccessCodePageParams);
    } catch (err) {
      ToastQueue.show({ message: `准备失败: ${(err as Error).message}` });
    } finally {
      AppStorage.setOrCreate<boolean>('connectingVisible', false);
    }
  }

  /** 配对 */
  async pairWithComputer(computer: ObservableComputer): Promise<void> {
    const info = this.computerManager.getComputer(computer.uuid);
    const online = computer.isOnline || (info !== undefined && info.state === ComputerState.ONLINE);
    if (!online) {
      ToastQueue.show({ message: '电脑离线，无法配对' });
      return;
    }
    try {
      const context = getContext() as common.UIAbilityContext;
      const address = selectBestAddress(computer);
      // 同账号时由电脑端直接代我们生成一次性配对码，不需要用户去电脑网页上输 PIN
      const token: string = await AccountCenterService.getAccessTokenForGate();
      const pin: string = await AccessGate.requestPairPin(address, token, computer.name);
      if (pin.length === 0) {
        ToastQueue.show({ message: '这台电脑没有允许自动配对，请确认电脑端已登录同一账号' });
        return;
      }
      const pairingManager = new PairingManager(address, computer.uuid, context, computer.httpPort);
      const result = await pairingManager.pair(pin);
      if (result.state === PMPairState.PAIRED) {
        let serverCertBase64 = '';
        if (result.serverCert) {
          const buf = buffer.from(result.serverCert);
          serverCertBase64 = buf.toString('base64');
        }
        await this.computerManager.updateComputer(computer.uuid, {
          pairState: PairState.PAIRED,
          serverCert: serverCertBase64,
          pairName: result.pairName || ''
        });
        this.ui.syncViewModel();
        ToastQueue.show({ message: '配对成功！' });
        AppNav.push('AppListPageV2', { computerId: computer.uuid } as AppListPageParams);
      } else if (result.state === PMPairState.PIN_WRONG) {
        ToastQueue.show({ message: 'PIN 码错误，请重试' });
      } else if (result.state === PMPairState.ALREADY_IN_PROGRESS) {
        ToastQueue.show({ message: '另一个设备正在配对中' });
      } else {
        ToastQueue.show({ message: `配对失败: ${result.state}` });
      }
    } catch (error) {
      ToastQueue.show({ message: `配对失败: ${(error as Error).message}` });
    }
  }

  /** 唤醒 */
  async wakeComputer(computer: ObservableComputer): Promise<void> {
    if (!computer.macAddress || computer.macAddress === '00:00:00:00:00:00') {
      ToastQueue.show({ message: '缺少有效的 MAC 地址。请先在电脑在线时配对，以获取 MAC 地址。' });
      return;
    }
    try {
      await this.computerManager.wakeComputer(computer.uuid);
      ToastQueue.show({ message: '唤醒包已发送' });
    } catch (err) {
      ToastQueue.show({ message: `发送失败: ${err instanceof Error ? err.message : String(err)}` });
    }
  }

  /** 退出游戏 */
  quitGame(computer: ObservableComputer): void {
    if (!computer.isOnline) {
      ToastQueue.show({ message: '电脑离线，无法退出游戏' });
      return;
    }
    if (!computer.isPaired) {
      ToastQueue.show({ message: '未配对，无法退出游戏' });
      return;
    }
    if (!computer.runningGameId || computer.runningGameId <= 0) {
      ToastQueue.show({ message: '没有正在运行的游戏' });
      return;
    }
    this.ui.showConfirmDialog({
      title: '退出游戏',
      message: '确定要退出当前运行的游戏吗？',
      confirmButton: {
        text: '退出',
        color: AppColors.Error,
        onClick: async () => {
          try {
            ToastQueue.show({ message: '正在退出游戏...' });
            const context = getContext() as common.UIAbilityContext;
            const nvHttp = NvHttp.fromComputer(computer, context);
            const success = await nvHttp.quitApp();
            if (success) {
              ToastQueue.show({ message: '游戏已退出' });
              await this.computerManager.pollComputer(computer.toComputerInfo());
              this.ui.syncViewModel();
            } else {
              ToastQueue.show({ message: '退出游戏失败' });
            }
          } catch (error) {
            ToastQueue.show({ message: `退出游戏失败: ${(error as Error).message}` });
          }
        }
      }
    });
  }

  /** 休眠 */
  sleepComputer(computer: ObservableComputer): void {
    if (!computer.isOnline) {
      ToastQueue.show({ message: '电脑离线，无法休眠' });
      return;
    }
    if (!computer.isPaired) {
      ToastQueue.show({ message: '未配对，无法发送休眠命令' });
      return;
    }
    this.ui.showConfirmDialog({
      title: '休眠电脑',
      message: `确定要让 "${computer.name}" 进入睡眠模式吗？`,
      confirmButton: {
        text: '休眠',
        onClick: async () => {
          try {
            ToastQueue.show({ message: '正在发送休眠命令...' });
            const context = getContext() as common.UIAbilityContext;
            const nvHttp = NvHttp.fromComputer(computer, context);
            const success = await nvHttp.pcSleep();
            if (success) {
              ToastQueue.show({ message: '睡眠命令已发送' });
              computer.state = ComputerState.OFFLINE;
              this.ui.syncViewModel();
            } else {
              ToastQueue.show({ message: '发送睡眠命令失败' });
            }
          } catch (error) {
            ToastQueue.show({ message: `发送睡眠命令失败: ${(error as Error).message}` });
          }
        }
      }
    });
  }

  /** 恢复游戏 */
  async resumeGame(computer: ObservableComputer): Promise<void> {
    // 获取应用列表以获取超级指令（cmdList）
    try {
      const computerInfo = this.computerManager.getComputer(computer.uuid);
      if (computerInfo) {
        const context = getContext() as common.UIAbilityContext;
        const nvHttp = NvHttp.fromComputer(computerInfo, context);
        const apps = await nvHttp.getAppList();
        const runningApp = apps.find(a => a.id === computer.runningGameId);
        const cmdList = runningApp?.cmdList;
        await StreamEntry.open(computer.uuid, {
          computerId: computer.uuid,
          appId: computer.runningGameId,
          appName: runningApp?.name,
          cmdList: serializeCmdList(cmdList),
          resume: true,
          displayGuid: ''
        } as StreamPageParams);
        return;
      }
    } catch {
      // 获取失败时仍然恢复游戏，只是没有超级指令
    }
    await StreamEntry.open(computer.uuid, {
      computerId: computer.uuid,
      appId: computer.runningGameId,
      resume: true,
      displayGuid: ''
    } as StreamPageParams);
  }

  /** 取消配对 */
  unpairComputer(computer: ObservableComputer): void {
    this.ui.showConfirmDialog({
      title: '取消配对',
      message: `确定要取消与 ${computer.name} 的配对吗？`,
      confirmButton: {
        text: '确定',
        color: AppColors.Error,
        onClick: async () => {
          try {
            await this.computerManager.unpairComputer(computer.uuid);
            ToastQueue.show({ message: '已取消配对' });
            this.ui.syncViewModel();
          } catch (_e) {
            ToastQueue.show({ message: '操作失败' });
          }
        }
      }
    });
  }

  /** 删除电脑 */
  deleteComputer(computer: ObservableComputer): void {
    this.ui.showConfirmDialog({
      title: '删除电脑',
      message: `确定要删除 ${computer.name} 吗？`,
      confirmButton: {
        text: '删除',
        color: AppColors.Error,
        onClick: async () => {
          try {
            await this.computerManager.removeComputer(computer.uuid);
            ToastQueue.show({ message: '已删除' });
            this.ui.syncViewModel();
          } catch (_e) {
            ToastQueue.show({ message: '删除失败' });
          }
        }
      }
    });
  }

  /** 测试网络 */
  async testNetwork(computer: ObservableComputer): Promise<void> {
    ToastQueue.show({ message: '正在检测网络…' });
    const computerInfo = computer.toComputerInfo();
    const context = getContext() as common.UIAbilityContext;

    // 诊断包含锁定地址，但过滤服务器自报的 127.x 回环地址。
    const addresses = collectKnownAddresses(computerInfo, {
      includePreferred: true,
      excludeLoopbackIPv4: true
    });
    const addressSet = new Set<string>(addresses);

    if (addresses.length === 0) {
      this.ui.showInfoDialog({ title: '网络测试', content: '没有可用的连接地址' });
      return;
    }

    // 对每个地址分别测试延迟（3 轮取平均）
    const TEST_ROUNDS = 3;
    const results: AddressTestResult[] = [];

    for (const addr of addresses) {
      const roundLatencies: number[] = [];
      let lastServerInfo: ServerInfo | null = null;
      let lastError = '';

      for (let i = 0; i < TEST_ROUNDS; i++) {
        const startMs = Date.now();
        try {
          // 基础可达性使用 HTTP，避免把证书/HTTPS 故障误判成整个网络不可达。
          // 此处刻意不传 context：不配置客户端证书文件时 getServerInfo() 才走 HTTP。
          const nvHttp = NvHttp.fromAddress(addr, computerInfo);
          const info = await nvHttp.getServerInfo();
          const identity = classifyServerIdentity(computerInfo.uuid, info.uniqueId);
          if (identity === ServerIdentityDisposition.MISSING) {
            throw new Error('服务器响应缺少主机 UUID');
          }
          if (identity === ServerIdentityDisposition.MISMATCH) {
            throw new Error(`主机身份不匹配 (${info.uniqueId})`);
          }
          const elapsed = Date.now() - startMs;
          roundLatencies.push(elapsed);
          lastServerInfo = info;
        } catch (err) {
          lastError = (err as Error).message || String(err);
          break; // 失败则不继续后续轮次
        }
      }

      const avgLatency = roundLatencies.length > 0
        ? roundLatencies.reduce((a, b) => a + b, 0) / roundLatencies.length
        : 0;

      results.push({
        address: addr,
        reachable: roundLatencies.length > 0,
        latencyMs: Math.round(avgLatency),
        serverInfo: lastServerInfo,
        error: lastError
      });
    }

    // 汇总结果
    const lines: string[] = [];
    const reachableResults = results.filter(r => r.reachable);
    const unreachableResults = results.filter(r => !r.reachable);

    const currentPreferred = computerInfo.preferredAddress;

    // 基础信息取延迟最低的可达地址；实际认证链路必须遵循用户锁定地址。
    let displayResult: AddressTestResult | undefined;
    for (const result of reachableResults) {
      if (!displayResult || result.latencyMs < displayResult.latencyMs) {
        displayResult = result;
      }
    }
    const connectionAddress = selectBestAddress(computerInfo);
    const connectionAddressTested = !!connectionAddress && addressSet.has(connectionAddress);
    const connectionAddressUntested = !!connectionAddress && !connectionAddressTested;
    const connectionResult = reachableResults.find(result => result.address === connectionAddress);
    const connectionAddressUnavailable = connectionAddressTested && !connectionResult;

    const serverInfo = displayResult?.serverInfo || undefined;
    let appListReachable: boolean | undefined;
    let appListError = '';
    if (computer.isPaired && connectionResult) {
      // serverinfo 可由 HTTP 回退成功，不能据此宣称配对链路完整可用。
      // 只验证真正会被 AppList/串流使用的地址，不用备用地址制造假阳性。
      try {
        const latestComputer = this.computerManager.getComputer(computer.uuid) || computerInfo;
        const nvHttp = NvHttp.fromAddress(connectionResult.address, latestComputer, context);
        await nvHttp.getAppList();
        appListReachable = true;
      } catch (err) {
        appListReachable = false;
        appListError = (err as Error).message || String(err);
      }
    }

    if (reachableResults.length > 0) {
      lines.push('[OK] 基础网络可达');
      if (computer.isPaired) {
        if (connectionAddressUntested) {
          const addressKind = currentPreferred ? '锁定地址' : '当前连接地址';
          lines.push(`[!] ${addressKind}为本机回环地址，未执行诊断`);
        } else if (connectionAddressUnavailable) {
          const addressKind = currentPreferred ? '锁定地址' : '当前连接地址';
          lines.push(`[!] ${addressKind}不可达，备用地址仅用于网络诊断`);
        } else if (appListReachable) {
          lines.push('[OK] 应用列表认证可用');
        } else {
          lines.push('[!] 主机可达，但应用列表认证不可用');
          if (appListError) {
            const shortAppError = appListError.length > 80 ? appListError.substring(0, 80) + '…' : appListError;
            lines.push(`    ${shortAppError}`);
          }
        }
      }
      lines.push('');

      // 地址延迟
      for (const r of reachableResults) {
        const label = this.getAddressLabel(r.address, computerInfo);
        const quality = r.latencyMs < 10 ? '极佳' : r.latencyMs < 30 ? '良好' : r.latencyMs < 80 ? '一般' : '较高';
        const pin = r.address === computerInfo.preferredAddress ? ' 📌' : '';
        lines.push(`${label}: ${r.latencyMs}ms (${quality})${pin}`);
      }

      // 服务器信息
      if (serverInfo) {
        lines.push('');
        lines.push(`主机名: ${serverInfo.hostname}`);
        if (serverInfo.gpuType) lines.push(`GPU: ${serverInfo.gpuType}`);
        let pairText = '未配对';
        if (computer.isPaired) {
          if (appListReachable) {
            pairText = '已配对（已验证）';
          } else if (connectionAddressUntested) {
            pairText = '本地已配对（连接地址未测试）';
          } else if (connectionAddressUnavailable) {
            pairText = currentPreferred
              ? '本地已配对（锁定地址不可达）'
              : '本地已配对（当前连接地址不可达）';
          } else {
            pairText = '本地已配对（认证未通过）';
          }
        }
        lines.push(`配对: ${pairText}`);
        if (serverInfo.currentGame > 0) lines.push(`运行中游戏 ID: ${serverInfo.currentGame}`);
      }
    } else {
      lines.push('所有地址均无法连接');
    }

    // 不可达地址
    if (unreachableResults.length > 0) {
      lines.push('');
      for (const r of unreachableResults) {
        const label = this.getAddressLabel(r.address, computerInfo);
        const shortErr = r.error.length > 60 ? r.error.substring(0, 60) + '…' : r.error;
        lines.push(`[X] ${label}: ${shortErr || '超时'}`);
      }
    }

    // 当前锁定的地址
    if (currentPreferred) {
      lines.push('');
      lines.push(`📌 已锁定: ${currentPreferred}`);
    }

    // 显示结果后提供锁定/解锁操作
    if (reachableResults.length > 0) {
      this.ui.showInfoDialog({
        title: '网络测试 — ' + computer.name,
        content: lines.join('\n'),
        closeButtonText: '关闭',
        onClose: () => {
          this.showAddressPinMenu(computer, reachableResults, currentPreferred);
        }
      });
    } else {
      this.ui.showInfoDialog({ title: '网络测试 — ' + computer.name, content: lines.join('\n') });
    }
  }

  /** 显示地址锁定/解锁菜单 */
  private showAddressPinMenu(
    computer: ObservableComputer,
    reachableResults: AddressTestResult[],
    currentPreferred: string | undefined
  ): void {
    const computerInfo = computer.toComputerInfo();

    // 构建按钮列表（showDialog 最多 3 个按钮，我们用前几个可达地址 + 解锁）
    interface DialogBtn {
      text: string;
      color: string;
    }
    const dialogButtons: DialogBtn[] = [];
    // 记录每个按钮对应的动作
    const actions: string[] = []; // 'unlock' | address string

    // 如果已锁定，提供解锁选项
    if (currentPreferred) {
      dialogButtons.push({ text: '解除锁定', color: '#E57373' });
      actions.push('unlock');
    }

    // 提供可达地址（最多填满到 3 个按钮）
    for (const r of reachableResults) {
      if (dialogButtons.length >= 3) break;
      const label = this.getAddressLabel(r.address, computerInfo);
      const pinned = r.address === currentPreferred ? ' ✓' : '';
      dialogButtons.push({ text: `${label}${pinned}`, color: '#4CAF50' });
      actions.push(r.address);
    }

    if (dialogButtons.length === 0) return;

    promptAction.showDialog({
      title: '锁定优先连接地址',
      message: currentPreferred ? `当前锁定: ${currentPreferred}` : '选择要锁定的地址',
      buttons: dialogButtons
    }).then(async (result) => {
      const action = actions[result.index];
      if (!action) return;
      const nextAddress = action === 'unlock' ? '' : action;
      try {
        await this.computerManager.updateComputer(computer.uuid, { preferredAddress: nextAddress });
      } catch (err) {
        const message = (err as Error).message || String(err);
        ToastQueue.show({ message: `保存地址锁定失败: ${message}` });
        return;
      }
      computer.preferredAddress = nextAddress;
      this.ui.syncViewModel();
      ToastQueue.show({ message: nextAddress ? `已锁定: ${nextAddress}` : '已解除地址锁定' });
    }).catch(() => {
      // 用户取消
    });
  }

  /** 根据地址匹配返回易读标签 */
  private getAddressLabel(address: string, computerInfo: ComputerInfo): string {
    if (address === computerInfo.manualAddress) return `手动 (${address})`;
    if (address === computerInfo.localAddress) return `局域网 (${address})`;
    if (address === computerInfo.remoteAddress) return `远程 (${address})`;
    if (address === computerInfo.ipv6Address) return `IPv6 (${address})`;
    return address;
  }

  /** 显示电脑详情 */
  showComputerDetails(computer: ObservableComputer): void {
    const stateText = computer.isOnline ? '在线' : '离线';
    const pairText = computer.isPaired ? '已配对' : '未配对';
    const gamingText = computer.isGaming ? `正在运行游戏 (ID: ${computer.runningGameId})` : '空闲';

    const addressLines: string[] = [];
    const info = computer.toComputerInfo();
    const notLoopback = (a: string | undefined) => a && !isLoopbackIPv4(a);
    if (notLoopback(info.manualAddress)) { addressLines.push(`手动地址: ${info.manualAddress}`); }
    if (notLoopback(info.localAddress)) { addressLines.push(`本地地址: ${info.localAddress}`); }
    if (notLoopback(info.remoteAddress)) { addressLines.push(`远程地址: ${info.remoteAddress}`); }
    if (notLoopback(info.address) && info.address !== info.localAddress && info.address !== info.remoteAddress && info.address !== info.manualAddress) {
      addressLines.push(`当前地址: ${info.address}`);
    }
    if (addressLines.length === 0) { addressLines.push(`地址: 未知`); }

    const details = [
      `名称: ${computer.name}`,
      `状态: ${stateText}`,
      `配对: ${pairText}`,
      `游戏: ${gamingText}`,
      ``,
      `UUID: ${computer.uuid}`,
      ...addressLines,
      `MAC 地址: ${computer.macAddress || '未知'}`,
      `HTTPS 端口: ${info.httpsPort || NvHttp.DEFAULT_HTTPS_PORT}`,
      `HTTP 端口: ${info.httpPort || NvHttp.DEFAULT_HTTP_PORT}`,
    ].join('\n');

    this.ui.showInfoDialog({ title: computer.name, content: details });
  }
}
